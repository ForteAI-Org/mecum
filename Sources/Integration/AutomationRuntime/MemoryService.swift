//
//  MemoryService.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 07/10/2026.
//

import Foundation
import Memory
import OSLog
import PerceptionCore
import SQLiteMemory
import Synchronization

/// MemoryClock keeps the three times the living memory's producers need apart:
///
/// - the **calendar** of the facts (`calendarMS`): the wall as it reads, kept as it was even when it
///   runs backwards (a clock change), for `occurred_at_ms`, `started_at_ms` and `completed_at_ms`;
///   a chronology, never subtracted;
/// - the **Brain's clock** (`brainNow`): the calendar read once when this clock was made plus the
///   monotonic time elapsed since, so the instant an application is asked for never runs backwards
///   within the process whatever the wall does;
/// - **durations** (`monotonicNS`, `durationMS(from:to:)`): monotonic readings of this process,
///   compared only with each other, never with a calendar or with another process.
nonisolated public final class MemoryClock: Sendable {

    private let wall: @Sendable () -> Date
    private let monotonic: @Sendable () -> Int64
    private let referenceMS: Int64
    private let referenceNS: Int64

    public init(
        wall     : @escaping @Sendable () -> Date = { Date() },
        monotonic: @escaping @Sendable () -> Int64 = { Int64(clamping: DispatchTime.now().uptimeNanoseconds) }
    ) {
        self.wall        = wall
        self.monotonic   = monotonic
        self.referenceMS = Self.milliseconds(of: wall())
        self.referenceNS = monotonic()
    }

    /// The calendar instant of a fact, as the wall reads now, in milliseconds since 1970.
    public func calendarMS() -> Int64 { Self.milliseconds(of: wall()) }

    /// The process's monotonic clock, in nanoseconds, for durations.
    public func monotonicNS() -> Int64 { monotonic() }

    /// The Brain's clock: the reference calendar plus the monotonic time elapsed since the reference.
    public func brainMS() -> Int64 { referenceMS + max(0, monotonic() - referenceNS) / 1_000_000 }

    /// `brainMS` as a date, at the millisecond.
    public func brainNow() -> Date { Date(timeIntervalSince1970: Double(brainMS()) / 1000) }

    /// Milliseconds between two monotonic readings of this process, never below zero.
    public static func durationMS(from start: Int64, to end: Int64) -> Int64 { max(0, end - start) / 1_000_000 }

    static func milliseconds(of date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }
}

/// MemoryUnavailable is what the service answers while its archive cannot be used: the reason, in a
/// sentence with no content of the agent's in it.
nonisolated public struct MemoryUnavailable: Error, CustomStringConvertible, Sendable, Equatable {

    public let description: String

    public init(_ description: String) { self.description = description }
}

/// MemoryRepositories are the roles of one open archive, as a write or a read receives them.
nonisolated public struct MemoryRepositories: Sendable {

    public let captures    : SQLiteCaptureRepository
    public let scenes      : SQLiteSceneRepository
    public let calls       : SQLiteAgentCallRepository
    public let brains      : SQLiteBrainRepository
    public let applications: SQLiteBrainApplicationRepository
    public let graph       : SQLiteBrainGraphRepository
    public let traces      : SQLiteTraceRepository

    /// The store under the roles, for the package's tests: a write that holds it, as a long
    /// transaction of a producer would.
    package let store: SQLiteMemoryStore

    init(store: SQLiteMemoryStore) {
        self.store   = store
        captures     = SQLiteCaptureRepository(store: store)
        scenes       = SQLiteSceneRepository(store: store)
        calls        = SQLiteAgentCallRepository(store: store)
        brains       = SQLiteBrainRepository(store: store)
        applications = SQLiteBrainApplicationRepository(store: store)
        graph        = SQLiteBrainGraphRepository(store: store)
        traces       = SQLiteTraceRepository(store: store)
    }
}

