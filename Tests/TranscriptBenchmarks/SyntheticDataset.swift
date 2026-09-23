//
//  SyntheticDataset.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation
import Workspace

/// SyntheticDataset is the reproducible load of §20.1, written to a store in
/// a temporary directory: one conversation of 10,000 messages, 50,000 events
/// in all, long code blocks, and teams of 1, 20 and 100 workers.
///
/// Deterministic: every id, text and time comes from one seeded generator, so
/// two runs write the same rows in the same order, and `digest` says so. It
/// is written through the store's own public writes, one row at a time, and
/// nothing generated is kept once it is written, so memory holds one message
/// at a time and not the history.
///
/// Generating takes a while, so a finished store is kept under its version
/// and seed and reused: `complete` marks a store that finished writing. A
/// benchmark that writes works on a copy (`copy(to:)`), never on this one.
struct SyntheticDataset: Sendable {

    static let version = 1

    let seed     : UInt64
    let directory: URL

    /// The team of one's conversation, the 10,000 message one.
    let solo    : UUID
    let team20  : UUID
    let team100 : UUID

    static let soloTurns        = 5_000
    static let soloToolsPerTurn = 6
    static let teamTurns        = 250
    static let teamToolsPerTurn = 18

    static let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static let workspaceID = UUID(uuidString: "5EED0000-0000-4000-8000-000000000001") ?? UUID()

    init(seed: UInt64 = 2026) {
        self.seed = seed
        directory = URL.temporaryDirectory.appending(path: "MecumTranscriptDataset-v\(Self.version)-\(seed)",
                                                     directoryHint: .isDirectory)
        var ids = Generator(seed: seed ^ 0xC0FFEE)
        solo    = ids.uuid()
        team20  = ids.uuid()
        team100 = ids.uuid()
    }

    private var marker: URL { directory.appending(path: "complete.txt") }

    /// The digest written when the store finished, or nil when it has not.
    var complete: String? {
        do { return try String(contentsOf: marker, encoding: .utf8) } catch { return nil }
    }

    /// The id of the solo conversation's message at `sequence`, derived from
    /// the seed again without reading the store.
    func soloMessageID(sequence: Int) -> UUID {
        var ids = Generator(seed: seed ^ UInt64(sequence) &* 0x9E37_79B9_7F4A_7C15)
        return ids.uuid()
    }

    /// Writes the store unless a complete one is there, and returns its digest.
    func prepare(progress: (String) -> Void) async throws -> String {
        if let digest = complete { return digest }
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        let store  = try WorkspaceStore.opening(in: directory)
        var random = Generator(seed: seed)
        var digest = Digest()

        let solos = try await team(of: 1, in: store, random: &random)
        let twenty = try await team(of: 20, in: store, random: &random)
        let hundred = try await team(of: 100, in: store, random: &random)
        try await store.createConversation(id: solo, kind: .direct, participants: solos)
        try await store.createConversation(id: team20, kind: .room, participants: twenty)
        try await store.createConversation(id: team100, kind: .room, participants: hundred)

        var clock = 0.0
        for turn in 0..<Self.soloTurns {
            try await write(turn: turn, in: solo, workers: solos, tools: Self.soloToolsPerTurn, store: store,
                            random: &random, clock: &clock, digest: &digest, fixedIDs: true)
            if turn % 500 == 0 { progress("solo turn \(turn) of \(Self.soloTurns)") }
        }
        for (conversation, workers) in [(team20, twenty), (team100, hundred)] {
            for turn in 0..<Self.teamTurns {
                try await write(turn: turn, in: conversation, workers: workers, tools: Self.teamToolsPerTurn,
                                store: store, random: &random, clock: &clock, digest: &digest, fixedIDs: false)
            }
            progress("team of \(workers.count) written")
        }
        let value = digest.hex
        try value.write(to: marker, atomically: true, encoding: .utf8)
        return value
    }

