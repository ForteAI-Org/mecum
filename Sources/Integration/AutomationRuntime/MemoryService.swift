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

    init(store: SQLiteMemoryStore) {
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
/// `memory.sqlite.corrupt-<date>`, never deleted, and the newest copy takes its place; with no copy
/// the memory starts empty. Either way `status()` says what happened.
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

        /// How long the end of the process waits for the queue to empty before what is left is a gap.
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
        /// Writes taken from the queue and not yet committed or failed: one at most.
        public let inFlight: Int
        /// Writes committed since the service was made.
        public let written: Int
        /// Writes that failed: each one a fact the archive does not hold.
        public let failed: Int
        /// Writes dropped because the queue was full: facts the archive does not hold either.
        public let dropped: Int
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
    /// Whether a write is taken from the queue and running now.
    private var inFlight = false
    /// False once a close began: no write, copy or open is admitted after that point.
    private var admitting = true
    private var closing: Task<Void, Never>?
    private var lastClose: String?
    private nonisolated let activity = Mutex(Activity())
    private var written = 0
    private var failed = 0
    private var dropped = 0
    private var lastFailure: String?

    private var brains: [String: (version: Int64, brain: UIBrain?)] = [:]

    private var lastBackup: Date?
    private var lastRecovery: String?
    private var backingUp: Task<Void, Never>?

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
            inFlight = true
            do {
                let repositories = try await ready()
                try await write.body(repositories)
                settle(write, error: nil)
            } catch {
                settle(write, error: error)
            }
        }
        drainer = nil
        scheduleBackupIfDue()
    }

    /// Counts a write that left the queue as committed or failed, once: a write the close already
    /// counted as not saved is not counted again when it ends.
    private func settle(_ write: Write, error: (any Error)?) {
        guard inFlight else { return }
        inFlight = false
        activity.withLock { $0.outstanding -= 1 }
        guard let error else {
            written += 1
            return
        }
        failed += 1
        lastFailure = "\(write.label): \(Self.describe(error))"
        Self.log.error("memory write failed: \(write.label, privacy: .public): \(Self.describe(error), privacy: .public)")
    }

    // MARK: Opening

    /// The repositories of the open archive, opening it first when needed. Throws `MemoryUnavailable`
    /// while the service is degraded and the reopen interval has not passed, or when it is closed.
    public func ready() async throws -> MemoryRepositories {
        if let repositories, state == .open { return repositories }
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
            guard state != .closed else {
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
        guard Self.isCorrupt(firstError), FileManager.default.fileExists(atPath: url.path) else { throw firstError }
        let recovery = try recover()
        lastRecovery = recovery
        Self.log.error("memory recovered: \(recovery, privacy: .public)")
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
            lastBackup = Date()
            for old in backups().dropFirst(max(1, configuration.keptBackups)) {
                try? FileManager.default.removeItem(at: old.url)
            }
        } catch {
            Self.log.error("memory copy failed: \(Self.describe(error), privacy: .public)")
        }
    }

    /// Moves a corrupt archive aside with its journal and puts the newest copy in its place, and
    /// says what it did. Nothing is deleted.
    private func recover() throws -> String {
        let manager = FileManager.default
        let stamp   = Self.stamp(Date())
        let aside   = "\(configuration.fileName).corrupt-\(stamp)"
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            guard manager.fileExists(atPath: file.path) else { continue }
            try manager.moveItem(at: file, to: directory.appendingPathComponent(aside + suffix))
        }
        guard let newest = newestBackup() else {
            return "the archive could not be read; it was moved to \(aside) and the memory started empty"
        }
        try manager.copyItem(at: newest.url, to: url)
        return "the archive could not be read; it was moved to \(aside) and the copy of \(Self.stamp(newest.date)) restored"
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

    /// Closes the archive within `closingBudget`, once, whoever asks and however often.
    ///
    /// From the first call nothing new is admitted: a write offered after it is refused and counted
    /// as dropped, and no copy starts. Then, against one deadline on the monotonic clock: a copy in
    /// progress is cancelled (the store removes its partial file, so an incomplete copy is never
    /// published; the next open takes the day's copy again); the queue drains, a busy archive
    /// waited out until the deadline. What the deadline leaves is counted, never lost silently: the
    /// writes still queued as dropped, the one in flight as failed once it ends, or at once if it
    /// does not end within a short grace. The archive is closed last. A second call waits for the
    /// first one's end.
    public func close() async {
        if let closing {
            await closing.value
            return
        }
        guard state != .closed else { return }
        let task = Task { await self.performClose() }
        closing = task
        await task.value
    }

    private func performClose() async {
        admitting = false
        let started  = ContinuousClock.now
        let deadline = started + configuration.closingBudget
        var copyCancelled = false
        if let backingUp {
            backingUp.cancel()
            copyCancelled = true
            await waitUntil(deadline) { self.backingUp == nil }
        }
        let drained = await waitUntil(deadline) { self.drainer == nil && self.queue.isEmpty }
        let leftQueued = queue.count
        if !drained {
            dropped += leftQueued
            activity.withLock { $0.outstanding -= leftQueued }
            queue.removeAll()
            drainer?.cancel()
        }
        if let store { await store.close() }
        let grace = ContinuousClock.now + .milliseconds(250)
        await waitUntil(grace) { self.drainer == nil }
        var abandoned = 0
        if inFlight {
            inFlight = false
            failed  += 1
            abandoned = 1
            activity.withLock { $0.outstanding -= 1 }
            lastFailure = "a write did not end within the close"
        }
        await waitUntil(grace) { self.backingUp == nil }
        state        = .closed
        store        = nil
        repositories = nil
        brains       = [:]
        let took = started.duration(to: .now)
        let summary = "closed in \(took): \(written) written, \(failed) failed, \(dropped) dropped"
            + (leftQueued > 0 && !drained ? ", \(leftQueued) still queued at the deadline" : "")
            + (abandoned > 0 ? ", one write abandoned in flight" : "")
            + (copyCancelled ? ", the copy in progress cancelled" : "")
        lastClose = summary
        if drained && abandoned == 0 {
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
        var version: String?, sourceID: String?
        if let store, state == .open, let diagnostics = try? await store.diagnostics() {
            version  = diagnostics.libraryVersion
            sourceID = diagnostics.librarySourceID
        }
        return Status(path: url.path, state: state, libraryVersion: version, librarySourceID: sourceID,
                      pending: queue.count, inFlight: inFlight ? 1 : 0, written: written, failed: failed, dropped: dropped,
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
        if let store = error as? MemoryStoreError { return "\(store)" }
        if error is CancellationError { return "cancelled" }
        return String(describing: type(of: error)) + ": " + "\(error)".prefix(160)
    }
}
