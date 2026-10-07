//
//  SQLiteMemoryStore.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 03/10/2026.
//

import Foundation
import Memory
import SQLite3

/// SQLiteMemoryStore is the living memory's one SQLite file, opened explicitly at a path the
/// composition root chose and used through typed transactions. It owns two connections: a writer,
/// which runs every change inside `BEGIN IMMEDIATE ... COMMIT`, and a reader, which sees the last
/// committed state without waiting on the writer. Actor isolation serializes both within the
/// process; between processes the file's own locks do, which is why every transaction is short,
/// holds no `await`, and is retried with the same identifiers when the lock is busy.
///
/// A write is answered only after its commit. The ordinary `write` holds the work while the lock
/// is busy: the body and the caller's task are the work, and they stay where they are, cycle after
/// cycle of the lock budget, until the commit, the caller's cancellation, the store's close or a
/// failure that is not contention. Nothing is queued elsewhere and nothing is dropped, so nothing
/// is ever reported as saved before it is. `attemptWrite` is the single cycle underneath, for a
/// caller that wants to classify a spent budget itself. Every cycle contains at least one real
/// pause: a configuration that would allow a retry without one is refused at `open`.
///
/// The store never scans or imports JSON, never opens a database elsewhere when the path fails,
/// and never resets or downgrades a file it does not recognise. Waiting for a busy lock happens
/// between attempts, outside any transaction, and honours the caller's cancellation. A `close`
/// prevails over an `open` still waiting: that open ends with `unavailable(.closed)` and lets go of
/// the connection it had, and no handle survives the close. `close` is not a flush: work still
/// waiting ends with that error, so a producer awaits the writes it means to keep before closing.
///
/// After a failure of the device or the file the store looks at the transaction it interrupted,
/// ends it if the library had not, and reports which (`MemoryStoreFault.cleanup`). A transaction
/// it could not end makes the connection untrusted: the store lets go of both connections and
/// answers `unavailable(.failed)` until it is closed, and recovery is a new instance opened on
/// the same path once the cause is removed. Nothing is retried on the store's own initiative.
///
/// A snapshot copies the file through the library's backup API into a path of the caller's,
/// consistent as of one read transaction, verified before it is handed over; a checkpoint moves
/// the write-ahead log into the file passively, never waiting on readers or other processes.
///
/// The store holds the archive's presence lock shared (`SQLiteMemoryPresence`) from before its first
/// connection until its last one, and the last one of a copy still in flight, has closed: a
/// recovery, which takes the lock exclusive, is refused meanwhile, and an open waits for a recovery
/// in progress within one lock budget, then answers `contention`.
public actor SQLiteMemoryStore {

    /// Configuration is the store's waiting policy, chosen at composition. The defaults are what
    /// the module's tests run with; they are not a measured guarantee of availability. A policy
    /// that would let a cycle end without one real pause is refused at `open` (`problem`).
    public struct Configuration: Sendable, Equatable {

        /// One cycle of waiting for a busy lock: the pauses of the cycle add up to at most this.
        /// A spent cycle is `contention` from `attemptWrite` and another cycle from `write`. It
        /// must cover at least one `retryPause`.
        public var lockBudget: Duration

        /// The pause before the first retry, above zero. Each retry doubles it, up to
        /// `maximumRetryPause`, which must not be shorter.
        public var retryPause: Duration

        public var maximumRetryPause: Duration

        /// Pages one step of a snapshot copies before the store yields to other work and checks
        /// for cancellation. Above zero.
        public var snapshotPagesPerStep: Int32

        public init(
            lockBudget          : Duration = .seconds(2),
            retryPause          : Duration = .milliseconds(5),
            maximumRetryPause   : Duration = .milliseconds(100),
            snapshotPagesPerStep: Int32    = 256
        ) {
            self.lockBudget           = lockBudget
            self.retryPause           = retryPause
            self.maximumRetryPause    = maximumRetryPause
            self.snapshotPagesPerStep = snapshotPagesPerStep
        }

        /// The rule this configuration breaks, or nil when every cycle of waiting it allows holds
        /// at least one real pause and every step of a snapshot copies something.
        public var problem: String? {
            if retryPause <= .zero {
                return "retryPause must be above zero: a retry without a pause is a spin"
            }
            if maximumRetryPause < retryPause {
                return "maximumRetryPause must not be shorter than retryPause"
            }
            if lockBudget < retryPause {
                return "lockBudget must cover at least one retryPause, or a cycle would end without waiting"
            }
            if snapshotPagesPerStep <= 0 {
                return "snapshotPagesPerStep must be above zero"
            }
            return nil
        }
    }

    /// Diagnostics is what the store can say about itself without reading the schema's rows:
    /// enough to tell an empty archive from an unreadable one, a busy file from a broken one, and
    /// work still waiting from work on disk.
    public struct Diagnostics: Sendable, Equatable {

        public let path              : String
        public let libraryVersion    : String
        public let librarySourceID   : String
        public let schemaVersion     : Int32
        public let journalMode       : String
        public let synchronous       : Int64
        public let foreignKeysEnabled: Bool

        /// Whether this open created schema 1 in an empty file, as opposed to finding it.
        public let bootstrappedNow: Bool

        /// Committed write transactions since the open.
        public let commits: Int

        /// Pauses taken because a lock was busy, and their total length, since the open.
        public let busyRetries: Int
        public let waited     : Duration

        /// Writes offered through `write` that are waiting for the lock right now: work the store
        /// holds in its callers' tasks, on disk only once `commits` moves.
        public let retainedWrites: Int

        /// Lock budgets that ran out since the open. Each was followed by another cycle of the
        /// same write, never by a dropped one.
        public let exhaustedCycles: Int

        /// The log size, in frames, at which the library checkpoints on its own after a commit on
        /// the writer: `wal_autocheckpoint`, left at the library's default.
        public let autoCheckpointFrames: Int64

        /// Explicit checkpoints run since the open, and the last one's report.
        public let checkpoints   : Int
        public let lastCheckpoint: Checkpoint?

        /// Snapshots handed over since the open.
        public let snapshots: Int
    }

    /// Checkpoint is the report of one explicit passive checkpoint: how many frames the log held,
    /// how many reached the file, and why not all of them when not all did. Neither outcome but
    /// `complete` is a failure: the rest of the log waits for the next checkpoint.
    public struct Checkpoint: Sendable, Equatable {

        public enum Outcome: Sendable, Equatable {

            /// Every frame reached the file, which was then synced.
            case complete

            /// A reader on an older snapshot, in this or another process, keeps the rest in the log.
            case partial

            /// Another connection was checkpointing; this one did nothing.
            case busy
        }

        public let frames            : Int
        public let checkpointedFrames: Int
        public let outcome           : Outcome
        public let duration          : Duration
    }

    /// Snapshot is the report of one copy handed over at its destination: verified, in rollback
    /// journal mode, self-contained in one file.
    public struct Snapshot: Sendable, Equatable {

        public let destination: URL
        public let pageCount  : Int
        public let pageSize   : Int
        public let steps      : Int
        public let duration   : Duration
    }

    /// WaitEvent is one step of the store's waiting or yielding, offered to the observer a test or
    /// a diagnostic sink installs: a point to synchronize on, not a promise about the file.
    package enum WaitEvent: Sendable, Equatable {

        /// The store is about to pause because the lock was busy at this phase.
        case pausing(MemoryStoreError.Phase, attempt: Int)

        /// A whole lock budget passed without the lock; `write` begins another cycle.
        case cycleExhausted(MemoryStoreError.Phase, attempts: Int, waited: Duration)

        /// The store is about to yield between the steps of a long operation, with this much left.
        case yielding(MemoryStoreError.Phase, remaining: Int)
    }

    public nonisolated let url          : URL
    public nonisolated let configuration: Configuration

    /// Connections this store holds open: two while open, zero once closed or failed, whatever
    /// an open in flight was doing when the close arrived. A snapshot in flight holds two more
    /// until its next step finds the store closed.
    private(set) var liveHandles = 0

    private var writer          : SQLiteConnection?
    private var reader          : SQLiteConnection?
    private var lifecycle       = Lifecycle.notOpened
    private var opening         : Task<Void, any Error>?
    private var bootstrappedNow = false
    private var commits         = 0
    private var busyRetries     = 0
    private var waited          = Duration.zero
    private var retainedWrites  = 0
    private var exhaustedCycles = 0
    private var checkpoints     = 0
    private var lastCheckpoint  : Checkpoint?
    private var snapshots       = 0
    private var waitObserver    : (@Sendable (WaitEvent) -> Void)?
    private var refusedRollback : SQLiteConnection.Failure?
    private var stepGate        : (@Sendable () async throws -> Void)?
    private var presence        : SQLiteMemoryPresence?
    private let clock           = ContinuousClock()

    /// Lifecycle is the store's state: `opening` while an open is in flight, so a second open
    /// joins it and a close ends it; `failed` once a connection could not be trusted, until close.
    private enum Lifecycle: Equatable {
        case notOpened, opening, open, closed
        case failed(MemoryStoreFault)
    }

    /// WaitingCycle is one cycle's retry rule apart from the lock and the clock: the attempts made,
    /// the next pause and the pauses taken so far, which the budget bounds. The store gives it what
    /// each pause really lasted; a test gives it chosen lengths and reads the schedule, which no
    /// sleep of the system decides.
    package struct WaitingCycle: Sendable, Equatable {

        package private(set) var attempts = 0
        package private(set) var pause   : Duration
        package private(set) var waited  = Duration.zero

        private let budget      : Duration
        private let maximumPause: Duration

        package init(_ configuration: Configuration) {
            pause        = configuration.retryPause
            budget       = configuration.lockBudget
            maximumPause = configuration.maximumRetryPause
        }

        /// Counts the attempt about to run.
        package mutating func attempting() {
            attempts += 1
        }

        /// The pause to take after a busy attempt, or nil when it would overrun the budget.
        package var nextPause: Duration? {
            waited + pause <= budget ? pause : nil
        }

        /// Counts a pause that lasted `measured` and doubles the next one, up to the maximum.
        package mutating func paused(for measured: Duration) {
            waited += measured
            pause   = min(pause * 2, maximumPause)
        }

        /// Counts the part of a pause a cancellation cut short; no attempt follows it.
        package mutating func interrupted(after measured: Duration) {
            waited += measured
        }
    }

    /// Busy is a library failure met at a phase, thrown inside a `retrying` step so the loop
    /// pauses and tries the step again while keeping the phase for the report.
    private struct Busy: Error {
        let failure: SQLiteConnection.Failure
        let phase  : MemoryStoreError.Phase
    }

    /// Remembers the path and the policy. Nothing is opened until `open`.
    public init(url: URL, configuration: Configuration = Configuration()) {
        self.url           = url
        self.configuration = configuration
    }

    /// Opening is what an open may do to the file it finds. `producer` is the open of whoever
    /// writes the memory: it creates a missing file and bootstraps schema 1 in an empty one, as S1
    /// decided. `existingArchive` is the open of a reader: it takes only a file that is already a
    /// Mecum archive at the schema this build knows, and never creates the file, bootstraps a
    /// schema or sets the journal of a file it refuses (`uninitialized` for a file with no schema
    /// yet, and every refusal `producer` makes). Both decide on the file as it is when they open it
    /// (the producer under its write lock, the reader in a read transaction, which writes nothing),
    /// so a file that appears, vanishes or changes before the decision is judged as it is then.
    /// Once open, a store is the same whichever opening made it.
    public enum Opening: Sendable, Equatable {
        case producer
        case existingArchive
    }

    /// Opens and bootstraps a store at the URL, ready for use.
    public static func open(
        at url       : URL,
        configuration: Configuration = Configuration()
    ) async throws -> SQLiteMemoryStore {
        let store = SQLiteMemoryStore(url: url, configuration: configuration)
        try await store.open()
        return store
    }

    // MARK: Lifecycle

    /// Opens the writer and the reader, checks the linked library, enables foreign keys, sets WAL
    /// and `synchronous=FULL`, then bootstraps (`producer` only) or verifies schema 1 under the write
    /// lock (a reader inspects in a read transaction); `existingArchive` creates no file and refuses
    /// one with no schema yet (`Opening`). A second
    /// opener of the same file waits for the first and then finds the schema. Throws without
    /// creating anything when the configuration is refused or the path cannot be opened, and
    /// without touching a file whose schema it does not recognise. A second `open` on the same
    /// instance joins the one in flight, whatever its kind, and shares its answer; an open store answers at once; a
    /// closed one stays closed, and so does one closed while this open was waiting for the lock.
    /// A failed instance stays failed: recovery is a new instance on the same path.
    public func open(_ kind: Opening = .producer) async throws {
        if let problem = configuration.problem {
            throw MemoryStoreError.unavailable(.misconfigured(problem))
        }
        switch lifecycle {
        case .open              : return
        case .closed            : throw MemoryStoreError.unavailable(.closed)
        case .failed(let fault) : throw MemoryStoreError.unavailable(.failed(fault))
        case .opening           : break
        case .notOpened:
            lifecycle = .opening
            opening   = Task { try await self.performOpen(kind) }
        }
        guard let inFlight = opening else { throw MemoryStoreError.unavailable(.closed) }
        do {
            try await inFlight.value
        } catch {
            if lifecycle == .closed { throw MemoryStoreError.unavailable(.closed) }
            throw error
        }
        if lifecycle == .closed { throw MemoryStoreError.unavailable(.closed) }
    }

    /// Closes both connections and ends an open still in flight, which then answers
    /// `unavailable(.closed)` and lets go of its connection. A transaction still waiting for a
    /// lock, or a snapshot between two steps, finds the store closed after its pause and answers
    /// the same; nothing is written after this returns. Definitive: a failed instance closes the
    /// same way and never reopens.
    public func close() {
        opening?.cancel()
        if let writer { release(writer) }
        if let reader { release(reader) }
        writer    = nil
        reader    = nil
        lifecycle = .closed
        releasePresenceWhenIdle()
    }

    /// What the store knows about its file and its waiting, read from the reader connection.
    public func diagnostics() throws -> Diagnostics {
        let reader = try connection(.reader)
        let writer = try connection(.writer)
        do {
            return Diagnostics(
                path                : url.path,
                libraryVersion      : SQLiteLibrary.version,
                librarySourceID     : SQLiteLibrary.sourceID,
                schemaVersion       : Int32(try Self.integerPragma(reader, "user_version")),
                journalMode         : try Self.textPragma(reader, "journal_mode"),
                synchronous         : try Self.integerPragma(reader, "synchronous"),
                foreignKeysEnabled  : try Self.integerPragma(reader, "foreign_keys") == 1,
                bootstrappedNow     : bootstrappedNow,
                commits             : commits,
                busyRetries         : busyRetries,
                waited              : waited,
                retainedWrites      : retainedWrites,
                exhaustedCycles     : exhaustedCycles,
                autoCheckpointFrames: try Self.integerPragma(writer, "wal_autocheckpoint"),
                checkpoints         : checkpoints,
                lastCheckpoint      : lastCheckpoint,
                snapshots           : snapshots
            )
        } catch {
            throw Self.classified(error, phase: .statement)
        }
    }

    /// Installs, or removes, the observer of the store's waiting. Called on the actor, before the
    /// pause or the yield it announces; it must not call back into the store synchronously.
    package func observeWaits(_ observer: (@Sendable (WaitEvent) -> Void)?) {
        waitObserver = observer
    }

    /// A test's seam into the cleanup, for the package's tests only (never public): the next rollback
    /// the store runs after a failure inside a transaction is not run, and answers the library's code
    /// and message given here instead. The connection stays inside its transaction, as after a
    /// rollback that truly failed, and the store's own decision (`cleanupOutcome`) and its
    /// consequences (`invalidate`) follow unchanged. One use; nothing is broken on the device, so what
    /// it proves is the store's path and its owner's, not a real fault.
    package func refuseNextRollback(primary: Int32, extended: Int32, message: String) {
        refusedRollback = SQLiteConnection.Failure(primary: primary, extended: extended, message: message)
    }

    /// The same seam, with the library's failure as the module's own type.
    func refuseNextRollback(with failure: SQLiteConnection.Failure) {
        refusedRollback = failure
    }

    /// A test's seam into a snapshot, for the package's tests only: awaited between two steps of every
    /// copy, after the yield, while the copy holds its connections and its partial file. The store is
    /// free meanwhile, so a close can run; the copy sees it, or its task's cancellation, when the gate
    /// returns or throws.
    package func holdSnapshots(between gate: (@Sendable () async throws -> Void)?) {
        stepGate = gate
    }

    // MARK: Transactions

    /// Runs the body inside one write transaction and answers after its commit, holding the work
    /// while the lock is busy. The work is the body and its inputs, owned by the caller's task; it
    /// is offered again with the same identifiers at every cycle of the lock budget, and it ends
    /// only with the commit, the caller's cancellation, the store's close or a failure that is
    /// not contention. Order is the caller's: its next write is offered after this one's answer.
    /// Nothing is queued elsewhere, so nothing is reported as saved before it is; a body that
    /// throws rolls the transaction back and its error is answered unchanged.
    package func write<T: Sendable>(_ body: @Sendable (SQLiteTransaction) throws -> T) async throws -> T {
        retainedWrites += 1
        defer { retainedWrites -= 1 }
        while true {
            do {
                return try await attemptWrite(body)
            } catch MemoryStoreError.contention(let fault, attempts: let attempts, waited: let cycleWaited) {
                exhaustedCycles += 1
                waitObserver?(.cycleExhausted(fault.phase, attempts: attempts, waited: cycleWaited))
            }
        }
    }

    /// One cycle of `write`: begins, runs the body, commits, waiting for a busy lock only within
    /// the configured budget and answering `contention` when it is spent, with nothing written.
    /// The body runs again on each attempt of the cycle. For a caller that classifies the spent
    /// budget itself; the ordinary path is `write`.
    package func attemptWrite<T: Sendable>(_ body: @Sendable (SQLiteTransaction) throws -> T) async throws -> T {
        let writer = try connection(.writer)
        let value  = try await transaction(on: writer, begin: "BEGIN IMMEDIATE", phase: .statement) {
            try body(SQLiteTransaction(connection: writer))
        }
        commits += 1
        return value
    }

    /// Runs the body on the reader inside one deferred transaction: every query in it sees the same
    /// committed state, and the transaction ends when the body returns. A write in progress on
    /// another connection is neither seen nor waited for; a busy answer, rare in WAL, is waited
    /// for within one budget.
    package func read<T: Sendable>(_ body: @Sendable (SQLiteSnapshot) throws -> T) async throws -> T {
        let reader = try connection(.reader)
        return try await transaction(on: reader, begin: "BEGIN", phase: .statement) {
            try body(SQLiteSnapshot(connection: reader))
        }
    }

    /// The archive's data version as the reader sees it: a number that moves whenever a commit by
    /// another connection, of this process or another one, changed the file since the reader last
    /// looked. A cache of what was read stays good while it does not move.
    public func dataVersion() async throws -> Int64 {
        try await read { snapshot in
            try snapshot.query("PRAGMA data_version") { $0.integer(0) ?? 0 }.first ?? 0
        }
    }

    // MARK: Checkpoint

    /// Runs one passive checkpoint on the writer: frames of the log are copied into the file as far
    /// as no reader, in this process or another, still needs them; nothing is waited for and the
    /// log is neither truncated nor restarted, so other processes on the file are never assumed
    /// absent. A partial or busy outcome is reported, not thrown. The library's own automatic
    /// checkpoint, after a commit that leaves the log above `autoCheckpointFrames`, is the same
    /// passive kind and stays in force.
    public func checkpoint() throws -> Checkpoint {
        let writer  = try connection(.writer)
        let started = clock.now
        do {
            let result  = try writer.checkpoint()
            let outcome: Checkpoint.Outcome
            if result.wasBusy {
                outcome = .busy
            } else {
                outcome = result.checkpointed == result.frames ? .complete : .partial
            }
            let report = Checkpoint(
                frames            : result.frames,
                checkpointedFrames: result.checkpointed,
                outcome           : outcome,
                duration          : clock.now - started
            )
            checkpoints   += 1
            lastCheckpoint = report
            return report
        } catch let failure as SQLiteConnection.Failure {
            throw MemoryStoreError(failure, phase: .checkpoint)
        }
    }

    // MARK: Snapshot

    /// Copies the file to `destination` through the backup API and answers once the copy is
    /// verified and in place. The copy is consistent as of one read transaction on a connection
    /// of its own, held through every step, so commits by this or another process during the copy
    /// neither appear in it nor restart it; the writer is not stopped. The destination must not be
    /// the store's file or its journals and must not exist: nothing is overwritten. The copy is
    /// built at a temporary path beside the destination that only this call names, checked
    /// (`integrity_check`, `foreign_key_check`, schema 1 with every table), put in rollback
    /// journal mode so it is one self-contained file, and then renamed into place without
    /// clobbering. Any refusal, failure, cancellation between steps or close of the store removes
    /// the temporary files this call created and leaves no copy: an interrupted copy is never
    /// handed over, and nothing is restored from a copy on the store's own initiative.
    public func snapshot(to destination: URL) async throws -> Snapshot {
        _ = try connection(.writer)
        let target = Self.resolved(destination)
        let own    = Self.resolved(url).path
        guard !["", "-wal", "-shm", "-journal", ".lock"].map({ own + $0 }).contains(target.path) else {
            throw MemoryStoreError.snapshot(.destinationIsTheSource)
        }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw MemoryStoreError.snapshot(.destinationExists)
        }
        let partial = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).partial-\(UUID().uuidString)")
        let started = clock.now
        var copying = SnapshotResources(partialPath: partial.path)
        do {
            let source = try acquire(url.path, readOnly: true)
            copying.source = source
            try await retrying(phase: .snapshot) { try Self.pin(source) }
            try stillOpen()
            let copy: SQLiteConnection
            do {
                copy = try acquire(partial.path)
            } catch MemoryStoreError.open(let fault) {
                throw MemoryStoreError.snapshot(.destinationUnavailable(
                    MemoryStoreFault(code: fault.code, phase: .snapshot, message: fault.message)
                ))
            }
            copying.copy = copy
            let backup = try SQLiteBackup(from: source, to: copy)
            copying.backup = backup
            var steps     = 0
            var pageCount = 0
            while true {
                if Task.isCancelled { throw MemoryStoreError.cancelled(.snapshot) }
                try stillOpen()
                let pages    = configuration.snapshotPagesPerStep
                let progress = try await retrying(phase: .snapshot) { try backup.step(pages: pages) }
                steps    += 1
                pageCount = progress.pageCount
                if progress.remaining == 0 { break }
                waitObserver?(.yielding(.snapshot, remaining: progress.remaining))
                await Task.yield()
                // The gate's own error is not the copy's: what it waited for is seen at the loop's head.
                if let stepGate { try? await stepGate() }
            }
            try backup.finish()
            copying.backup = nil
            release(source)
            copying.source = nil
            try stillOpen()
            let pageSize = try Self.verify(copy: copy)
            try Self.settle(copy: copy)
            release(copy)
            copying.copy = nil
            try Self.move(copying.partialPath, to: target.path)
            copying.removeJournals()
            snapshots += 1
            return Snapshot(
                destination: target,
                pageCount  : pageCount,
                pageSize   : pageSize,
                steps      : steps,
                duration   : clock.now - started
            )
        } catch {
            copying.abandon(releasing: self)
            throw Self.classified(error, phase: .snapshot)
        }
    }

    /// The connections and files one snapshot holds while it runs, so that every way out lets go
    /// of all of them. The partial path and its journal siblings are named by this call alone.
    private struct SnapshotResources {

        let partialPath: String
        var source     : SQLiteConnection?
        var copy       : SQLiteConnection?
        var backup     : SQLiteBackup?

        /// Ends the copy without handing it over: the backup object first, so the connections can
        /// close, then the files. A finish that fails here is not answered: the primary error is
        /// the one that brought the snapshot here.
        mutating func abandon(releasing store: isolated SQLiteMemoryStore) {
            if let backup { try? backup.finish() }
            backup = nil
            if let copy { store.release(copy) }
            copy = nil
            if let source { store.release(source) }
            source = nil
            for path in family { try? FileManager.default.removeItem(atPath: path) }
        }

        /// Removes the journal siblings a verification may have created beside a finished copy.
        func removeJournals() {
            for path in family.dropFirst() { try? FileManager.default.removeItem(atPath: path) }
        }

        private var family: [String] { ["", "-wal", "-shm", "-journal"].map { partialPath + $0 } }
    }

    /// Opens the read transaction the whole copy reads through. A busy answer leaves no
    /// transaction behind, so `retrying` may run this again.
    private static func pin(_ source: SQLiteConnection) throws {
        try source.execute("BEGIN")
        do {
            _ = try source.query("SELECT count(*) FROM sqlite_schema") { $0.integer(0) }
        } catch {
            rollback(source)
            throw error
        }
    }

    /// Checks the finished copy and answers its page size. Anything short of `ok`, no violation
    /// and schema 1 with every table is a refusal, and the copy is removed by the caller.
    private static func verify(copy: SQLiteConnection) throws -> Int {
        let integrity = try copy.query("PRAGMA integrity_check") { try $0.text(0) ?? "" }
        guard integrity == ["ok"] else { throw MemoryStoreError.snapshot(.copyFailedIntegrityCheck(integrity)) }
        let violations = try copy.query("PRAGMA foreign_key_check") { _ in () }.count
        guard violations == 0 else { throw MemoryStoreError.snapshot(.copyHasForeignKeyViolations(violations)) }
        let expected = try Expected(ddl: try SQLiteMemorySchema.text())
        do {
            guard try inspect(copy, expected: expected) == .current else {
                throw MemoryStoreError.snapshot(.copySchema(.missingTables(expected.tables)))
            }
        } catch MemoryStoreError.schema(let mismatch) {
            throw MemoryStoreError.snapshot(.copySchema(mismatch))
        }
        return Int(try integerPragma(copy, "page_size"))
    }

    /// Leaves the copy in rollback journal mode: its header came from a WAL file, and this folds
    /// any log the verification opened back into the one file before it is handed over.
    private static func settle(copy: SQLiteConnection) throws {
        let mode = try copy.query("PRAGMA journal_mode = DELETE") { try $0.text(0) ?? "" }.first ?? ""
        guard mode == "delete" else {
            throw MemoryStoreError.snapshot(.copyFailedIntegrityCheck([
                "journal_mode could not be set to delete; the copy answered '\(mode)'"
            ]))
        }
    }

    /// Renames the finished copy into place, refusing to replace anything that appeared at the
    /// destination meanwhile.
    private static func move(_ partial: String, to target: String) throws {
        guard renamex_np(partial, target, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            if code == EEXIST { throw MemoryStoreError.snapshot(.destinationExists) }
            throw MemoryStoreError.snapshot(.destinationUnavailable(MemoryStoreFault(
                code   : MemoryStoreFault.Code(primary: 0, extended: code),
                phase  : .snapshot,
                message: String(cString: strerror(code))
            )))
        }
    }

    private static func resolved(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    // MARK: Opening

    /// What the inspection of a file found: nothing yet, or the schema this build knows.
    enum Inspection: Equatable {
        case empty, current
    }

    /// The open in flight. Every step that waited checks that the store is still opening, so a
    /// close that arrived meanwhile prevails: the connection is let go and the answer is `closed`.
    /// A failure of any other kind, from the first step on (the library, the schema resource, the
    /// first connection), leaves the store not opened with no handle held, so a later open on this
    /// instance may try again.
    private func performOpen(_ kind: Opening) async throws {
        defer { opening = nil }
        let path = url.path
        let ddl     : String
        let expected: Expected
        let writer  : SQLiteConnection
        do {
            if let unmet = SQLiteLibrary.unmetRequirement() {
                throw MemoryStoreError.unavailable(.library(found: SQLiteLibrary.version, required: unmet.minimumVersion))
            }
            ddl      = try SQLiteMemorySchema.text()
            expected = try Expected(ddl: ddl)
            // A reader of a file that is not there makes nothing beside it, not even the lock file.
            if kind == .existingArchive, !FileManager.default.fileExists(atPath: path) {
                throw MemoryStoreError(SQLiteConnection.Failure(
                    primary: SQLITE_CANTOPEN, extended: SQLITE_CANTOPEN, message: "unable to open database file"
                ), phase: .open)
            }
            try await takePresence()
            writer   = try acquire(path, mayCreate: kind == .producer)
        } catch {
            throw abandonedOpen(after: error)
        }
        do {
            // Inspect before touching the journal mode, so a file this build refuses is left as found. A
            // producer inspects under the write lock it may bootstrap under; a reader in a read transaction,
            // since the library writes a header into a zero-byte file at the end of any write transaction.
            let found = try await transaction(on: writer, begin: kind == .producer ? "BEGIN IMMEDIATE" : "BEGIN",
                                              phase: .bootstrap) {
                try Self.inspect(writer, expected: expected)
            }
            try stillOpening()
            if found == .empty, kind == .existingArchive {
                // A reader never makes an archive: a file with no schema yet is refused as found.
                let pages = try Self.integerPragma(writer, "page_count")
                throw MemoryStoreError.schema(.uninitialized(fileIsEmpty: pages == 0))
            }
            try await retrying(phase: .open) {
                try Self.setJournal(writer, phase: .open)
            }
            try stillOpening()
            var created = false
            if found == .empty {
                // Another process may have created the schema since the inspection: look again under the lock.
                created = try await transaction(on: writer, begin: "BEGIN IMMEDIATE", phase: .bootstrap) {
                    guard try Self.inspect(writer, expected: expected) == .empty else { return false }
                    try writer.execute(ddl)
                    // A pragma cannot take a bound value; the version is this module's own constant.
                    try writer.execute("PRAGMA user_version = \(SQLiteMemorySchema.version)")
                    return true
                }
                try stillOpening()
            }
            let reader = try acquire(path, mayCreate: kind == .producer)
            do {
                try Self.verifyJournal(reader, phase: .open)
            } catch {
                release(reader)
                throw error
            }
            self.writer          = writer
            self.reader          = reader
            self.bootstrappedNow = created
            self.lifecycle       = .open
        } catch {
            release(writer)
            throw abandonedOpen(after: error)
        }
    }

    /// What an open that did not succeed answers: `closed` when a close arrived meanwhile, which
    /// prevails and stays; otherwise the error, with the store not opened again.
    private func abandonedOpen(after error: any Error) -> any Error {
        defer { releasePresenceWhenIdle() }
        if lifecycle == .closed { return MemoryStoreError.unavailable(.closed) }
        lifecycle = .notOpened
        return error
    }

    /// Takes the archive's presence lock shared, before the first connection. A recovery in progress
    /// holds it exclusive: the open waits for it as for a busy lock, within one budget, and then
    /// answers `contention`.
    private func takePresence() async throws {
        guard presence == nil else { return }
        let path = url.path
        try await retrying(phase: .open) {
            try stillOpening()
            guard let taken = try SQLiteMemoryPresence.take(.shared, of: url) else {
                throw Busy(failure: SQLiteConnection.Failure(
                    primary : SQLITE_BUSY,
                    extended: SQLITE_BUSY,
                    message : "a recovery of \(path) holds its presence lock"
                ), phase: .open)
            }
            presence = taken
        }
    }

    /// Lets go of the presence lock once nothing of this store holds the archive's files: no
    /// connection of its own or of a copy still in flight, and no open in progress or done.
    private func releasePresenceWhenIdle() {
        guard liveHandles == 0, lifecycle != .open, lifecycle != .opening else { return }
        presence?.release()
        presence = nil
    }

    /// Whether the store holds the archive's presence lock now: for the package's tests.
    package var holdsPresence: Bool { presence?.isHeld == true }

    private func stillOpening() throws {
        guard lifecycle == .opening else { throw MemoryStoreError.unavailable(.closed) }
    }

    /// The store is still open after an `await`; otherwise the answer is why not.
    private func stillOpen() throws {
        switch lifecycle {
        case .open             : return
        case .failed(let fault): throw MemoryStoreError.unavailable(.failed(fault))
        default                : throw MemoryStoreError.unavailable(.closed)
        }
    }

    /// Opens one counted connection with foreign keys on and verified.
    private func acquire(_ path: String, readOnly: Bool = false, mayCreate: Bool = true) throws -> SQLiteConnection {
        let connection = try Self.connect(path, readOnly: readOnly, mayCreate: mayCreate)
        liveHandles += 1
        return connection
    }

    /// Closes one counted connection; a connection already closed is not counted twice.
    private func release(_ connection: SQLiteConnection) {
        guard connection.isOpen else { return }
        connection.close()
        liveHandles -= 1
        releasePresenceWhenIdle()
    }

    /// Lets go of both connections after a transaction that could not be ended: nothing more goes
    /// through a connection the store does not trust. The fault stays as the reason, for every
    /// later call, until `close`.
    private func invalidate(with fault: MemoryStoreFault) {
        guard lifecycle == .open else { return }
        if let writer { release(writer) }
        if let reader { release(reader) }
        writer    = nil
        reader    = nil
        lifecycle = .failed(fault)
        releasePresenceWhenIdle()
    }

    /// Opens one connection with foreign keys on and verified. The journal is dealt with apart,
    /// because setting it needs the file to be one this build accepts.
    private static func connect(_ path: String, readOnly: Bool, mayCreate: Bool = true) throws -> SQLiteConnection {
        do {
            let connection = try SQLiteConnection(path: path, readOnly: readOnly, mayCreate: mayCreate)
            try connection.execute("PRAGMA foreign_keys = ON")
            guard try integerPragma(connection, "foreign_keys") == 1 else {
                throw refusal(.open, "foreign_keys could not be enabled")
            }
            return connection
        } catch let failure as SQLiteConnection.Failure {
            throw MemoryStoreError(failure, phase: .open)
        }
    }

    /// Puts the file in WAL and this connection in `synchronous=FULL`, verifying both. WAL is a
    /// property of the file: set once here, found by every later connection. A refused journal
    /// mode is an `open` error with code 0, since the library reports it as a value, not an error.
    private static func setJournal(_ connection: SQLiteConnection, phase: MemoryStoreError.Phase) throws {
        let mode = try connection.query("PRAGMA journal_mode = WAL") { try $0.text(0) ?? "" }.first ?? ""
        guard mode == "wal" else {
            throw refusal(phase, "journal_mode=WAL was not accepted; the file answered '\(mode)'")
        }
        try connection.execute("PRAGMA synchronous = FULL")
    }

    /// Confirms the file is in WAL, sets `synchronous=FULL`, and makes the connection read-only.
    private static func verifyJournal(_ connection: SQLiteConnection, phase: MemoryStoreError.Phase) throws {
        do {
            let mode = try textPragma(connection, "journal_mode")
            guard mode == "wal" else {
                throw refusal(phase, "journal_mode is not WAL; the file answered '\(mode)'")
            }
            try connection.execute("PRAGMA synchronous = FULL")
            try connection.execute("PRAGMA query_only = ON")
        } catch {
            throw classified(error, phase: phase)
        }
    }

    /// What an inspection compares a file with: the tables the resource creates, for a refusal that
    /// names them, and the exact objects a file bootstrapped from it holds.
    struct Expected {
        let tables : [String]
        let objects: Set<SQLiteMemorySchema.SchemaObject>

        init(ddl: String) throws {
            tables  = SQLiteMemorySchema.tableNames(in: ddl)
            objects = try SQLiteMemorySchema.objects(of: ddl)
        }
    }

    /// Reads the version and the schema under the write lock and says whether the file is empty
    /// or at the schema this build knows. Every other file is refused, untouched: a future version,
    /// a version 0 file with tables of its own, a version 1 file with tables missing, a version 1
    /// file whose tables lack a column this build writes, and a version 1 file whose tables,
    /// indexes or triggers are not exactly the ones this build creates (an earlier development form
    /// with other constraints).
    static func inspect(_ connection: SQLiteConnection, expected: Expected) throws -> Inspection {
        let tables = expected.tables
        let version  = try integerPragma(connection, "user_version")
        let existing = try connection.query(
            "SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        ) { try $0.text(0) ?? "" }
        switch version {
        case 0 where existing.isEmpty:
            return .empty
        case 0:
            throw MemoryStoreError.schema(.unknownTables(existing))
        case Int64(SQLiteMemorySchema.version):
            let missing = tables.filter { !existing.contains($0) }
            guard missing.isEmpty else { throw MemoryStoreError.schema(.missingTables(missing)) }
            var missingColumns: [String] = []
            for (table, column) in SQLiteMemorySchema.requiredColumns {
                // Table names are this module's own literals; nothing from a caller is spliced in.
                let columns = try connection.query("PRAGMA table_info(\(table))") { try $0.text(1) ?? "" }
                if !columns.contains(column) { missingColumns.append("\(table).\(column)") }
            }
            guard missingColumns.isEmpty else { throw MemoryStoreError.schema(.missingColumns(missingColumns)) }
            let differences = SQLiteMemorySchema.differences(
                found: try SQLiteMemorySchema.objects(in: connection), expected: expected.objects
            )
            guard differences.isEmpty else { throw MemoryStoreError.schema(.differentShape(differences)) }
            return .current
        default:
            throw MemoryStoreError.schema(.future(
                found    : Int32(clamping: version),
                supported: SQLiteMemorySchema.version
            ))
        }
    }

    private static func integerPragma(_ connection: SQLiteConnection, _ name: String) throws -> Int64 {
        // Pragma names are this module's own literals; nothing from a caller is spliced in.
        try connection.query("PRAGMA \(name)") { $0.integer(0) ?? 0 }.first ?? 0
    }

    private static func textPragma(_ connection: SQLiteConnection, _ name: String) throws -> String {
        try connection.query("PRAGMA \(name)") { try $0.text(0) ?? "" }.first ?? ""
    }

    private static func refusal(_ phase: MemoryStoreError.Phase, _ message: String) -> MemoryStoreError {
        .open(MemoryStoreFault(
            code   : MemoryStoreFault.Code(primary: SQLITE_OK, extended: SQLITE_OK),
            phase  : phase,
            message: message
        ))
    }

    /// The store's error for anything a step threw: a library failure by its code and the phase,
    /// an invalid text by its position, the store's own errors unchanged.
    private static func classified(_ error: any Error, phase: MemoryStoreError.Phase) -> any Error {
        switch error {
        case let failure as SQLiteConnection.Failure   : MemoryStoreError(failure, phase: phase)
        case let invalid as SQLiteStatement.InvalidText: MemoryStoreError(invalid)
        default                                        : error
        }
    }

    // MARK: Running a transaction

    private enum Role {
        case writer, reader
    }

    private func connection(_ role: Role) throws -> SQLiteConnection {
        switch lifecycle {
        case .notOpened, .opening: throw MemoryStoreError.unavailable(.notOpened)
        case .closed             : throw MemoryStoreError.unavailable(.closed)
        case .failed(let fault)  : throw MemoryStoreError.unavailable(.failed(fault))
        case .open               : break
        }
        let candidate: SQLiteConnection?
        switch role {
        case .writer: candidate = writer
        case .reader: candidate = reader
        }
        guard let connection = candidate, connection.isOpen else {
            throw MemoryStoreError.unavailable(.closed)
        }
        return connection
    }

    /// Runs the step until it returns or throws anything but `Busy`. A busy answer pauses outside
    /// the step, within the budget, and runs the whole step again; the step must leave the
    /// connection outside any transaction before it throws `Busy`.
    private func retrying<T>(phase: MemoryStoreError.Phase, _ step: () throws -> T) async throws -> T {
        var cycle = WaitingCycle(configuration)
        defer { waited += cycle.waited }
        while true {
            cycle.attempting()
            if Task.isCancelled { throw MemoryStoreError.cancelled(phase) }
            do {
                return try step()
            } catch let busy as Busy {
                try await pauseBeforeRetry(&cycle, after: busy.failure, at: busy.phase)
            } catch let failure as SQLiteConnection.Failure {
                guard failure.isBusy else { throw MemoryStoreError(failure, phase: phase) }
                try await pauseBeforeRetry(&cycle, after: failure, at: phase)
            }
        }
    }

    /// Begins, runs the body, commits, as one retried step. Any failure ends the transaction; a
    /// busy one is retried with the same body, any other is thrown: classified when it is the
    /// library's, unchanged when it is the body's. The connection is never left inside a
    /// transaction: after a failure the store looks at what the library left, rolls back what is
    /// still open, and reports which it found (`cleanup`); a transaction it cannot end makes the
    /// connection untrusted (`invalidate`). While bootstrapping, the begin and the commit are
    /// reported in the bootstrap phase too, since a file that is not a database shows itself at
    /// the first lock.
    private func transaction<T>(
        on connection: SQLiteConnection,
        begin        : String,
        phase        : MemoryStoreError.Phase,
        _ body       : () throws -> T
    ) async throws -> T {
        let beginPhase  = phase == .bootstrap ? phase : MemoryStoreError.Phase.begin
        let commitPhase = phase == .bootstrap ? phase : MemoryStoreError.Phase.commit
        return try await retrying(phase: beginPhase) {
            // A connection let go of while this waited: closed by `close`, or by `invalidate`, whose
            // fault is the answer then, as for every later call.
            guard connection.isOpen else {
                try stillOpen()
                throw MemoryStoreError.unavailable(.closed)
            }
            do {
                try connection.execute(begin)
            } catch let failure as SQLiteConnection.Failure {
                if failure.isBusy { throw Busy(failure: failure, phase: beginPhase) }
                throw MemoryStoreError(failure, phase: beginPhase)
            }
            let value: T
            do {
                value = try body()
            } catch {
                throw ended(after: error, on: connection, phase: phase)
            }
            do {
                try connection.execute("COMMIT")
            } catch let failure as SQLiteConnection.Failure {
                throw ended(after: failure, on: connection, phase: commitPhase)
            }
            return value
        }
    }

    /// Ends the transaction a failure interrupted and answers what to throw: `Busy` for a busy
    /// lock whose transaction ended cleanly, so the step runs again; the classified failure, with
    /// the cleanup beside it, for the library's other answers; the body's own error unchanged. A
    /// cleanup that failed invalidates the store first, whatever the primary error was.
    private func ended(
        after error  : any Error,
        on connection: SQLiteConnection,
        phase        : MemoryStoreError.Phase
    ) -> any Error {
        let cleanup: MemoryStoreFault.Cleanup
        if let refusal = refusedRollback {
            refusedRollback = nil
            cleanup = Self.cleanupOutcome(
                inTransaction     : connection.isInTransaction,
                rollback          : { refusal },
                stillInTransaction: { connection.isInTransaction }
            )
        } else {
            cleanup = Self.endTransaction(on: connection)
        }
        let clean: Bool
        if case .failed = cleanup { clean = false } else { clean = true }
        switch error {
        case let failure as SQLiteConnection.Failure:
            if failure.isBusy, clean { return Busy(failure: failure, phase: phase) }
            if !clean {
                invalidate(with: MemoryStoreFault(
                    code   : MemoryStoreFault.Code(primary: failure.primary, extended: failure.extended),
                    phase  : phase,
                    message: failure.message,
                    cleanup: cleanup
                ))
            }
            return MemoryStoreError(failure, phase: phase, cleanup: cleanup)
        default:
            if !clean {
                invalidate(with: MemoryStoreFault(
                    code   : MemoryStoreFault.Code(primary: SQLITE_OK, extended: SQLITE_OK),
                    phase  : phase,
                    message: "the transaction could not be ended after the body's error",
                    cleanup: cleanup
                ))
            }
            return Self.classified(error, phase: phase)
        }
    }

    /// Looks at the connection after a failure inside a transaction and ends what is still open.
    /// The library rolls some failures back on its own and not others, so this never assumes:
    /// it reads `autocommit`, rolls back when needed, and reads it again.
    static func endTransaction(on connection: SQLiteConnection) -> MemoryStoreFault.Cleanup {
        cleanupOutcome(
            inTransaction     : connection.isInTransaction,
            rollback          : {
                do {
                    try connection.execute("ROLLBACK")
                    return nil
                } catch let failure as SQLiteConnection.Failure {
                    return failure
                } catch {
                    return SQLiteConnection.Failure(
                        primary : SQLITE_MISUSE,
                        extended: SQLITE_MISUSE,
                        message : "\(error)"
                    )
                }
            },
            stillInTransaction: { connection.isInTransaction }
        )
    }

    /// The cleanup decision on its own, over what was observed: nothing to do when the library
    /// already rolled back; rolled back when the store's rollback answered OK and the connection
    /// is outside any transaction; failed otherwise, with the rollback's code and message, or
    /// code 0 when the rollback answered OK and the connection stayed inside a transaction.
    static func cleanupOutcome(
        inTransaction     : Bool,
        rollback          : () -> SQLiteConnection.Failure?,
        stillInTransaction: () -> Bool
    ) -> MemoryStoreFault.Cleanup {
        guard inTransaction else { return .alreadyRolledBack }
        if let failure = rollback() {
            return .failed(MemoryStoreFault.Code(primary: failure.primary, extended: failure.extended), failure.message)
        }
        guard !stillInTransaction() else {
            return .failed(
                MemoryStoreFault.Code(primary: SQLITE_OK, extended: SQLITE_OK),
                "the connection stayed inside a transaction after ROLLBACK"
            )
        }
        return .rolledBack
    }

    /// Pauses before the next attempt, or answers `contention` when another pause would overrun
    /// the cycle's budget, or `cancelled` when the caller's task was cancelled during the pause.
    /// The budget bounds the pauses of the cycle, not the wall clock, so a cycle always holds the
    /// first pause when the configuration was accepted. Called only with no transaction open on
    /// the connection; the observer hears of the pause before it starts.
    private func pauseBeforeRetry(
        _ cycle      : inout WaitingCycle,
        after failure: SQLiteConnection.Failure,
        at phase     : MemoryStoreError.Phase
    ) async throws {
        guard let pause = cycle.nextPause else {
            let fault = MemoryStoreFault(
                code   : MemoryStoreFault.Code(primary: failure.primary, extended: failure.extended),
                phase  : phase,
                message: failure.message
            )
            throw MemoryStoreError.contention(fault, attempts: cycle.attempts, waited: cycle.waited)
        }
        waitObserver?(.pausing(phase, attempt: cycle.attempts))
        let now = clock.now
        do {
            try await Task.sleep(for: pause)
        } catch {
            cycle.interrupted(after: clock.now - now)
            throw MemoryStoreError.cancelled(phase)
        }
        cycle.paused(for: clock.now - now)
        busyRetries += 1
    }

    // A rollback that fails leaves the primary failure in place: used only where a transaction is
    // about to be abandoned with its connection, so nothing later depends on the connection's state.
    private static func rollback(_ connection: SQLiteConnection) {
        guard connection.isInTransaction else { return }
        _ = try? connection.execute("ROLLBACK")
    }
}