    /// Copies the finished store to `destination`, for a benchmark that writes.
    func copy(to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: directory, to: destination)
    }

    // MARK: Writing

    /// `size` workers.
    private func team(of size: Int, in store: WorkspaceStore, random: inout Generator) async throws -> [UUID] {
        var ids: [UUID] = []
        for index in 0..<size {
            let worker = try await store.createWorker(
                id        : random.uuid(),
                name      : "Worker \(size)-\(index)",
                appearance: WorkerAppearance(seed: Int64(random.next() % 1000), palette: "tide")
            )
            ids.append(worker.id)
        }
        return ids
    }

    /// One turn: the person's question, the execution with its tool calls,
    /// the worker's reply and the completion. The solo conversation takes
    /// its message ids from `soloMessageID`, so a benchmark can name one.
    private func write(
        turn       : Int,
        in conversation: UUID,
        workers    : [UUID],
        tools      : Int,
        store      : WorkspaceStore,
        random     : inout Generator,
        clock      : inout Double,
        digest     : inout Digest,
        fixedIDs   : Bool
    ) async throws {
        let worker  = workers[Int(random.next() % UInt64(workers.count))]
        let subject = random.uuid()
        let question = Self.question(turn, random: &random)
        let reply    = Self.reply(turn, random: &random)
        let first    = 2 * turn + 1
        clock += 30

        let questionID = fixedIDs ? soloMessageID(sequence: first) : random.uuid()
        try await store.appendMessage(to: conversation, id: questionID, text: question,
                                      at: Self.origin.addingTimeInterval(clock), delivery: .completed)
        digest.add(question)
        try await event(.executionStarted, subject, conversation, worker, clock + 1, nil, store, &random)
        for call in 0..<tools {
            let line = call % 2 == 0 ? "→ read_file {\"path\":\"Sources/File\(turn % 97).swift\"}"
                                     : "← read_file {\"lines\":\(random.next() % 400)}"
            try await event(.toolActivity, subject, conversation, worker, clock + 2 + Double(call) * 0.1, line,
                            store, &random)
            digest.add(line)
        }
        let replyID = fixedIDs ? soloMessageID(sequence: first + 1) : random.uuid()
        try await store.appendMessage(to: conversation, id: replyID, author: worker, text: reply,
                                      at: Self.origin.addingTimeInterval(clock + 5), delivery: .completed)
        digest.add(reply)
        try await event(.executionCompleted, subject, conversation, worker, clock + 6, nil, store, &random)
    }

    private func event(
        _ type        : EventType,
        _ subject     : UUID,
        _ conversation: UUID,
        _ worker      : UUID,
        _ second      : Double,
        _ text        : String?,
        _ store       : WorkspaceStore,
        _ random      : inout Generator
    ) async throws {
        try await store.append(NewEvent(
            id            : random.uuid(),
            workspaceID   : Self.workspaceID,
            subjectID     : subject,
            conversationID: conversation,
            workerID      : worker,
            timestamp     : Self.origin.addingTimeInterval(second),
            type          : type,
            payload       : text.map { Data($0.utf8) }
        ))
    }

    // MARK: Text

    static func question(_ turn: Int, random: inout Generator) -> String {
        let topics = ["the capture suite", "the sidebar width", "the release branch", "the flaky display test",
                      "the migration", "the transcript anchor"]
        return "Turn \(turn): can you look at \(topics[Int(random.next() % UInt64(topics.count))]) again?"
    }

    /// Prose, a list, and on every tenth turn a code block of 80 to 200 lines.
    static func reply(_ turn: Int, random: inout Generator) -> String {
        var text = "Looked at it in turn \(turn). "
            + String(repeating: "The suite passes after the change, and the log is clean. ",
                     count: 1 + Int(random.next() % 6))
        text += "\n\n- checked the **build**\n- ran `make test`\n- read the [log](https://example.com/log/\(turn))"
        if turn % 10 == 0 {
            let lines = 80 + Int(random.next() % 121)
            text += "\n\n```swift\n"
            for line in 0..<lines {
                text += "    let value\(line) = try await compute(step: \(line), retries: \(random.next() % 5))"
                    + " // keeps going past the width of a bubble\n"
            }
            text += "```"
        }
        return text
    }
}

extension SyntheticDataset {

    /// Generator is SplitMix64: small, fast and the same on every run and machine.
    struct Generator: Sendable {

        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }

        mutating func uuid() -> UUID {
            let high = next(), low = next()
            let bytes = (0..<8).map { UInt8(truncatingIfNeeded: high >> ($0 * 8)) }
                + (0..<8).map { UInt8(truncatingIfNeeded: low >> ($0 * 8)) }
            return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6] & 0x0F | 0x40,
                               bytes[7], bytes[8] & 0x3F | 0x80, bytes[9], bytes[10], bytes[11], bytes[12],
                               bytes[13], bytes[14], bytes[15]))
        }
    }

    /// Digest is FNV-1a over every text written, in order: equal digests from
    /// two runs mean the same dataset.
    struct Digest: Sendable {

        private var value: UInt64 = 0xCBF2_9CE4_8422_2325

        mutating func add(_ text: String) {
            for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        }

        var hex: String { String(value, radix: 16) }
    }
}
