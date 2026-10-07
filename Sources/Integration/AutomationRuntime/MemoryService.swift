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

        public init(
            fileName      : String = "memory.sqlite",
            store         : SQLiteMemoryStore.Configuration = SQLiteMemoryStore.Configuration(),
            reopenInterval: Duration = .seconds(5),
            queueLimit    : Int = 4096,
            closingBudget : Duration = .seconds(3)
        ) {
            self.fileName       = fileName
            self.store          = store
            self.reopenInterval = reopenInterval
            self.queueLimit     = queueLimit
            self.closingBudget  = closingBudget
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
        /// Writes waiting in the queue now.
        public let pending: Int
        /// Writes committed since the service was made.
        public let written: Int
        /// Writes that failed: each one a fact the archive does not hold.
        public let failed: Int
        /// Writes dropped because the queue was full: facts the archive does not hold either.
        public let dropped: Int
        /// The last failure, in a sentence with no content of the agent's.
        public let lastFailure: String?
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
    private var written = 0
    private var failed = 0
    private var dropped = 0
    private var lastFailure: String?

    private var brains: [String: (version: Int64, brain: UIBrain?)] = [:]

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

    /// Whether the archive's file is there now, without opening it.
    nonisolated public var archiveExists: Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: Writing

    /// Adds a write to the queue and returns at once. The write runs after every write enqueued before
    /// it; its failure is a counted gap, never an error for the caller.
    public func enqueue(_ label: String, _ body: @escaping @Sendable (MemoryRepositories) async throws -> Void) {
        guard state != .closed else {
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
        while !queue.isEmpty {
            let write = queue.removeFirst()
            do {
                let repositories = try await ready()
                try await write.body(repositories)
                written += 1
            } catch {
                failed += 1
                lastFailure = "\(write.label): \(Self.describe(error))"
                Self.log.error("memory write failed: \(write.label, privacy: .public): \(Self.describe(error), privacy: .public)")
            }
        }
        drainer = nil
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
            let store = try await SQLiteMemoryStore.open(at: url, configuration: configuration.store)
            guard state != .closed else {
                await store.close()
                throw MemoryUnavailable("the memory is closed")
            }
            let repositories  = MemoryRepositories(store: store)
            self.store        = store
            self.repositories = repositories
            state             = .open
            degradedSince     = nil
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

    /// Closes the archive after the queue empties or the closing budget is spent. Definitive.
    public func close() async {
        guard state != .closed else { return }
        await flush(within: configuration.closingBudget)
        let left = queue.count
        if left > 0 {
            dropped += left
            queue.removeAll()
            Self.log.error("memory closed with \(left) writes not saved")
        }
        drainer?.cancel()
        state = .closed
        if let store { await store.close() }
        store        = nil
        repositories = nil
        brains       = [:]
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
                      pending: queue.count, written: written, failed: failed, dropped: dropped, lastFailure: lastFailure)
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