/// MemoryService is the living memory of one Knowledge directory in this process: the one
/// `memory.sqlite` under it, opened on first use, written by one writer and read without waiting
/// for it. `shared(for:)` hands every session, tool and command of the process the same service
/// for the same directory, as each of them used to open the same JSON directory: none of them owns
/// it and none closes it. The process closes every service once, at its end (`closeAll`).
///
/// Writing never holds up an action. A producer `enqueue`s a write and goes on; the writes run one
/// after another, in the order they were enqueued, on a task of the service's own, so a sample
/// always follows its event and a call's end its start. A busy archive is waited out by that task
/// alone. A write that fails is counted and logged, never retried in a loop and never thrown back at
/// the action: it is a gap, visible in `status()`. A queue that grows past `queueLimit` (the archive
/// stuck for a long time) drops what arrives next and counts it, rather than holding the process's
/// memory without bound. `flush(within:)` waits for what is queued, within a budget, for the few
/// places that read what they just wrote, and for the end of the process.
///
/// A memory that cannot be opened (a schema this build refuses, a library too old, a path that
/// cannot be created) is `degraded`, with the reason, and an open is tried again only after
/// `reopenInterval`: reads answer nothing and writes are gaps meanwhile. Nothing resets or replaces
/// the file.
///
/// Reads of a Brain are cached per application and kept while the archive's data version, as the
/// reading connection sees it, has not moved: a commit by this process or by another one moves it.
///
/// The archive keeps itself recoverable, as the JSON files before it did. Once a `backupInterval`,
/// on opening and then while it is written, the service takes a consistent, verified copy of the
/// archive beside it (`memory.sqlite.backup-<date>`), keeping the newest `keptBackups`. A file the
/// library calls corrupt or not a database is moved aside, with its journal, as
/// `memory.sqlite.corrupt-<date>`, never deleted, and the newest sound copy takes its place; with no
/// copy the memory starts empty. Either way `status()` says what happened. The recovery runs under
/// the archive's exclusive presence lock (`SQLiteMemoryRecovery`): while another process holds the
/// archive it is refused, nothing moves, and the service stays degraded until its next attempt. A
/// recovery that stopped half way, in this process or another, is completed from its record on the
/// next open, or the service stays degraded saying why, with every file kept: it never starts an
/// empty memory in its place.
public actor MemoryService: BrainReading, BrainApplicationStoring {

    nonisolated public struct Configuration: Sendable, Equatable {

        /// The archive's file name under the directory.
        public var fileName: String

        /// The store's waiting policy for a busy lock.
        public var store: SQLiteMemoryStore.Configuration

        /// How long a degraded service waits before it tries to open again.
        public var reopenInterval: Duration

        /// The most writes that may wait in the queue; what arrives beyond it is a counted gap.
        public var queueLimit: Int

        /// The whole close, from its first call to its return (`close()`): the queue drains until the
        /// last fifth of it, at most 500 ms, which is kept for closing the archive.
        public var closingBudget: Duration

        /// How old the newest copy of the archive may be before another is taken.
        public var backupInterval: Duration

        /// How many copies are kept, the newest first.
        public var keptBackups: Int

        public init(
            fileName      : String = "memory.sqlite",
            store         : SQLiteMemoryStore.Configuration = SQLiteMemoryStore.Configuration(),
            reopenInterval: Duration = .seconds(5),
            queueLimit    : Int = 4096,
            closingBudget : Duration = .seconds(3),
            backupInterval: Duration = .seconds(86_400),
            keptBackups   : Int = 3
        ) {
            self.fileName       = fileName
            self.store          = store
            self.reopenInterval = reopenInterval
            self.queueLimit     = queueLimit
            self.closingBudget  = closingBudget
            self.backupInterval = backupInterval
            self.keptBackups    = keptBackups
        }
    }

    /// State is where the service stands with its archive.
    nonisolated public enum State: Sendable, Equatable {
        case notOpened
        case open
        case degraded(String)
        case closed
    }

    /// Status is what a reader may show about the memory: where it is, where it stands, the library it
    /// runs on when open, and what happened to the writes this process offered.
    nonisolated public struct Status: Sendable, Equatable {
        public let path: String
        public let state: State
        public let libraryVersion: String?
        public let librarySourceID: String?
        /// Writes waiting in the queue now, in this process's memory only.
        public let pending: Int
        /// Writes taken from the queue and running now: one at most.
        public let inFlight: Int
        /// Writes that ended with every change of theirs committed, since the service was made.
        public let written: Int
        /// Writes that ended with an error before any change of theirs was committed: each one a fact
        /// the archive does not hold.
        public let failed: Int
        /// Writes that ended with an error after some of their changes were committed (a call's
        /// record without its start): the archive holds a part of each.
        public let partial: Int
        /// Writes that never ran: the queue was full, the close had begun, or the close's bound came
        /// while they waited. Facts the archive does not hold either.
        public let dropped: Int
        /// Writes still running when the close returned, which the archive may hold whole, in part or
        /// not at all. One that ends later in the process leaves this count for the one it ended in.
        public let unsettled: Int
        /// The last failure, in a sentence with no content of the agent's.
        public let lastFailure: String?
        /// When the newest copy of the archive was taken, when one exists.
        public let lastBackup: Date?
        /// What the service did with an archive it found corrupt, when it found one.
        public let lastRecovery: String?
        /// How the close went, once the service closed: how long it took, what it saved and what not.
        public let lastClose: String?
    }

    /// Activity is what a quitting process may ask without waiting for the actor: whether this
    /// service still holds writes not yet committed, or a copy in progress.
    private struct Activity {
        var outstanding = 0
        var copying     = false
    }

    /// One write as it waits in the queue: a label for the log and the body.
    private struct Write {
        let label: String
        let body: @Sendable (MemoryRepositories) async throws -> Void
    }

    nonisolated public let directory: URL
    nonisolated public let clock: MemoryClock
    nonisolated public let configuration: Configuration
    nonisolated public var url: URL { directory.appendingPathComponent(configuration.fileName) }

    private var store: SQLiteMemoryStore?
    private var repositories: MemoryRepositories?
    private var state: State = .notOpened
    private var degradedSince: ContinuousClock.Instant?
    private var opening: Task<MemoryRepositories, any Error>?

    private var queue: [Write] = []
    private var drainer: Task<Void, Never>?
    /// The write taken from the queue and running now, with the tally of what it committed.
    private var running: (label: String, tally: SQLiteMemoryStore.CommitTally)?
    /// Whether the close counted the running write as unsettled, so its end corrects that count.
    private var runningUnsettled = false
    /// False from the first `close()` call on: no write, read, open or copy is admitted after it, and
    /// only the writes already accepted run, to be drained.
    private var admitting = true
    private var closing: Task<Void, Never>?
    /// True once the close let go of the archive: an open still in flight then closes what it opened.
    private var storeClosing = false
    private var lastClose: String?
    private nonisolated let activity = Mutex(Activity())
    private var written = 0
    private var failed = 0
    private var partial = 0
    private var dropped = 0
    private var unsettled = 0
    private var lastFailure: String?

    private var brains: [String: (version: Int64, brain: UIBrain?)] = [:]

    private var lastBackup: Date?
    private var lastRecovery: String?
    private var backingUp: Task<Void, Never>?
    /// How the last copy ended: handed over, or abandoned with nothing published.
    private var lastCopyPublished: Bool?

    /// A test's seam into the copy, for the package's tests only: run before the snapshot starts.
    private var beforeBackup: (@Sendable () async throws -> Void)?

    private static let log = Logger(subsystem: "dev.forte.Mecum", category: "Memory")

    public init(directory: URL, configuration: Configuration = Configuration(), clock: MemoryClock = MemoryClock()) {
        self.directory     = directory
        self.configuration = configuration
        self.clock         = clock
    }

    // MARK: One service per directory

    private static let services = Mutex<[String: MemoryService]>([:])

    /// The service of the directory for this process, made on first request. Every caller of the same
    /// directory gets the same service, so the process has one writer per archive.
    public static func shared(for directory: URL) -> MemoryService {
        let key = directory.standardizedFileURL.resolvingSymlinksInPath().path
        return services.withLock { services in
            if let known = services[key] { return known }
            let made = MemoryService(directory: directory)
            services[key] = made
            return made
        }
    }

    /// Closes every shared service of the process, each within its closing budget: what the queue
    /// still holds when the budget is spent is a gap. For the end of the process only; a service it
    /// closes stays closed.
    public static func closeAll() async {
        let all = services.withLock { Array($0.values) }
        await withTaskGroup(of: Void.self) { group in
            for service in all { group.addTask { await service.close() } }
        }
    }

    /// Whether any service of the process still holds writes not committed or a copy in progress:
    /// what a quitting process asks before it decides it can end at once. It does not wait.
    nonisolated public static var hasUnfinishedWork: Bool {
        services.withLock { services in
            services.values.contains { $0.activity.withLock { $0.outstanding > 0 || $0.copying } }
        }
    }

    /// Whether the archive's file is there now, without opening it.
    nonisolated public var archiveExists: Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: Writing

    /// Adds a write to the queue and returns at once. The write runs after every write enqueued before
    /// it; its failure is a counted gap, never an error for the caller.
    public func enqueue(_ label: String, _ body: @escaping @Sendable (MemoryRepositories) async throws -> Void) {
        guard admitting, state != .closed else {
            dropped += 1
            return
        }
        guard queue.count < configuration.queueLimit else {
            dropped += 1
            if dropped == 1 || dropped.isMultiple(of: 100) {
                Self.log.error("memory queue full: \(self.dropped) writes dropped")
            }
            return
        }
        queue.append(Write(label: label, body: body))
        activity.withLock { $0.outstanding += 1 }
        if drainer == nil { drainer = Task { await self.drain() } }
    }

    /// Waits until every write enqueued before this call has run, or until the budget is spent,
    /// whichever comes first. True when the queue emptied in time.
    @discardableResult
    public func flush(within budget: Duration) async -> Bool {
        let deadline = ContinuousClock.now + budget
        while drainer != nil || !queue.isEmpty {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }

    private func drain() async {
        while !queue.isEmpty, !Task.isCancelled {
            let write = queue.removeFirst()
            let tally = SQLiteMemoryStore.CommitTally()
            running = (write.label, tally)
            do {
                try await SQLiteMemoryStore.$tally.withValue(tally) {
                    try await write.body(try await self.open())
                }
                settle(write, tally: tally, error: nil)
            } catch {
                settle(write, tally: tally, error: error)
            }
        }
        drainer = nil
        scheduleBackupIfDue()
    }

    /// Counts a write that ended, once, by what it committed: written when it ended without an error,
    /// failed when it ended with one before any commit, partial when after one. A write the close
    /// counted as unsettled leaves that count for this one.
    private func settle(_ write: Write, tally: SQLiteMemoryStore.CommitTally, error: (any Error)?) {
        running = nil
        if runningUnsettled {
            runningUnsettled = false
            unsettled -= 1
        } else {
            activity.withLock { $0.outstanding -= 1 }
        }
        guard let error else {
            written += 1
            return
        }
        if tally.commits > 0 { partial += 1 } else { failed += 1 }
        let saved = tally.commits > 0 ? " after \(tally.commits) of its changes were saved" : ""
        lastFailure = "\(write.label)\(saved): \(Self.describe(error))"
        Self.log.error("memory write failed\(saved, privacy: .public): \(write.label, privacy: .public): \(Self.describe(error), privacy: .public)")
    }

    // MARK: Opening

    /// The repositories of the open archive, opening it first when needed. Throws `MemoryUnavailable`
    /// while the service is degraded and the reopen interval has not passed, and from the first
    /// `close()` call on: a new request is not admitted once the close began.
    public func ready() async throws -> MemoryRepositories {
        guard admitting else {
            throw MemoryUnavailable(state == .closed ? "the memory is closed" : "the memory is closing")
        }
        return try await open()
    }

    /// The repositories for a write already accepted: during a close as well, until it let go of the
    /// archive, so the queue it drains can still be saved.
    private func open() async throws -> MemoryRepositories {
        if let repositories, state == .open { return repositories }
        guard !storeClosing else { throw MemoryUnavailable("the memory is closed") }
        switch state {
            case .closed:
                throw MemoryUnavailable("the memory is closed")
            case .degraded(let reason):
                if let since = degradedSince, ContinuousClock.now - since < configuration.reopenInterval {
                    throw MemoryUnavailable(reason)
                }
            case .notOpened, .open:
                break
        }
        if let opening { return try await opening.value }
        let attempt = Task { try await self.performOpen() }
        opening = attempt
        defer { opening = nil }
        return try await attempt.value
    }

    private func performOpen() async throws -> MemoryRepositories {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = try await openRecovering()
            guard state != .closed, !storeClosing else {
                await store.close()
                throw MemoryUnavailable("the memory is closed")
            }
            let repositories  = MemoryRepositories(store: store)
            self.store        = store
            self.repositories = repositories
            state             = .open
            degradedSince     = nil
            scheduleBackupIfDue()
            return repositories
        } catch {
            if state != .closed {
                let reason = "could not open: \(Self.describe(error))"
                state         = .degraded(reason)
                degradedSince = .now
                Self.log.error("memory degraded: \(reason, privacy: .public)")
            }
            throw error
        }
    }

    // MARK: Test seams

    /// Runs `gate` before each copy's snapshot. For the package's tests only.
    package func setBeforeBackup(_ gate: (@Sendable () async throws -> Void)?) {
        beforeBackup = gate
    }

    /// Forwards the store's waiting events, once the archive is open. For the package's tests only.
    package func observeStoreWaits(_ observer: (@Sendable (SQLiteMemoryStore.WaitEvent) -> Void)?) async {
        await store?.observeWaits(observer)
    }

    /// Holds every copy between two of its steps at `gate`, once the archive is open. For the
    /// package's tests only.
    package func holdCopySteps(_ gate: (@Sendable () async throws -> Void)?) async {
        await store?.holdSnapshots(between: gate)
    }

    // MARK: Copies and recovery

    /// Opens the store; a file the library calls corrupt is moved aside and the newest copy restored
    /// first, then the store is opened once more.
    private func openRecovering() async throws -> SQLiteMemoryStore {
        let firstError: any Error
        do {
            return try await SQLiteMemoryStore.open(at: url, configuration: configuration.store)
        } catch {
            firstError = error
        }
        let interrupted: Bool
        if case MemoryStoreError.unavailable(.interruptedRecovery) = firstError { interrupted = true } else { interrupted = false }
        guard interrupted || (Self.isCorrupt(firstError) && FileManager.default.fileExists(atPath: url.path)) else {
            throw firstError
        }
        let restoredOrEmpty = { (restored: String?) in restored.map { "the copy \($0) restored" } ?? "the memory started empty" }
        switch try SQLiteMemoryRecovery.recover(url, copies: { self.backups().map(\.url) }, stamp: Self.stamp(Date())) {
        case .inUse:
            throw MemoryUnavailable("the archive could not be read and another process holds it: "
                                    + "the recovery was refused and nothing was moved")
        case .notCorrupt:
            // Recovered by another process since the error, or readable now: opened as it is.
            break
        case .recovered(let aside, let restored):
            let recovery = "the archive could not be read; it was moved to \(aside) and " + restoredOrEmpty(restored)
            lastRecovery = recovery
            Self.log.error("memory recovered: \(recovery, privacy: .public)")
        case .resumed(let aside, let restored):
            let recovery = "a recovery that had stopped half way was completed from its record: the archive was moved "
                + "to \(aside) and " + restoredOrEmpty(restored)
            lastRecovery = recovery
            Self.log.error("memory recovered: \(recovery, privacy: .public)")
        }
        return try await SQLiteMemoryStore.open(at: url, configuration: configuration.store)
    }

    /// Starts a copy of the archive when the newest one is older than `backupInterval`, unless one
    /// is being taken. The copy runs beside the writes; it never holds them up.
    private func scheduleBackupIfDue() {
        guard admitting, state == .open, backingUp == nil else { return }
        if let newest = lastBackup ?? newestBackup()?.date,
           Date().timeIntervalSince(newest) < Double(configuration.backupInterval.components.seconds) { return }
        backingUp = Task { await self.backup() }
    }

    /// Takes a verified copy of the archive and keeps the newest `keptBackups`.
    private func backup() async {
        activity.withLock { $0.copying = true }
        defer {
            backingUp = nil
            activity.withLock { $0.copying = false }
        }
        guard let store else { return }
        let stamp       = Self.stamp(Date())
        let destination = directory.appendingPathComponent("\(configuration.fileName).backup-\(stamp)")
        do {
            if let beforeBackup { try await beforeBackup() }
            _ = try await store.snapshot(to: destination)
            lastBackup        = Date()
            lastCopyPublished = true
            for old in backups().dropFirst(max(1, configuration.keptBackups)) {
                try? FileManager.default.removeItem(at: old.url)
            }
        } catch {
            lastCopyPublished = false
            Self.log.error("memory copy failed: \(Self.describe(error), privacy: .public)")
        }
    }

    /// The copies of the archive beside it, the newest first.
    private nonisolated func backups() -> [(url: URL, date: Date)] {
        let prefix = "\(configuration.fileName).backup-"
        let files  = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
    }

    private nonisolated func newestBackup() -> (url: URL, date: Date)? { backups().first }

    /// Whether the library said the file is corrupt or is not a database at all.
    nonisolated static func isCorrupt(_ error: any Error) -> Bool {
        let fault: MemoryStoreFault?
        switch error as? MemoryStoreError {
            case .open(let f)?, .failed(let f)?, .locked(let f)?, .contract(let f)?: fault = f
            case .unavailable(.failed(let f))?: fault = f
            default: fault = nil
        }
        guard let fault else { return false }
        return fault.code.primary == 11 || fault.code.primary == 26
    }

    private nonisolated static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale     = Locale(identifier: "en_US_POSIX")
        formatter.timeZone   = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss.SSS'Z'"
        return formatter.string(from: date)
    }

    /// Closes the archive within `closingBudget`, once, whoever asks and however often, and accounts
    /// for every write it was offered.
    ///
    /// Admission ends at the first call, before it returns to the caller's actor: a write offered
    /// after it is refused and counted as dropped, a read or an open (`ready()` and what calls it) is
    /// refused, and no copy starts. Only the writes already accepted run on. Then, against one
    /// deadline on the monotonic clock, `closingBudget` after the first call:
    ///
    /// 1. a copy in progress is cancelled: the store removes its partial file and publishes nothing
    ///    after the cancellation; the next open takes the day's copy again;
    /// 2. the queue drains until the last fifth of the bound (at most 500 ms of it), a busy archive
    ///    waited out meanwhile; what is still queued then never runs and is counted as dropped, and
    ///    the running write is cancelled;
    /// 3. the archive is closed by a task of its own, and the close waits, until the deadline, for it,
    ///    for the running write to end and for the copy to let go.
    ///
    /// The close returns at the deadline whatever is left, never waiting on past it: a synchronous
    /// operation that holds the store (a long transaction, a copy's verification) finishes after the
    /// return, and the archive closes when it ends, or with the process. A write still running then is
    /// unsettled, since it may still commit; if it ends later in the process, it is counted again by
    /// how it ended. `lastClose` says which of these happened. A second call waits for the first.
    public func close() async {
        if let closing {
            await closing.value
            return
        }
        guard state != .closed else { return }
        admitting = false
        let task = Task { await self.performClose() }
        closing = task
        await task.value
    }

    /// The part of a close's bound kept for closing the archive once the queue's drain is over.
    static func closingReserve(of budget: Duration) -> Duration {
        min(budget / 5, .milliseconds(500))
    }

    private func performClose() async {
        let started  = ContinuousClock.now
        let deadline = started + configuration.closingBudget
        let copying  = backingUp != nil
        backingUp?.cancel()
        let drained = await waitUntil(deadline - Self.closingReserve(of: configuration.closingBudget)) {
            self.drainer == nil && self.queue.isEmpty
        }
        let leftQueued = drained ? 0 : queue.count
        if !drained {
            dropped += leftQueued
            activity.withLock { $0.outstanding -= leftQueued }
            queue.removeAll()
            drainer?.cancel()
        }
        storeClosing = true
        opening?.cancel()
        let archiveClosed = Flag()
        if let store {
            Task { await store.close(); archiveClosed.raise() }
        } else {
            archiveClosed.raise()
        }
        await waitUntil(deadline) { archiveClosed.isRaised && self.running == nil && self.backingUp == nil }
        var stillRunning = ""
        if let running {
            unsettled       += 1
            runningUnsettled = true
            activity.withLock { $0.outstanding -= 1 }
            stillRunning = ", one write (\(running.label)) still running at the bound after \(running.tally.commits) commits"
        }
        let copy: String
        switch (copying, backingUp == nil, lastCopyPublished) {
            case (false, _, _):        copy = ""
            case (true, false, _):     copy = ", the copy still stopping at the bound (it publishes nothing once stopped)"
            case (true, true, true?):  copy = ", the copy in progress finished before it was stopped"
            case (true, true, _):      copy = ", the copy in progress stopped with nothing published"
        }
        state        = .closed
        store        = nil
        repositories = nil
        brains       = [:]
        let took = started.duration(to: .now)
        let summary = "closed in \(took): \(written) written, \(failed) failed, \(partial) partial, \(dropped) dropped, "
            + "\(unsettled) unsettled"
            + (leftQueued > 0 ? ", \(leftQueued) still queued at the end of the drain" : "")
            + stillRunning + copy
            + (archiveClosed.isRaised ? "" : ", the archive still closing at the bound (a synchronous operation holds it; "
               + "it closes when that ends, or with the process)")
        lastClose = summary
        if drained && stillRunning.isEmpty && archiveClosed.isRaised {
            Self.log.info("memory \(summary, privacy: .public)")
        } else {
            Self.log.error("memory \(summary, privacy: .public)")
        }
    }

    /// Waits until `done` holds or the deadline passes, whichever is first; true when it holds.
    @discardableResult
    private func waitUntil(_ deadline: ContinuousClock.Instant, _ done: () -> Bool) async -> Bool {
        while !done() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }

    /// Flag is raised once, by a task the close does not wait on past its bound, and read without waiting.
    private final class Flag: Sendable {

        private let raised = Mutex(false)

        func raise() { raised.withLock { $0 = true } }

        var isRaised: Bool { raised.withLock { $0 } }
    }

    // MARK: Reading

    /// The stored Brain of an application, cached while the archive has not changed since it was read.
    public func brain(of bundleID: String) async throws -> UIBrain? {
        let repositories = try await ready()
        guard let store else { throw MemoryUnavailable("the memory is closed") }
        let version = try await store.dataVersion()
        if let cached = brains[bundleID], cached.version == version { return cached.brain }
        let brain = try await repositories.brains.brain(of: bundleID)
        brains[bundleID] = (version, brain)
        return brain
    }

    /// Applies a Brain application at once, outside the queue, for a caller that needs its answer
    /// (a test, a command line). Producers on an action's path enqueue instead.
    public func apply(_ command: BrainApplicationCommand) async throws -> BrainApplicationResult {
        try await ready().applications.apply(command)
    }

    public func application(_ key: BrainApplicationKey) async throws -> BrainApplication? {
        try await ready().applications.application(key)
    }

    /// Where the memory stands, without opening it.
    public func status() async -> Status {
        // The library linked into this process, the one the archive is or would be opened with.
        var version: String? = SQLiteLibrary.version, sourceID: String? = SQLiteLibrary.sourceID
        if let store, state == .open, let diagnostics = try? await store.diagnostics() {
            version  = diagnostics.libraryVersion
            sourceID = diagnostics.librarySourceID
        }
        return Status(path: url.path, state: state, libraryVersion: version, librarySourceID: sourceID,
                      pending: queue.count, inFlight: running == nil ? 0 : 1, written: written, failed: failed,
                      partial: partial, dropped: dropped, unsettled: unsettled,
                      lastFailure: lastFailure, lastBackup: lastBackup ?? newestBackup()?.date,
                      lastRecovery: lastRecovery, lastClose: lastClose)
    }

    /// The archive's applications and counts.
    public func overview() async throws -> MemoryOverview {
        try await ready().graph.overview()
    }

    /// A stored call, for readers and tests.
    public func call(_ eventID: String) async throws -> AgentCall? {
        try await ready().calls.call(eventID)
    }

    /// The calls of a trace in local order.
    public func calls(inTrace traceID: String, limit: Int = 200) async throws -> [AgentCall] {
        try await ready().calls.calls(inTrace: traceID, after: nil, limit: limit)
    }

    /// A stored sample.
    public func sample(_ key: CaptureSampleKey) async throws -> CaptureSample? {
        try await ready().captures.sample(key)
    }

    /// A stored event.
    public func event(_ eventID: String) async throws -> MemoryEventRecord? {
        try await ready().captures.event(eventID)
    }

    // MARK: Reasons

    /// A sentence for an error of the memory: its kind and case, never a text the agent typed or read.
    nonisolated public static func describe(_ error: any Error) -> String {
        if let unavailable = error as? MemoryUnavailable { return unavailable.description }
        if case MemoryStoreError.unavailable(.interruptedRecovery(let why))? = error as? MemoryStoreError { return why }
        if let store = error as? MemoryStoreError { return "\(store)" }
        if error is CancellationError { return "cancelled" }
        return String(describing: type(of: error)) + ": " + "\(error)".prefix(160)
    }
}
