//
//  SQLiteLivingMemoryStore.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import Foundation
import Memory

/// SQLiteLivingMemoryStore is `LivingMemoryStoring` over one SQLite file, by default
/// `living-memory.sqlite` in the knowledge directory, beside the brain's JSON files and
/// independent of them.
///
/// Durability: the file is in WAL mode with `synchronous=FULL` and `fullfsync`, so every write
/// commits and reaches stable storage before its call returns; nothing waits for the chat to end.
///
/// Serialization: the actor owns one connection and runs each operation synchronously inside it,
/// so no transaction is open across a suspension. Every write is one `BEGIN IMMEDIATE`
/// transaction, which takes the file's write lock before reading, so a second connection, in this
/// process or another, cannot interleave a read-modify-write. Contention waits up to
/// `busyTimeoutMilliseconds`, blocking this actor's thread, then fails with `SQLITE_BUSY`.
///
/// Failure: a thrown operation rolled back and changed nothing. Opening never repairs: a file that
/// is not a database, a database of something else, or a newer schema is refused with a readable
/// `SQLiteLivingMemoryError` and left untouched. A read-only store opens only an existing store at
/// a schema this build reads without migrating (`SQLiteLivingMemorySchema.oldestReadableVersion`
/// through the current one), and never creates, migrates or writes.
public actor SQLiteLivingMemoryStore: LivingMemoryStoring {

    /// Access is whether the store may create, migrate and write.
    public enum Access: Sendable, Equatable {
        case readWrite
        case readOnly
    }

    public static let fileName = "living-memory.sqlite"

    /// How long an operation waits for another connection's write lock.
    public static let busyTimeoutMilliseconds = 5_000

    /// The store file inside a knowledge directory.
    public static func file(inKnowledgeDirectory directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    public nonisolated let file: URL
    public nonisolated let access: Access

    private let connection: SQLiteConnection
    private let makeID: @Sendable () -> ExperienceID
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Opens the store at `file`.
    ///
    /// Read-write creates the file and its directory when absent and migrates an older schema in one
    /// transaction. Read-only requires an existing store at the current schema.
    /// - Parameter makeID: supplies a new experience's persistent id; a random UUID by default.
    /// - Throws: `SQLiteLivingMemoryError`; the file is left as it was.
    public init(
        file  : URL,
        access: Access = .readWrite,
        makeID: @escaping @Sendable () -> ExperienceID = { ExperienceID(UUID().uuidString) }
    ) throws {
        try self.init(file: file, access: access, makeID: makeID, schema: .current)
    }

    /// Opens the store against an explicit schema, so a test can exercise a migration.
    init(
        file  : URL,
        access: Access,
        makeID: @escaping @Sendable () -> ExperienceID,
        schema: SQLiteLivingMemorySchema
    ) throws {
        self.file   = file
        self.access = access
        self.makeID = makeID
        let encoder = KnowledgeCoding.makeEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = KnowledgeCoding.makeDecoder()
        self.connection = try Self.open(file: file, access: access, schema: schema)
    }

    // MARK: Sightings

    public func recordSightings(_ observations: [SightingObservation]) throws -> [Sighting] {
        try requireWrite()
        let observations = try roundTrip(observations)
        return try connection.transaction {
            var order: [SightingKey] = []
            var merged: [SightingKey: Sighting] = [:]
            for observation in observations {
                let key = observation.key
                if merged[key] == nil, let stored = try loadSighting(key) { merged[key] = stored }
                if var sighting = merged[key] {
                    sighting.merge(observation)
                    merged[key] = sighting
                } else {
                    merged[key] = Sighting(first: observation)
                }
                if !order.contains(key) { order.append(key) }
            }
            let sightings = order.compactMap { merged[$0] }
            for sighting in sightings {
                try connection.query(
                    """
                    INSERT INTO sightings (bundle_id, window_family, identity_key, record) VALUES (?, ?, ?, ?)
                    ON CONFLICT (bundle_id, window_family, identity_key) DO UPDATE SET record = excluded.record
                    """,
                    Self.bindings(sighting.key) + [.text(try json(sighting))]
                )
            }
            return sightings
        }
    }

    public func sightings(in bundleIDs: Set<String>) throws -> [Sighting] {
        guard !bundleIDs.isEmpty else { return [] }
        let (clause, bindings) = Self.bundleFilter(bundleIDs)
        return try rows(Sighting.self, table: "sightings", "SELECT record FROM sightings WHERE \(clause)", bindings)
            .sorted(by: Sighting.isOrderedBefore)
    }

    // MARK: Experiences

    public func record(_ event: ExperienceEvent) throws -> ExperienceRecording {
        try requireWrite()
        let event = try roundTrip(event)
        return try connection.transaction {
            let previous = try rows(ExperienceHistoryEntry.self, table: "experience_events",
                                    "SELECT entry FROM experience_events WHERE event_id = ?", [.text(event.id)]).first
            let target: ExperienceRecord? = switch event.subject {
                case .step(let draft)   : try experience(naturalKey: draft.naturalKey)
                case .experience(let id): try experience(id: id)
                case .unattributed      : nil
            }
            switch try ExperienceEventRule.resolve(event, previous: previous, target: target, newID: makeID) {
                case .duplicate(let id):
                    return .duplicate(try id.flatMap { try experience(id: $0) })
                case .write(let entry, let record):
                    if let record {
                        try connection.query(
                            """
                            INSERT INTO experiences (id, natural_key, bundle_id, record) VALUES (?, ?, ?, ?)
                            ON CONFLICT (id) DO UPDATE SET record = excluded.record
                            """,
                            [.text(record.id.rawValue), .text(record.draft.naturalKey),
                             .text(record.context.bundleID), .text(try json(record))]
                        )
                    }
                    try connection.query(
                        "INSERT INTO experience_events (event_id, experience_id, entry) VALUES (?, ?, ?)",
                        [.text(event.id), entry.experienceID.map { .text($0.rawValue) } ?? .null,
                         .text(try json(entry))]
                    )
                    return .applied(record)
            }
        }
    }

    public func experiences(in bundleIDs: Set<String>) throws -> [ExperienceRecord] {
        guard !bundleIDs.isEmpty else { return [] }
        let (clause, bindings) = Self.bundleFilter(bundleIDs)
        return try rows(ExperienceRecord.self, table: "experiences",
                        "SELECT record FROM experiences WHERE \(clause)", bindings)
            .sorted(by: ExperienceRecord.isOrderedBefore)
    }

    public func history(of experience: ExperienceID) throws -> [ExperienceHistoryEntry] {
        try rows(ExperienceHistoryEntry.self, table: "experience_events",
                 "SELECT entry FROM experience_events WHERE experience_id = ? ORDER BY sequence",
                 [.text(experience.rawValue)])
    }

    public func candidates(for phrase: String, in bundleIDs: Set<String>?) throws -> [ExperienceRecord] {
        let tokens = Set(GoalPhrase.tokens(phrase))
        let all: [ExperienceRecord]
        if let bundleIDs {
            all = try experiences(in: bundleIDs)
        } else {
            all = try rows(ExperienceRecord.self, table: "experiences", "SELECT record FROM experiences", [])
                .sorted(by: ExperienceRecord.isOrderedBefore)
        }
        return all.filter { $0.isCandidate(forPhraseTokens: tokens) }
    }

    // MARK: Recall decisions

    public func record(_ decision: RecallDecisionRecord) throws {
        try requireWrite()
        let decision = try roundTrip(decision)
        try connection.transaction {
            let previous = try rows(RecallDecisionRecord.self, table: "recall_decisions",
                                    "SELECT record FROM recall_decisions WHERE decision_id = ?", [.text(decision.id)])
            if let previous = previous.first {
                guard previous == decision else { throw LivingMemoryError.conflictingDecision(id: decision.id) }
                return
            }
            try connection.query(
                "INSERT INTO recall_decisions (decision_id, experience_id, record) VALUES (?, ?, ?)",
                [.text(decision.id), decision.experienceID.map { .text($0.rawValue) } ?? .null,
                 .text(try json(decision))]
            )
        }
    }

    public func decisions(about experience: ExperienceID) throws -> [RecallDecisionRecord] {
        try rows(RecallDecisionRecord.self, table: "recall_decisions",
                 "SELECT record FROM recall_decisions WHERE experience_id = ? ORDER BY sequence",
                 [.text(experience.rawValue)])
    }

    // MARK: Rows

    private func requireWrite() throws {
        guard access == .readWrite else { throw SQLiteLivingMemoryError.readOnly(path: file.path) }
    }

    private func loadSighting(_ key: SightingKey) throws -> Sighting? {
        try rows(Sighting.self, table: "sightings",
                 "SELECT record FROM sightings WHERE bundle_id = ? AND window_family = ? AND identity_key = ?",
                 Self.bindings(key)).first
    }

    private func experience(id: ExperienceID) throws -> ExperienceRecord? {
        try rows(ExperienceRecord.self, table: "experiences", "SELECT record FROM experiences WHERE id = ?",
                 [.text(id.rawValue)]).first
    }

    private func experience(naturalKey: String) throws -> ExperienceRecord? {
        try rows(ExperienceRecord.self, table: "experiences", "SELECT record FROM experiences WHERE natural_key = ?",
                 [.text(naturalKey)]).first
    }

    /// Decodes the first column of every row. A row that does not decode is reported, never skipped.
    private func rows<T: Decodable & Sendable>(
        _ type    : T.Type,
        table     : String,
        _ sql     : String,
        _ bindings: [SQLiteConnection.Value]
    ) throws -> [T] {
        var values: [T] = []
        try connection.query(sql, bindings) { row in
            let text = row.text(0) ?? ""
            do {
                values.append(try decoder.decode(T.self, from: Data(text.utf8)))
            } catch {
                throw SQLiteLivingMemoryError.corruptRecord(table: table, key: String(text.prefix(80)))
            }
        }
        return values
    }

    private func json(_ value: some Encodable) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// The value as it will read back, so a repeated write compares equal to the stored one even
    /// when a date carried more precision than the stored milliseconds.
    private func roundTrip<T: Codable & Sendable>(_ value: T) throws -> T {
        try decoder.decode(T.self, from: try encoder.encode(value))
    }

    private static func bindings(_ key: SightingKey) -> [SQLiteConnection.Value] {
        [.text(key.context.bundleID), .text(key.context.windowFamily), .text(key.identity.storageKey)]
    }

    private static func bundleFilter(_ bundleIDs: Set<String>) -> (String, [SQLiteConnection.Value]) {
        let sorted = bundleIDs.sorted()
        let placeholders = Array(repeating: "?", count: sorted.count).joined(separator: ", ")
        return ("bundle_id IN (\(placeholders))", sorted.map { .text($0) })
    }
}
