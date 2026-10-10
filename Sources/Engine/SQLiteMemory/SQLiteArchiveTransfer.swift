//
//  SQLiteArchiveTransfer.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 09/10/2026.
//

import Foundation
import Memory
import SQLite3

/// SQLiteArchiveTransfer moves the knowledge of an earlier archive (an external client's private archive
/// of schema 1) into the user's one archive, without changing the earlier archive and without copying its
/// file: its facts are offered again through the same codecs every producer uses, with their source.
///
/// 1. The source is copied through the backup API, consistent as of one read transaction, to a staging
///    file, which is opened as an archive (migrated to the current schema if it is an earlier one); the
///    source itself is only read. A source whose schema this build refuses is `refused`, untouched.
/// 2. A source holding facts this transfer does not carry (Watcher inputs, correlations, verifications,
///    tasks, procedures, experiences, menu commands) is `refused` whole, so nothing is half merged.
/// 3. Every event, in the source's local order, is written with its call's planned and started state
///    and its samples, one transaction each, together with its row in `memory_origin_events`. An event
///    whose identity the destination holds with the same content is a proven duplicate: mapped, never
///    written twice, and it adds no evidence. One whose identity holds other content is written under a
///    new identity in the origin's namespace, and every reference to it (a batch's parent, an
///    observation's origin, a sample, a result) follows the mapping. Then every call's end.
/// 4. `importBase`, the caller's, runs: the Brains of the earlier JSON files of the origin, merged element
///    by element into the destination's (`BrainMerge`), with each contribution journaled under the origin,
///    before anything is learned into them. A Brain that could not be merged stops the transfer, which
///    resumes on the next open; an element excluded from a merge makes the origin `partial`.
/// 5. The source's Brain applications are applied again in their order, under the mapped keys, through
///    the destination's own algorithm: a key already applied is `alreadyApplied` and teaches nothing
///    twice. The samples' scene associations are offered again the same way.
///
/// The journal (`memory_archive_origins`) says where an origin stands; a transfer that stops (a crash, a
/// full device) leaves it `in_progress` or `failed`, and a later one resumes it: what was transferred is
/// recognized by its mapping and skipped, everything else is idempotent. The staging copy is removed once
/// the transfer ends, whatever its outcome; the source is never written.
package enum SQLiteArchiveTransfer {

    /// Stage is a point of the transfer a test may stop it at, as a process ending there would.
    package enum Stage: Sendable, Equatable {
        case copied
        case event(Int)
        case factsTransferred
        case baseImported
        case application(Int)
    }

    /// Report is what one transfer did, read back from the journal.
    package struct Report: Sendable, Equatable {
        package let originID: String
        package let status: String
        package let eventsAdded: Int
        package let eventsDuplicate: Int
        package let eventsRenamed: Int
        package let applicationsAdded: Int
        package let applicationsDuplicate: Int
        package let brainsImported: Int
        package let detail: String?
    }

    /// The tables of facts this transfer does not carry: a source with rows in any of them is refused.
    static let untransferred = [
        "memory_input_events", "memory_action_correlations", "memory_verifications", "memory_task_occurrences",
        "memory_task_events", "memory_task_labels", "memory_routes", "memory_step_occurrences", "memory_experiences",
        "brain_menu_commands", "memory_tasks", "memory_call_effects", "memory_value_redactions",
        "memory_call_recording_gaps", "memory_origin_brain_contributions",
    ]

    /// The statuses an origin keeps once its transfer ended: it is not offered again unless its archive
    /// grew since.
    package static let ended: Set<String> = ["completed", "partial", "refused"]

    /// How an origin's journal row concludes once everything was offered: `partial` when its Brains had
    /// elements excluded, said in the detail, `completed` otherwise, with the Brains merged counted from
    /// its contributions.
    private static let concluding = """
        status = CASE WHEN EXISTS (
                SELECT 1 FROM memory_origin_brain_contributions c
                WHERE c.origin_id = memory_archive_origins.origin_id AND c.disposition = 'excluded'
            ) THEN 'partial' ELSE 'completed' END,
        brains_imported = (
            SELECT count(DISTINCT c.bundle_id) FROM memory_origin_brain_contributions c
            WHERE c.origin_id = memory_archive_origins.origin_id AND c.disposition = 'added'
        ),
        detail = (
            SELECT CASE WHEN count(*) = 0 THEN NULL ELSE count(*) || ' elements of its JSON Brains were not taken in '
                || '(an identity another application holds here, an anchor not in the Brain, a group that lost '
                || 'members, an effect holding a withheld value); they stay in its files' END
            FROM memory_origin_brain_contributions c
            WHERE c.origin_id = memory_archive_origins.origin_id AND c.disposition = 'excluded'
        )
        """

    /// TransferError is a transfer that could not end for a reason of the transfer itself; the origin is
    /// left to a later open, never certified.
    package enum TransferError: Error, Sendable, Equatable, CustomStringConvertible {
        /// Another opener held the origin's transfer past the wait.
        case busy(origin: String)
        /// The verified staging copy is no longer the one this attempt made: missing, emptied or replaced.
        case stagingLost(String)
        /// What reached the destination does not match the snapshot: how many facts, and the first.
        case incomplete(String)
        /// The journal shows another attempt took the origin over: this one publishes nothing.
        case superseded(origin: String)

        package var description: String {
            switch self {
                case .busy(let origin)      : "another opener is transferring \(origin)"
                case .stagingLost(let why)  : "the staging copy is not the one this attempt made: \(why)"
                case .incomplete(let why)   : "the shared archive does not hold the snapshot: \(why)"
                case .superseded(let origin): "another attempt took over the transfer of \(origin)"
            }
        }
    }

    /// The pause between two tries of the origin's lock while another opener holds it.
    static let lockStep: Duration = .milliseconds(50)

    /// Transfers the source archive into `destination` under `originID`, recorded at `location`.
    ///
    /// The transfer of one origin into one destination is one at a time across instances and processes:
    /// it holds the origin's lock (`coordinated`), waiting up to `lockWait` for another opener's, and
    /// first looks again whether the origin still needs it. Each attempt copies into a directory of its
    /// own under `staging`, opens that copy only as the existing file it made and checks its token, and
    /// publishes the journal's end only after checking the destination holds the snapshot, and only while
    /// the journal still names it.
    package static func transfer(
        from source  : URL,
        origin originID: String,
        location     : String,
        into destination: SQLiteMemoryStore,
        staging      : URL,
        nowMS        : Int64,
        lockWait     : Duration = .seconds(30),
        importBase   : @Sendable () async throws -> Void = {},
        at stage     : (@Sendable (Stage) async throws -> Void)? = nil
    ) async throws -> Report {
        let stage = stage ?? { _ in }
        return try await coordinated(destination: destination, origin: originID, wait: lockWait) {
            // Under the lock nobody else transfers this origin: what the journal says stays so until this writes.
            guard await needsTransfer(source: source, origin: originID, into: destination) else {
                return try await report(destination, originID)
            }
            removeResidualStaging(in: staging, origin: originID)
            let attempt = UUID().uuidString
            try await begin(destination, originID, location: location, nowMS: nowMS, attempt: attempt)
            let directory = staging.appendingPathComponent("\(slug(originID))-\(attempt)", isDirectory: true)
            defer {
                removeStaging(directory)
                // The staging root goes too once empty; rmdir(2) never removes what another origin keeps in it.
                rmdir(staging.path)
            }
            do {
                let (copy, token) = try await stagingCopy(of: source, in: directory)
                try await stage(.copied)
                let store = try await openCopy(copy, token: token)
                do {
                    let report = try await transferFacts(
                        from: store,
                        origin: originID,
                        location: location,
                        into: destination,
                        nowMS: nowMS,
                        attempt: attempt,
                        importBase: importBase,
                        at: stage
                    )
                    await store.close()
                    return report
                } catch {
                    await store.close()
                    throw error
                }
            } catch let refusal as MemoryStoreError where refusal.isSchemaRefusal {
                let detail = "the archive's schema is not one this build reads; it is left as it is"
                try? await end(destination, originID, nowMS: nowMS, attempt: attempt, status: "refused", detail: detail)
                return try await report(destination, originID)
            } catch {
                let detail = "the transfer stopped (\(error)); it resumes on the next open"
                try? await end(destination, originID, nowMS: nowMS, attempt: attempt, status: "failed", detail: detail)
                throw error
            }
        }
    }

    // MARK: Coordination

    /// Runs `body` holding the lock of the origin's transfer into this destination: `flock(2)` on a file
    /// beside the destination archive (`.unification/<origin>.lock`), which is never deleted, so every
    /// instance and process that transfers through this code excludes the others, and the kernel lets go
    /// of a dead holder's. While another holds it this waits in steps, cancellable (a closing service
    /// cancels its unification), and gives up past `wait` with `busy`, the origin left to a later open.
    package static func coordinated<T: Sendable>(
        destination: SQLiteMemoryStore,
        origin     : String,
        wait       : Duration,
        _ body     : () async throws -> T
    ) async throws -> T {
        let root = destination.url.resolvingSymlinksInPath().deletingLastPathComponent()
            .appendingPathComponent(".unification", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let key = root.appendingPathComponent(slug(origin))
        let deadline = ContinuousClock.now + wait
        var held: SQLiteMemoryPresence?
        while held == nil {
            try Task.checkCancellation()
            held = try SQLiteMemoryPresence.take(.exclusive, of: key)
            if held == nil {
                guard ContinuousClock.now < deadline else { throw TransferError.busy(origin: origin) }
                try await Task.sleep(for: lockStep)
            }
        }
        defer { held?.release() }
        return try await body()
    }

    /// The origin's name as a file name: what its lock and its attempts' directories are called.
    package static func slug(_ origin: String) -> String {
        String(origin.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
    }

    // MARK: The journal

    /// Journals the origin in progress under this attempt, whatever an attempt that ended left.
    private static func begin(_ destination: SQLiteMemoryStore, _ origin: String, location: String, nowMS: Int64,
                              attempt: String) async throws {
        try await journal(destination, origin, location: location, nowMS: nowMS, status: "in_progress",
                          detail: "attempt \(attempt)")
    }

    /// Ends the attempt's journal row with `status`, only while the row is still this attempt's.
    private static func end(_ destination: SQLiteMemoryStore, _ origin: String, nowMS: Int64, attempt: String,
                            status: String, detail: String?) async throws {
        _ = try await destination.write { transaction in
            try owned(transaction, origin, attempt: attempt)
            try transaction.execute(
                "UPDATE memory_archive_origins SET status = ?, updated_at_ms = ?, detail = ? WHERE origin_id = ?",
                [.text(status), .integer(nowMS), detail.map(SQLiteValue.text) ?? .null, .text(origin)]
            )
        }
    }

    /// Throws `superseded` unless the origin's row is in progress under this attempt.
    private static func owned(_ transaction: SQLiteTransaction, _ origin: String, attempt: String) throws {
        let row = try transaction.query(
            "SELECT status, detail FROM memory_archive_origins WHERE origin_id = ?",
            [.text(origin)]
        ) { (status: try $0.text(0) ?? "", detail: try $0.text(1)) }.first
        guard let row, row.status == "in_progress", row.detail == "attempt \(attempt)" else {
            throw TransferError.superseded(origin: origin)
        }
    }

    /// Steps 2 to 5 over the opened staging copy.
    private static func transferFacts(
        from store   : SQLiteMemoryStore,
        origin originID: String,
        location     : String,
        into destination: SQLiteMemoryStore,
        nowMS        : Int64,
        attempt      : String,
        importBase   : @Sendable () async throws -> Void,
        at stage     : @Sendable (Stage) async throws -> Void
    ) async throws -> Report {
        do {
            let version = Int64(try await store.diagnostics().migration?.fromVersion ?? SQLiteMemorySchema.version)
            if let held = try await untransferredRows(store) {
                let detail = "the archive holds facts this migration does not transfer: \(held); nothing was taken from it"
                try await end(destination, originID, nowMS: nowMS, attempt: attempt, status: "refused", detail: detail)
                return try await report(destination, originID)
            }
            var counts = Counts()
            let admission = try await admission(of: store)
            let events = try await store.read { snapshot in
                try snapshot.query("SELECT event_id, local_order FROM memory_events ORDER BY local_order") {
                    (id: try $0.text(0) ?? "", order: $0.integer(1) ?? 0)
                }
            }
            var mapping = try await mappings(destination, originID)
            for (index, event) in events.enumerated() where mapping[event.id] == nil {
                try await transferEvent(
                    event.id,
                    from: store,
                    into: destination,
                    origin: originID,
                    admission: admission,
                    mapping: &mapping,
                    counts: &counts
                )
                try await stage(.event(index))
            }
            for event in events {
                try await transferEnd(event.id, from: store, into: destination, admission: admission, mapping: mapping)
            }
            try await stage(.factsTransferred)
            try await importBase()
            try await stage(.baseImported)
            let applications = SQLiteBrainApplicationRepository(store: destination)
            let sourceApplications = SQLiteBrainApplicationRepository(store: store)
            let keys = try await applicationKeys(store)
            for (index, key) in keys.enumerated() {
                guard let stored = try await sourceApplications.application(key) else { continue }
                let moved = try remapped(stored.command, mapping)
                let (admitted, withheld) = try admission.minimize(application: moved)
                guard let command = admitted else {
                    // Its effect held a withheld value: learning it would teach the Brain to predict the marker.
                    try await journal(application: moved, .excluded, origin: originID, into: destination)
                    try await stage(.application(index))
                    continue
                }
                if withheld { try await journal(application: command, .added, origin: originID, into: destination) }
                let result = try await applications.apply(command)
                if result.receipt == .committed {
                    counts.applicationsAdded += 1
                } else {
                    counts.applicationsDuplicate += 1
                }
                try await stage(.application(index))
            }
            let scenes = SQLiteSceneRepository(store: destination)
            for key in try await sampleKeys(store) where key.phase.isAssociable {
                _ = try await scenes.associate(
                    CaptureSampleKey(
                        eventID: mapping[key.eventID] ?? key.eventID,
                        phase: key.phase,
                        ordinal: key.ordinal
                    ),
                    at: nowMS
                )
            }
            // The end is published only once the destination is shown to hold the snapshot.
            try await verify(store, origin: originID, into: destination)
            let final = counts, last = events.last?.order ?? 0, empty = events.isEmpty
            _ = try await destination.write { transaction in
                try owned(transaction, originID, attempt: attempt)
                try transaction.execute(
                    """
                    UPDATE memory_archive_origins
                    SET updated_at_ms = ?, source_schema_version = ?, high_local_order = ?,
                        events_added = events_added + ?, events_duplicate = events_duplicate + ?,
                        events_renamed = events_renamed + ?, applications_added = applications_added + ?,
                        applications_duplicate = applications_duplicate + ?,
                    \(concluding)
                    WHERE origin_id = ?
                    """,
                    [.integer(nowMS), .integer(version), .integer(last), .integer(Int64(final.eventsAdded)),
                     .integer(Int64(final.eventsDuplicate)), .integer(Int64(final.eventsRenamed)),
                     .integer(Int64(final.applicationsAdded)), .integer(Int64(final.applicationsDuplicate)),
                     .text(originID)]
                )
                if empty {
                    // An origin that held nothing is complete; the detail tells it from a copy that was lost.
                    try transaction.execute(
                        "UPDATE memory_archive_origins SET detail = ? WHERE origin_id = ? AND detail IS NULL",
                        [.text("the origin's archive held no facts"), .text(originID)]
                    )
                }
            }
            return try await report(destination, originID)
        }
    }

    // MARK: The staging copy

    /// Copies the source, consistent as of one read transaction, to `directory/archive.sqlite`, a
    /// directory this attempt makes and owns, verified, and marks the copy with a token of its own
    /// (`application_id`, which the store neither sets nor checks), so the file opened later can be told
    /// to be this copy. The source is opened read only; one whose write-ahead log files are not beside it,
    /// which a read-only connection cannot make, is opened for reading through a read-write connection
    /// that writes nothing.
    private static func stagingCopy(of source: URL, in directory: URL) async throws -> (copy: URL, token: Int32) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy  = directory.appendingPathComponent("archive.sqlite")
        let token = Int32.random(in: 1...Int32.max)
        guard let presence = try SQLiteMemoryPresence.take(.shared, of: source) else {
            throw MemoryStoreError.unavailable(.interruptedRecovery("a recovery holds the source archive"))
        }
        defer { presence.release() }
        let reader = try readableConnection(to: source)
        defer { reader.close() }
        let target = try SQLiteConnection(path: copy.path)
        defer { target.close() }
        try reader.execute("BEGIN")
        defer { _ = try? reader.execute("COMMIT") }
        let backup = try SQLiteBackup(from: reader, to: target)
        while try backup.step(pages: 1024).remaining > 0 { await Task.yield() }
        try backup.finish()
        guard try target.query("PRAGMA integrity_check", [], { try $0.text(0) ?? "" }) == ["ok"] else {
            throw MemoryStoreError.snapshot(.copyFailedIntegrityCheck(["the staging copy failed its integrity check"]))
        }
        // A pragma takes no bound value; the token is this attempt's own number.
        try target.execute("PRAGMA application_id = \(token)")
        return (copy, token)
    }

    /// The staging copy opened as the existing file this attempt made: never created, an earlier schema
    /// migrated in it, and its token checked once open. A file that is missing, emptied or replaced is
    /// `stagingLost`; a schema refusal is the source's only while the refused file still carries the token.
    private static func openCopy(_ copy: URL, token: Int32) async throws -> SQLiteMemoryStore {
        let store: SQLiteMemoryStore
        do {
            store = try await SQLiteMemoryStore.open(at: copy, opening: .existingCopy)
        } catch {
            guard stagedToken(at: copy) == token else {
                throw TransferError.stagingLost("the copy is missing, empty or another file (\(error))")
            }
            throw error
        }
        let found = try? await store.read { snapshot in
            try snapshot.query("PRAGMA application_id") { $0.integer(0) }.first ?? nil
        }
        guard found == Int64(token) else {
            await store.close()
            throw TransferError.stagingLost("the file opened does not carry this attempt's token")
        }
        return store
    }

    /// The token of the file at the URL, read without creating or changing it; nil when it cannot be read.
    private static func stagedToken(at url: URL) -> Int32? {
        guard let connection = try? SQLiteConnection(path: url.path, readOnly: true, mayCreate: false) else {
            return nil
        }
        defer { connection.close() }
        guard let value = (try? connection.query("PRAGMA application_id", [], { $0.integer(0) }))?.first ?? nil else {
            return nil
        }
        return Int32(truncatingIfNeeded: value)
    }

    /// A connection that reads the source: read only when the library can, else read-write, which
    /// writes nothing but may make the log files a read-only connection cannot.
    private static func readableConnection(to source: URL) throws -> SQLiteConnection {
        if let reader = try? SQLiteConnection(path: source.path, readOnly: true, mayCreate: false) {
            if (try? reader.query("SELECT count(*) FROM sqlite_schema", [], { $0.integer(0) })) != nil { return reader }
            reader.close()
        }
        return try SQLiteConnection(path: source.path, readOnly: false, mayCreate: false)
    }

    private static func removeStaging(_ staging: URL) {
        try? FileManager.default.removeItem(at: staging)
    }

    /// Removes the directories earlier attempts of the origin left under `staging`: called under the
    /// origin's lock, when no other attempt of it can be running, so each belongs to an attempt that ended
    /// (a crash, a stop). Other origins' directories are never touched.
    private static func removeResidualStaging(in staging: URL, origin: String) {
        let prefix = slug(origin) + "-"
        let children = (try? FileManager.default.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: nil
        )) ?? []
        for child in children where child.lastPathComponent.hasPrefix(prefix) { removeStaging(child) }
    }

    // MARK: Facts

    private struct Counts {
        var eventsAdded = 0, eventsDuplicate = 0, eventsRenamed = 0, applicationsAdded = 0, applicationsDuplicate = 0
    }

    /// Writes one source event, with its call planned and started and its samples, and its mapping, in one
    /// transaction. A batch's parent brings its steps; a step is written with its parent.
    private static func transferEvent(
        _ id            : String,
        from store      : SQLiteMemoryStore,
        into destination: SQLiteMemoryStore,
        origin          : String,
        admission       : ValueMinimization,
        mapping         : inout [String: String],
        counts          : inout Counts
    ) async throws {
        let (event, call, steps, samples) = try await store.read {
            snapshot -> (MemoryEventRecord?, AgentCall?, [AgentCall], [CaptureSample]) in
            guard let event = try SQLiteEventRows.read(snapshot, eventID: id) else { return (nil, nil, [], []) }
            let call = try SQLiteAgentCallRows.call(snapshot, eventID: id)
            var steps: [AgentCall] = []
            if call?.request.tool == .batch {
                let ids = try snapshot.query(
                    "SELECT event_id FROM memory_events WHERE parent_event_id = ? ORDER BY parent_position",
                    [.text(id)]
                ) { try $0.text(0) ?? "" }
                steps = try ids.compactMap { try SQLiteAgentCallRows.call(snapshot, eventID: $0) }
            }
            var samples: [CaptureSample] = []
            for owner in [id] + steps.map(\.event.eventID) {
                for key in try sampleKeys(snapshot, of: owner) {
                    if let sample = try SQLiteObservationRows.sample(snapshot, key: key) { samples.append(sample) }
                }
            }
            return (event, call, steps, samples)
        }
        guard let event else { return }
        if event.parentEventID != nil, call != nil { return }
        // What the archive keeps of the calls and samples, as a live producer would have kept them.
        var minimized: [String: (request: AgentCallRequest, gaps: [ValueRedaction])] = [:]
        for owned in [call].compactMap({ $0 }) + steps {
            let (request, gaps) = admission.minimize(owned.request, eventID: owned.event.eventID)
            minimized[owned.event.eventID] = (request, gaps)
        }
        let requests = minimized
        let admitted = samples.map { admission.minimize(sample: $0) }
        let owners = [event] + steps.map(\.event)
        let known = mapping
        let decided = try await destination.write {
            transaction -> [(source: String, target: String, disposition: String)] in
            var decided: [(source: String, target: String, disposition: String)] = []
            var local = known
            for owner in owners {
                let target: String
                let disposition: String
                if let stored = try SQLiteEventRows.read(transaction, eventID: owner.eventID) {
                    let mapped = remapped(owner, local, as: owner.eventID)
                    if stored.hasSameImmutableContent(as: mapped) {
                        target = owner.eventID
                        disposition = "duplicate"
                    } else {
                        target = "\(owner.eventID)~\(origin)"
                        disposition = "renamed"
                    }
                } else {
                    target = owner.eventID
                    disposition = "added"
                }
                local[owner.eventID] = target
                decided.append((owner.eventID, target, disposition))
            }
            if let call {
                let batch = try AgentCallRecord(
                    event: remapped(call.event, local, as: local[call.event.eventID] ?? call.event.eventID),
                    request: requests[call.event.eventID]?.request ?? call.request
                )
                if steps.isEmpty {
                    _ = try SQLiteAgentCallRows.record(transaction, batch, requestedSteps: call.requestedSteps)
                } else {
                    let records = try steps.map { step in
                        try AgentCallRecord(
                            event: remapped(step.event, local, as: local[step.event.eventID] ?? step.event.eventID),
                            request: requests[step.event.eventID]?.request ?? step.request
                        )
                    }
                    try SQLiteAgentCallRows.validate(batch: batch, steps: records)
                    _ = try SQLiteAgentCallRows.record(transaction, batch, requestedSteps: records.count)
                    for record in records {
                        _ = try SQLiteAgentCallRows.record(transaction, record, requestedSteps: nil)
                    }
                }
                for started in [call] + steps {
                    guard let at = started.startedAtMS else { continue }
                    let target = local[started.event.eventID] ?? started.event.eventID
                    // A duplicate the shared archive already holds concluded keeps its state; its end is
                    // compared later.
                    if try SQLiteAgentCallRows.call(transaction, eventID: target)?.progress.status.isTerminal == true {
                        continue
                    }
                    _ = try SQLiteAgentCallRows.advance(transaction, AgentCallTransition(target, .started(atMS: at)))
                }
            } else {
                _ = try SQLiteEventRows.record(
                    transaction,
                    remapped(event, local, as: local[event.eventID] ?? event.eventID)
                )
            }
            for (source, call) in requests {
                let target = local[source] ?? source
                for gap in call.gaps {
                    _ = try SQLiteOperationFactRows.record(
                        transaction,
                        ValueRedaction(eventID: target, location: gap.location, reason: gap.reason)
                    )
                }
            }
            for (sample, gaps) in admitted {
                var moved = sample
                moved.key = CaptureSampleKey(
                    eventID: local[sample.key.eventID] ?? sample.key.eventID,
                    phase: sample.key.phase,
                    ordinal: sample.key.ordinal
                )
                _ = try SQLiteOperationFactRows.record(transaction, moved)
                for gap in gaps {
                    _ = try SQLiteOperationFactRows.record(
                        transaction,
                        ValueRedaction(eventID: moved.key.eventID, location: gap.location, reason: gap.reason)
                    )
                }
            }
            for entry in decided {
                try transaction.execute(
                    """
                    INSERT OR IGNORE INTO memory_origin_events (origin_id, source_event_id, event_id, disposition)
                    VALUES (?, ?, ?, ?)
                    """,
                    [.text(origin), .text(entry.source), .text(entry.target), .text(entry.disposition)]
                )
            }
            return decided
        }
        for entry in decided {
            mapping[entry.source] = entry.target
            switch entry.disposition {
                case "duplicate": counts.eventsDuplicate += 1
                case "renamed"  : counts.eventsRenamed += 1
                default         : counts.eventsAdded += 1
            }
        }
    }

    /// Writes a transferred call's end, once its samples and the observation events it names are there.
    /// A duplicate already concluded takes the same end as a retry; another end is a conflict.
    private static func transferEnd(_ id: String, from store: SQLiteMemoryStore, into destination: SQLiteMemoryStore,
                                    admission: ValueMinimization, mapping: [String: String]) async throws {
        guard let call = try await store.read({ try SQLiteAgentCallRows.call($0, eventID: id) }),
              call.progress.status.isTerminal else { return }
        let target = mapping[id] ?? id
        let (result, resultGaps) = admission.minimize(result: remapped(call.progress.result, mapping), eventID: target)
        var effectGaps: [ValueRedaction] = []
        var effect = call.progress.observedEffect
        if let observed = effect {
            (effect, effectGaps) = admission.minimize(observed: observed, eventID: target)
        }
        let progress = AgentCallProgress(
            call.progress.status,
            result: result,
            startedAtMS: nil,
            endedAtMS: call.progress.endedAtMS,
            durationMS: call.progress.durationMS,
            observedEffect: effect
        )
        let gaps = resultGaps + effectGaps
        _ = try await destination.write { transaction in
            let moved = try SQLiteAgentCallRows.advance(transaction, AgentCallTransition(target, progress))
            for gap in gaps { _ = try SQLiteOperationFactRows.record(transaction, gap) }
            return moved
        }
    }

    /// The minimization an origin's facts are admitted with: credential shapes, the texts typed into
    /// controls named for a secret, and every text any call of the origin had withheld from its
    /// arguments, wherever else it appears in the origin, as a live producer withholds them.
    private static func admission(of store: SQLiteMemoryStore) async throws -> ValueMinimization {
        let requests = try await store.read { snapshot in
            let ids = try snapshot.query("SELECT event_id FROM memory_agent_actions ORDER BY event_id") {
                try $0.text(0) ?? ""
            }
            return try ids.compactMap { try SQLiteAgentCallRows.call(snapshot, eventID: $0)?.request }
        }
        let rules = ValueMinimization()
        var withheld: [String] = []
        for request in requests {
            let (_, gaps) = rules.minimize(request, eventID: "admission")
            for gap in gaps {
                guard case .argument(let name, let position) = gap.location else { continue }
                for argument in request.arguments where argument.name == name && argument.position == position {
                    if case .text(let text) = argument.value, text != ValueMinimization.marker,
                       !withheld.contains(text) {
                        withheld.append(text)
                    }
                }
            }
        }
        return rules.adding(secrets: withheld)
    }

    /// Journals an application of the origin's Brain the admission withheld a value from: learned again
    /// with it withheld (`added`), or not learned again because its effect held it (`excluded`, which
    /// makes the origin `partial`).
    private static func journal(application command: BrainApplicationCommand, _ disposition: BrainMerge.Disposition,
                                origin: String, into destination: SQLiteMemoryStore) async throws {
        let key = "\(command.key.eventID)/\(command.key.operation.rawValue)"
        _ = try await destination.write { transaction in
            try transaction.execute(
                """
                INSERT OR IGNORE INTO memory_origin_brain_contributions
                    (origin_id, bundle_id, element_kind, element_key, disposition, withheld)
                VALUES (?, ?, 'application', ?, ?, 1)
                """,
                [.text(origin), .text(command.bundleID), .text(key), .text(disposition.rawValue)]
            )
        }
    }

    // MARK: Mapping

    private static func remapped(
        _ event  : MemoryEventRecord,
        _ mapping: [String: String],
        as id    : String
    ) -> MemoryEventRecord {
        var moved = event
        moved.eventID       = id
        moved.parentEventID = event.parentEventID.map { mapping[$0] ?? $0 }
        moved.originEventID = event.originEventID.map { mapping[$0] ?? $0 }
        return moved
    }

    private static func remapped(_ request: AgentCallRequest, _ mapping: [String: String]) -> AgentCallRequest {
        request
    }

    private static func remapped(_ result: AgentCallResult?, _ mapping: [String: String]) -> AgentCallResult? {
        guard case .observation(let observation)? = result else { return result }
        let sample = CaptureSampleKey(eventID: mapping[observation.sample.eventID] ?? observation.sample.eventID,
                                      phase: observation.sample.phase, ordinal: observation.sample.ordinal)
        return .observation(ObservationResult(
            sessionID: observation.sessionID,
            sessionRevision: observation.sessionRevision,
            observedAtMS: observation.observedAtMS,
            sample: sample
        ))
    }

    private static func remapped(
        _ command: BrainApplicationCommand,
        _ mapping: [String: String]
    ) throws -> BrainApplicationCommand {
        try BrainApplicationCommand(key: remapped(command.key, mapping), bundleID: command.bundleID,
                                    requestedAtMS: command.requestedAtMS, input: command.input)
    }

    private static func remapped(_ key: BrainApplicationKey, _ mapping: [String: String]) -> BrainApplicationKey {
        let event = mapping[key.eventID] ?? key.eventID
        return switch key.operation {
            case .observe : .observe(CaptureSampleKey(
                eventID: event,
                phase: key.sample?.phase ?? .current,
                ordinal: key.sample?.ordinal ?? 0
            ))
            case .record  : .record(eventID: event)
            case .setName : .setName(eventID: event)
        }
    }

    // MARK: Verification

    /// Checks that the destination holds the snapshot under the origin's mapping before the journal says
    /// so: every event of the copy mapped to an event that exists, with the parent the mapping gives; every
    /// call with its tool, and with the copy's state when that state is an end; every sample at its mapped
    /// key with as many elements; every Brain application applied under its mapped key, or journaled
    /// excluded. Throws `incomplete` with how many facts fail and the first; a count alone proves nothing.
    private static func verify(_ store: SQLiteMemoryStore, origin: String,
                               into destination: SQLiteMemoryStore) async throws {
        typealias Call = (tool: AgentTool, status: AgentCallStatus)
        let mapping = try await mappings(destination, origin)
        let source = try await store.read {
            snapshot -> (
                events: [(id: String, parent: String?)],
                calls: [String: Call],
                samples: [CaptureSampleKey: Int]
            ) in
            let events = try snapshot.query("SELECT event_id, parent_event_id FROM memory_events") {
                (id: try $0.text(0) ?? "", parent: try $0.text(1))
            }
            var calls: [String: Call] = [:]
            var samples: [CaptureSampleKey: Int] = [:]
            for event in events {
                if let call = try SQLiteAgentCallRows.call(snapshot, eventID: event.id) {
                    calls[event.id] = (call.request.tool, call.progress.status)
                }
                for key in try sampleKeys(snapshot, of: event.id) {
                    samples[key] = try SQLiteObservationRows.sample(snapshot, key: key)?.elements.count ?? 0
                }
            }
            return (events, calls, samples)
        }
        let sourceApplications = SQLiteBrainApplicationRepository(store: store)
        var applications: [(key: BrainApplicationKey, bundleID: String)] = []
        for key in try await applicationKeys(store) {
            guard let stored = try await sourceApplications.application(key) else { continue }
            applications.append((remapped(key, mapping), stored.command.bundleID))
        }
        let excluded = Set(try await destination.read { snapshot in
            try snapshot.query(
                """
                SELECT element_key FROM memory_origin_brain_contributions
                WHERE origin_id = ? AND element_kind = 'application' AND disposition = 'excluded'
                """,
                [.text(origin)]
            ) { try $0.text(0) ?? "" }
        })
        var problems = try await destination.read { snapshot -> [String] in
            var problems: [String] = []
            for event in source.events {
                guard let target = mapping[event.id] else {
                    problems.append("event \(event.id) is not mapped")
                    continue
                }
                guard let stored = try SQLiteEventRows.read(snapshot, eventID: target) else {
                    problems.append("event \(target) is missing")
                    continue
                }
                if stored.parentEventID != event.parent.map({ mapping[$0] ?? $0 }) {
                    problems.append("event \(target) has another parent")
                }
                guard let call = source.calls[event.id] else { continue }
                guard let held = try SQLiteAgentCallRows.call(snapshot, eventID: target) else {
                    problems.append("call \(target) is missing")
                    continue
                }
                if held.request.tool != call.tool || (call.status.isTerminal && held.progress.status != call.status) {
                    problems.append("call \(target) is not the snapshot's")
                }
            }
            for (key, elements) in source.samples {
                let moved = CaptureSampleKey(eventID: mapping[key.eventID] ?? key.eventID, phase: key.phase,
                                             ordinal: key.ordinal)
                if try SQLiteObservationRows.sample(snapshot, key: moved)?.elements.count != elements {
                    problems.append("sample \(moved.eventID)/\(moved.phase.rawValue) is missing")
                }
            }
            return problems
        }
        let applied = SQLiteBrainApplicationRepository(store: destination)
        for application in applications where try await applied.application(application.key) == nil {
            guard !excluded.contains("\(application.key.eventID)/\(application.key.operation.rawValue)") else {
                continue
            }
            problems.append("Brain application \(application.key.eventID) is missing")
        }
        if let first = problems.first {
            throw TransferError.incomplete("\(problems.count) facts of the snapshot fail, the first: \(first)")
        }
    }

    private static func mappings(_ destination: SQLiteMemoryStore, _ origin: String) async throws -> [String: String] {
        let rows = try await destination.read { snapshot in
            try snapshot.query(
                "SELECT source_event_id, event_id FROM memory_origin_events WHERE origin_id = ?",
                [.text(origin)]
            ) {
                (try $0.text(0) ?? "", try $0.text(1) ?? "")
            }
        }
        return Dictionary(rows, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Reading the source

    private static func sampleKeys(_ handle: some SQLiteQuerying, of eventID: String) throws -> [CaptureSampleKey] {
        try handle.query(
            """
            SELECT phase, sample_ordinal FROM memory_event_observations
            WHERE event_id = ? AND observation_kind = 'capture' ORDER BY observation_id
            """,
            [.text(eventID)]
        ) { row in
            guard let phase = CapturePhase(rawValue: try row.text(0) ?? "") else {
                throw MemoryStoreError.contract(.init(
                    code: .init(primary: 0, extended: 0),
                    phase: .statement,
                    message: "a sample of an unknown phase"
                ))
            }
            return CaptureSampleKey(eventID: eventID, phase: phase, ordinal: Int(row.integer(1) ?? 0))
        }
    }

    private static func sampleKeys(_ store: SQLiteMemoryStore) async throws -> [CaptureSampleKey] {
        try await store.read { snapshot in
            let owners = try snapshot.query(
                """
                SELECT DISTINCT event_id FROM memory_event_observations
                WHERE observation_kind = 'capture' ORDER BY event_id
                """
            ) { try $0.text(0) ?? "" }
            return try owners.flatMap { try sampleKeys(snapshot, of: $0) }
        }
    }

    private static func applicationKeys(_ store: SQLiteMemoryStore) async throws -> [BrainApplicationKey] {
        try await store.read { snapshot in
            try snapshot.query(
                "SELECT event_id, operation, phase, sample_ordinal FROM brain_applications ORDER BY application_id"
            ) { row -> BrainApplicationKey in
                let event = try row.text(0) ?? "", operation = try row.text(1) ?? ""
                switch operation {
                    case "observe":
                        let phase = CapturePhase(rawValue: try row.text(2) ?? "") ?? .current
                        return .observe(CaptureSampleKey(
                            eventID: event,
                            phase: phase,
                            ordinal: Int(row.integer(3) ?? 0)
                        ))
                    case "record": return .record(eventID: event)
                    default      : return .setName(eventID: event)
                }
            }
        }
    }

    private static func untransferredRows(_ store: SQLiteMemoryStore) async throws -> String? {
        let held = try await store.read { snapshot in
            try untransferred.compactMap { table -> String? in
                // Table names are this module's own literals; nothing from a caller is spliced in.
                let count = try snapshot.query("SELECT count(*) FROM \(table)") { $0.integer(0) ?? 0 }.first ?? 0
                return count > 0 ? "\(table) \(count)" : nil
            }
        }
        return held.isEmpty ? nil : held.joined(separator: ", ")
    }

    // MARK: The journal

    private static func journal(_ destination: SQLiteMemoryStore, _ origin: String, location: String, nowMS: Int64,
                                status: String, detail: String?, sourceVersion: Int64? = nil) async throws {
        _ = try await destination.write { transaction in
            try transaction.execute(
                """
                INSERT INTO memory_archive_origins (origin_id, origin_kind, location, status, first_seen_at_ms,
                                                    updated_at_ms, source_schema_version, detail)
                VALUES (?, 'mcp_profile', ?, ?, ?, ?, ?, ?)
                ON CONFLICT(origin_id) DO UPDATE SET status = excluded.status, updated_at_ms = excluded.updated_at_ms,
                    source_schema_version = ifnull(excluded.source_schema_version, source_schema_version),
                    detail = excluded.detail
                """,
                [.text(origin), .text(location), .text(status), .integer(nowMS), .integer(nowMS),
                 sourceVersion.map(SQLiteValue.integer) ?? .null, detail.map(SQLiteValue.text) ?? .null]
            )
        }
    }

    /// The origins a fact of the destination came from, in the order of their names: none for a fact its
    /// own producers wrote.
    package static func origins(of eventID: String, in destination: SQLiteMemoryStore) async throws -> [EventOrigin] {
        try await destination.read { snapshot in
            try snapshot.query(
                """
                SELECT e.origin_id, o.location, e.source_event_id, e.disposition
                FROM memory_origin_events e JOIN memory_archive_origins o ON o.origin_id = e.origin_id
                WHERE e.event_id = ? ORDER BY e.origin_id
                """,
                [.text(eventID)]
            ) { row in
                guard let disposition = EventOrigin.Disposition(rawValue: try row.text(3) ?? "") else {
                    throw MemoryStoreError.contract(.init(code: .init(primary: 0, extended: 0), phase: .statement,
                                                          message: "a transferred fact of an unknown disposition"))
                }
                return EventOrigin(originID: try row.text(0) ?? "", location: try row.text(1) ?? "",
                                   sourceEventID: try row.text(2) ?? "", disposition: disposition)
            }
        }
    }

    package static func report(_ destination: SQLiteMemoryStore, _ origin: String) async throws -> Report {
        try await destination.read { snapshot in
            try snapshot.query(
                """
                SELECT status, events_added, events_duplicate, events_renamed, applications_added,
                       applications_duplicate, brains_imported, detail
                FROM memory_archive_origins WHERE origin_id = ?
                """,
                [.text(origin)]
            ) { row in
                Report(originID: origin, status: try row.text(0) ?? "", eventsAdded: Int(row.integer(1) ?? 0),
                       eventsDuplicate: Int(row.integer(2) ?? 0), eventsRenamed: Int(row.integer(3) ?? 0),
                       applicationsAdded: Int(row.integer(4) ?? 0), applicationsDuplicate: Int(row.integer(5) ?? 0),
                       brainsImported: Int(row.integer(6) ?? 0), detail: try row.text(7))
            }.first ?? Report(originID: origin, status: "unknown", eventsAdded: 0, eventsDuplicate: 0, eventsRenamed: 0,
                              applicationsAdded: 0, applicationsDuplicate: 0, brainsImported: 0, detail: nil)
        }
    }

    /// Whether the origin's archive holds facts the journal has not taken yet: it was never transferred,
    /// its transfer did not end, or it holds an event the origin's mapping lacks (an earlier build wrote
    /// to it since, or an end was certified without it). Read only; an archive that cannot be read is
    /// offered, so the transfer itself says why.
    package static func needsTransfer(source: URL, origin: String, into destination: SQLiteMemoryStore) async -> Bool {
        let recorded = try? await destination.read { snapshot in
            try snapshot.query(
                "SELECT status, high_local_order FROM memory_archive_origins WHERE origin_id = ?",
                [.text(origin)]
            ) {
                (status: try $0.text(0) ?? "", high: $0.integer(1))
            }
        }
        guard let journaled = recorded?.first, ended.contains(journaled.status) else { return true }
        if journaled.status == "refused" { return false }
        guard let reader = try? readableConnection(to: source) else { return true }
        defer { reader.close() }
        guard let events = try? reader.query("SELECT event_id FROM memory_events", [], { try $0.text(0) ?? "" }),
              let mapped = try? await mappings(destination, origin) else {
            return true
        }
        // An ended origin with an event it never mapped is taken again: one an earlier build wrote since, or
        // one an end certified without (the empty copy a lost staging made).
        return events.contains { mapped[$0] == nil }
    }

    /// Journals an origin with no archive, only JSON Brains, as in progress, before they are merged.
    package static func beginJSONOnly(_ destination: SQLiteMemoryStore, origin: String, location: String,
                                      nowMS: Int64) async throws {
        try await journal(destination, origin, location: location, nowMS: nowMS, status: "in_progress", detail: nil)
    }

    /// Concludes the journal of an origin with no archive once its JSON Brains were merged: the report.
    package static func recordJSONOnly(_ destination: SQLiteMemoryStore, origin: String,
                                       nowMS: Int64) async throws -> Report {
        _ = try await destination.write { transaction in
            try transaction.execute(
                "UPDATE memory_archive_origins SET updated_at_ms = ?, \(concluding) WHERE origin_id = ?",
                [.integer(nowMS), .text(origin)]
            )
        }
        return try await report(destination, origin)
    }

    /// The origins the archive journaled and where each stands.
    package static func origins(_ destination: SQLiteMemoryStore) async throws -> [String: String] {
        try await destination.read { snapshot in
            Dictionary(try snapshot.query("SELECT origin_id, status FROM memory_archive_origins") {
                (try $0.text(0) ?? "", try $0.text(1) ?? "")
            }, uniquingKeysWith: { first, _ in first })
        }
    }
}

extension MemoryStoreError {

    /// Whether the error refuses a file for its schema: a newer, an unknown or another shape.
    var isSchemaRefusal: Bool {
        if case .schema = self { return true }
        return false
    }
}
