//
//  MemoryService.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 03/10/2026.
//

import Foundation
import Memory
import PerceptionCore
import SQLiteMemory
import Synchronization

/// MemoryClock keeps the three times the living memory's producers need apart:
///
/// - the **calendar** of the facts (`calendarMS`): the wall as it reads, kept as it was even when it
///   runs backwards (a clock change), for `occurred_at_ms`, `started_at_ms` and `completed_at_ms`;
///   a chronology, never subtracted;
/// - the **Brain's clock** (`brainMS`): the calendar read once when this clock was made plus the
///   monotonic time elapsed since, so the instant an application is asked for never runs backwards
///   within the process whatever the wall does; the store's own guard keeps it from running
///   backwards across processes;
/// - **durations** (`monotonicNS`, `durationMS(from:to:)`): monotonic readings of this process,
///   compared only with each other, never with a calendar or with another process.
///
/// Both sources are injected, so a proof can move the wall backwards and the monotonic clock forwards
/// by hand.
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

    /// The calendar instant of a fact, as a date.
    public func calendar() -> Date { wall() }

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
/// sentence with no content of the agent's in it, and nothing else.
nonisolated public struct MemoryUnavailable: Error, CustomStringConvertible, Sendable, Equatable {

    public let description: String

    public init(_ description: String) { self.description = description }
}

/// MemoryService is the living memory of one Knowledge directory in this process: the one
/// `memory.sqlite` under it, opened on first use and closed by its owner, handed to the engine's
/// seams and to the producers as the pure roles they need (`BrainReading`, `BrainApplicationStoring`,
/// `CaptureStoring`, `SceneStoring`, `AgentCallStoring`). SQLite stays here, in the composition: the
/// pure modules see the roles, the producers see this service.
///
/// Ownership: the app's model owns one for its workspace, `mecum chat` one for the chat, and each
/// vertical command one for its invocation; a `BrokeredAutomationSession` and the tools over it share
/// the owner's. The owner calls `close` when it ends; a producer never does.
///
/// Waiting: a busy archive is waited for, cycle after cycle of the store's budget, outside any
/// transaction and with its pauses, until the lock is free, the caller is cancelled, the owner
/// closes, or a failure that is not contention: at the open (the owner's one attempt, shared by every
/// caller, each waiting under its own cancellation: cancelling one caller cancels no other's wait
/// and never the attempt), on a read and on a write alike. A spent budget is never a failure, a
/// degraded state or a lost save. A memory that truly cannot be used is a state, never a stop: an
/// archive that will not open, a schema this build does not know or a store that let go of its
/// connections leaves the service `degraded`, with the reason, until `reopenInterval` has passed and
/// an open is tried again at the same path (no reset, no other file). A constraint, an identity
/// conflict, a malformed text or a cancellation is the producer's to report and degrades nothing.
///
/// Finalization: a fact that already exists (a sample taken, a learning, the end of a call that ran)
/// is written through `finalize`, which the caller's cancellation does not cut. While the caller is
/// not cancelled a finalization waits as every other call does, cycle after cycle, with no deadline
/// of its own: a busy archive is waited out and the fact is saved once the lock goes. Once the owner
/// stops, its finalizations share one `finalizationBudget`: the owner is the `MemoryFinalizationScope`
/// in force (a turn of an agent, a call outside a turn, one invocation of a vertical command), and the
/// budget runs on the monotonic clock from the owner's stop (the scope's `stop()`, or the first
/// cancelled finalization it sees). Samples, the Brain's learning, a call's end, a batch's skipped
/// steps and its own end all spend the same remaining time; once it is spent, every finalization the
/// stopped owner still offers is an explicit gap at once, with no new wait. Another owner on the same
/// service is not touched. Reasons name the error's case, phase and code, never a label, a title or a
/// text the agent typed or read.
public actor MemoryService: BrainReading, BrainApplicationStoring, CaptureStoring, SceneStoring, AgentCallStoring,
    MemoryTraceReading, MemoryReading {

    nonisolated public struct Configuration: Sendable, Equatable {

        /// The archive's file name under the directory.
        public var fileName: String

        /// The store's waiting policy: one cycle's budget and its pauses.
        public var store: SQLiteMemoryStore.Configuration

        /// How long a degraded service waits before it tries to open again.
        public var reopenInterval: Duration

        /// How long the finalizations of one stopped owner (`MemoryFinalizationScope`) may still wait for
        /// the archive, together, from the owner's stop, before what is left is an explicit gap. It
        /// bounds nothing while the caller is not cancelled.
        public var finalizationBudget: Duration

        public init(
            fileName          : String = "memory.sqlite",
            store             : SQLiteMemoryStore.Configuration = SQLiteMemoryStore.Configuration(),
            reopenInterval    : Duration = .seconds(5),
            finalizationBudget: Duration = .seconds(3)
        ) {
            self.fileName           = fileName
            self.store              = store
            self.reopenInterval     = reopenInterval
            self.finalizationBudget = finalizationBudget
        }
    }

    /// State is where the service stands with its archive.
    nonisolated public enum State: Sendable, Equatable {
        case notOpened
        /// The owner's open attempt is waiting for the archive.
        case opening
        case ready
        /// The archive cannot be used; the reason is safe to show and to log.
        case degraded(String)
        case closed
    }

    /// Status is what the service says about itself, for a person: the path, the state and the
    /// store's own diagnostics while it is open. It reads nothing from the schema's rows.
    nonisolated public struct Status: Sendable, Equatable {

        public let path: String
        public let state: State
        public let diagnostics: SQLiteMemoryStore.Diagnostics?

        public var isReady: Bool { state == .ready }

        /// The store's own facts, one per line, for a diagnosis: the schema, the library, the journal,
        /// the foreign keys and the work since the open. Empty while the archive is not open.
        public var technicalDetails: [String] {
            guard let diagnostics else { return [] }
            return [
                "schema \(diagnostics.schemaVersion), SQLite \(diagnostics.libraryVersion) (\(diagnostics.librarySourceID))",
                "journal \(diagnostics.journalMode), synchronous \(diagnostics.synchronous), foreign keys "
                    + (diagnostics.foreignKeysEnabled ? "on" : "off"),
                "since the open: \(diagnostics.commits) commits, \(diagnostics.busyRetries) busy retries, "
                    + "\(diagnostics.exhaustedCycles) exhausted lock budgets, \(diagnostics.retainedWrites) writes waiting"
                    + (diagnostics.bootstrappedNow ? "; created by this open" : ""),
            ]
        }

        /// One line for a log or a terminal.
        public var sentence: String {
            switch state {
                case .notOpened          : "memory: not opened yet (\(path))"
                case .opening            : "memory: waiting for the archive (\(path))"
                case .ready              : "memory: \(path) (schema \(diagnostics?.schemaVersion ?? 0), "
                    + "\(diagnostics?.commits ?? 0) commits since open)"
                case .degraded(let why)  : "memory degraded: \(why) (\(path)); tools go on without it"
                case .closed             : "memory: closed (\(path))"
            }
        }
    }

    private struct Repositories {
        let store: SQLiteMemoryStore
        let captures: SQLiteCaptureRepository
        let scenes: SQLiteSceneRepository
        let brains: SQLiteBrainRepository
        let applications: SQLiteBrainApplicationRepository
        let calls: SQLiteAgentCallRepository
        let traces: SQLiteTraceRepository
        let graph: SQLiteBrainGraphRepository

        init(store: SQLiteMemoryStore) {
            self.store        = store
            self.captures     = SQLiteCaptureRepository(store: store)
            self.scenes       = SQLiteSceneRepository(store: store)
            self.brains       = SQLiteBrainRepository(store: store)
            self.applications = SQLiteBrainApplicationRepository(store: store)
            self.calls        = SQLiteAgentCallRepository(store: store)
            self.traces       = SQLiteTraceRepository(store: store)
            self.graph        = SQLiteBrainGraphRepository(store: store)
        }
    }

    private enum Lifecycle {
        case notOpened
        /// The open attempt in flight: the owner's (a producer's open, which creates and bootstraps)
        /// or a reader's (`openForReading`, which takes only an existing archive).
        case opening(Task<Repositories, any Error>, forReading: Bool)
        case ready(Repositories)
        case degraded(reason: String, since: ContinuousClock.Instant)
        case closed
    }

    public nonisolated let directory: URL
    public nonisolated let url: URL
    public nonisolated let configuration: Configuration

    /// The clock every producer over this service stamps with.
    public nonisolated let clock: MemoryClock

    private var lifecycle: Lifecycle = .notOpened

    /// A caller waiting for the open attempt in flight, resumable on its own, and whether it reads only.
    private struct Waiter {
        let continuation: CheckedContinuation<Repositories, any Error>
        let forReading: Bool
    }

    /// The callers waiting for the open attempt in flight.
    private var waiters: [UUID: Waiter] = [:]

    /// Remembers the directory and the policy. Nothing is opened until the first use or `open`.
    public init(directory: URL, configuration: Configuration = Configuration(), clock: MemoryClock = MemoryClock()) {
        self.directory     = directory
        self.url           = directory.appendingPathComponent(configuration.fileName, isDirectory: false)
        self.configuration = configuration
        self.clock         = clock
    }

    // MARK: Lifecycle

    /// Opens the archive, creating the directory and bootstrapping an empty file, waiting out a busy
    /// lock, or throws why it cannot (`MemoryUnavailable`), which also leaves the service degraded.
    /// Idempotent while open; cancellable for this caller alone.
    public func open() async throws {
        _ = try await repositories()
    }

    /// Opens on first use and says where the service stands, never throwing: the caller reads the
    /// status and goes on. A degraded service is retried here once its interval has passed.
    @discardableResult
    public func ready() async -> Status {
        _ = try? await repositories()
        return await status()
    }

    /// Opens the archive for a reader: only a file that is already a Mecum archive at this build's
    /// schema (`SQLiteMemoryStore.Opening.existingArchive`), never creating the directory, the file
    /// or the schema, and never changing a file it refuses. An open service answers at once; an open
    /// in flight, the owner's or another reader's, is joined and shared, under this caller's own
    /// cancellation; a degraded or closed service answers why. A refusal (a missing file, a file
    /// with no schema yet, a schema this build does not know) is thrown as the store said it, and
    /// leaves the service as it was before the reading: not degraded, not a disabled writer, so the
    /// owner's next open is a producer's open as ever, and a producer that joined the reader's
    /// attempt meanwhile has its own open started at once. A busy archive is waited out as at any
    /// open. Nothing here closes the service: its owner does.
    public func openForReading() async throws {
        switch lifecycle {
            case .ready:
                return
            case .closed:
                throw Self.closedError
            case .degraded(let reason, _):
                throw MemoryUnavailable(reason)
            case .notOpened:
                startOpening(forReading: true)
            case .opening:
                break
        }
        _ = try await awaitOpening(forReading: true)
    }

    /// Where the service stands now, with the store's diagnostics while it is open.
    public func status() async -> Status {
        switch lifecycle {
            case .notOpened:
                return Status(path: url.path, state: .notOpened, diagnostics: nil)
            case .opening:
                return Status(path: url.path, state: .opening, diagnostics: nil)
            case .ready(let repositories):
                return Status(path: url.path, state: .ready, diagnostics: try? await repositories.store.diagnostics())
            case .degraded(let reason, _):
                return Status(path: url.path, state: .degraded(reason), diagnostics: nil)
            case .closed:
                return Status(path: url.path, state: .closed, diagnostics: nil)
        }
    }

    /// Closes the archive and ends the owner's open attempt if one is waiting, resuming every caller
    /// waiting for it with `MemoryUnavailable`. Definitive for this instance: every later operation
    /// answers the same, and nothing is written after this returns. Safe twice.
    public func close() async {
        let previous = lifecycle
        lifecycle = .closed
        switch previous {
            case .opening(let attempt, _) : attempt.cancel()
            case .ready(let repositories) : await repositories.store.close()
            default                       : break
        }
        resumeWaiters(.failure(Self.closedError))
    }

    private static let closedError = MemoryUnavailable("the memory is closed")

    /// The open repositories: opening on demand, waiting for an open in flight, opening again after a
    /// degraded interval.
    private func repositories() async throws -> Repositories {
        switch lifecycle {
            case .ready(let repositories):
                return repositories
            case .closed:
                throw Self.closedError
            case .degraded(let reason, let since):
                guard since.duration(to: .now) >= configuration.reopenInterval else { throw MemoryUnavailable(reason) }
                startOpening(forReading: false)
            case .notOpened:
                startOpening(forReading: false)
            case .opening:
                break
        }
        return try await awaitOpening(forReading: false)
    }

    /// Starts the one attempt: for a producer the directory, then the store's open that creates and
    /// bootstraps; for a reader the store's open of an existing archive alone. Cycle after cycle while
    /// the archive is busy, until it opens, the service closes or the open truly fails or refuses.
    private func startOpening(forReading: Bool) {
        let url = self.url, directory = self.directory, configuration = self.configuration.store
        let attempt = Task.detached { () throws -> Repositories in
            if !forReading { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            let store = SQLiteMemoryStore(url: url, configuration: configuration)
            while true {
                do {
                    try await store.open(forReading ? .existingArchive : .producer)
                    if !forReading { await FinalizationTrace.follow(store) }
                    return Repositories(store: store)
                } catch MemoryStoreError.contention {
                    // Another process holds the archive past one budget: another cycle, as a write does.
                    try Task.checkCancellation()
                } catch MemoryStoreError.cancelled {
                    throw CancellationError()
                }
            }
        }
        lifecycle = .opening(attempt, forReading: forReading)
        Task { [weak self] in
            let result = await attempt.result
            await self?.openingEnded(attempt, result)
        }
    }

    private func openingEnded(_ attempt: Task<Repositories, any Error>, _ result: Result<Repositories, any Error>) async {
        guard case .opening(let current, let forReading) = lifecycle, current == attempt else {
            // Closed while this one ran: a store it opened is let go of, and whoever still waits is told.
            if case .success(let repositories) = result { await repositories.store.close() }
            if case .closed = lifecycle { resumeWaiters(.failure(Self.closedError)) }
            return
        }
        switch result {
            case .success(let repositories):
                lifecycle = .ready(repositories)
                resumeWaiters(.success(repositories))
            case .failure(let error) where forReading:
                // A reader's open changed nothing: the service is as it was, and a producer that joined
                // the reader's attempt has its own open now.
                lifecycle = .notOpened
                resumeWaiters(.failure(error), readersOnly: true)
                if !waiters.isEmpty { startOpening(forReading: false) }
            case .failure(let error):
                let reason = "could not open: " + Self.describe(error)
                lifecycle = .degraded(reason: reason, since: .now)
                resumeWaiters(.failure(MemoryUnavailable(reason)))
        }
    }

    /// Waits for the attempt in flight, under this caller's own cancellation.
    private func awaitOpening(forReading: Bool) async throws -> Repositories {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Repositories, any Error>) in
                waiters[id] = Waiter(continuation: continuation, forReading: forReading)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    /// Resumes the waiting callers with `result`: all of them, or the readers alone.
    private func resumeWaiters(_ result: Result<Repositories, any Error>, readersOnly: Bool = false) {
        let pending = waiters.filter { !readersOnly || $0.value.forReading }
        for id in pending.keys { waiters.removeValue(forKey: id) }
        for waiter in pending.values { waiter.continuation.resume(with: result) }
    }

    /// Runs one operation on the open archive, cycle after cycle while its lock is busy, and degrades
    /// the service when the error says the archive can no longer be used.
    private func perform<T: Sendable>(_ body: @Sendable (Repositories) async throws -> T) async throws -> T {
        let repositories = try await repositories()
        while true {
            do {
                return try await body(repositories)
            } catch MemoryStoreError.contention {
                // A spent budget is waiting, not failure: the next cycle begins with the caller still here.
                try Task.checkCancellation()
            } catch {
                await degradeIfNeeded(error, repositories: repositories)
                throw error
            }
        }
    }

    /// Degrades the service when the archive can no longer be used, and only then: the store could not
    /// open or read its schema, it answers unavailable, or a failure inside a transaction left it
    /// `failed` because the transaction could not be ended. That last one is asked of the store after
    /// any other error (a constraint, a conflict the body raised, the library's failure), so the
    /// service says so after the operation that failed, not at the next one; the reason is the store's
    /// fault, the primary failure with its cleanup, and the caller still gets the primary error. An
    /// error whose transaction ended cleanly degrades nothing.
    private func degradeIfNeeded(_ error: any Error, repositories: Repositories) async {
        let reason: String
        switch error {
            case MemoryStoreError.open, MemoryStoreError.schema, MemoryStoreError.unavailable:
                reason = Self.describe(error)
            default:
                guard let fault = await Self.failure(of: repositories.store) else { return }
                reason = Self.describe(MemoryStoreError.unavailable(.failed(fault)))
        }
        guard case .ready = lifecycle else { return }
        lifecycle = .degraded(reason: reason, since: .now)
        await repositories.store.close()
    }

    /// The fault a store that let go of its connections answers with, or nil while it is usable.
    private static func failure(of store: SQLiteMemoryStore) async -> MemoryStoreFault? {
        do {
            _ = try await store.diagnostics()
            return nil
        } catch MemoryStoreError.unavailable(.failed(let fault)) {
            return fault
        } catch {
            return nil
        }
    }

    /// Runs `body` as the finalization of a fact that already exists: the sample was taken, the tool
    /// ran, so the caller's cancellation does not reach the body, and the body's wait is the ordinary
    /// one, cycle after cycle while the archive is busy, until the fact is written once, the service
    /// closes or the archive truly fails. The budget belongs to the owner, the
    /// `MemoryFinalizationScope.current` of the caller's task, read here before the body is detached
    /// (a caller with none is an owner of its own, this finalization alone). While the owner is not
    /// stopped nothing bounds the wait. Once it is (its `stop()`, said by its host, or the cancellation of
    /// a caller's task, whichever came first), the body may wait until the owner's stop plus
    /// `finalizationBudget` and is cut then, whether the caller's task is cancelled or still running
    /// (a call that finishes its action after a stop); a finalization offered after that deadline is
    /// an explicit gap at once (`CancellationError`) and its body never runs. A body already waiting
    /// when the owner stops is told by the owner. The error of a cut body (`cancelled`) is the caller's
    /// explicit gap, due to the stop, not to the wait. The caller's task owns the finalization: it
    /// awaits the body, the service keeps no list of them, and a finalization cut this way cancels no
    /// other owner's open or write. The body is ordinary service calls.
    public nonisolated func finalize<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let scope  = MemoryFinalizationScope.current ?? MemoryFinalizationScope()
        let budget = configuration.finalizationBudget
        // A cancelled caller stops its owner; the first instant, said or seen, stays the authority.
        if Task.isCancelled { scope.stop() }
        if let stopped = scope.stopInstant, stopped + budget <= .now {
            // The stopped owner's time is spent: a gap, with no new wait and nothing offered.
            FinalizationTrace.refused(scope)
            throw CancellationError()
        }
        // The opt-in trace's mark, nil while it is off; it follows the work and says nothing else.
        let mark  = FinalizationTrace.offered(scope)
        let work  = Task.detached { try await FinalizationTrace.run(mark) { try await body() } }
        let watch = FinalizationWatch(budget: budget) {
            FinalizationTrace.cut(mark)
            work.cancel()
        }
        // The owner arms the watch at its stop, or at once when it has stopped already.
        let enrolment = scope.enrol(watch)
        defer {
            watch.ended()
            scope.withdraw(enrolment)
        }
        return try await withTaskCancellationHandler {
            try await FinalizationTrace.ending(mark) { try await work.value }
        } onCancel: {
            // The caller's cancellation is a stop of its owner, if the owner had not stopped already.
            scope.stop()
        }
    }

    /// A test's seam, internal to this module (its tests reach it with `@testable`), never public: the
    /// open store's next rollback after a failure inside a transaction answers this library code
    /// instead of running (`SQLiteMemoryStore.refuseNextRollback`). It makes no failure of its own:
    /// the primary failure is a real one of the operation that follows. False when the archive is not
    /// open. Not a physical fault.
    func refuseNextRollbackOfTheStore(primary: Int32, extended: Int32, message: String) async -> Bool {
        guard case .ready(let repositories) = lifecycle else { return false }
        await repositories.store.refuseNextRollback(primary: primary, extended: extended, message: message)
        return true
    }

    /// A reason safe to show: the store's own taxonomy carries codes, phases and identifiers, never a
    /// value the agent typed or read; any other error is named by its type alone.
    nonisolated public static func describe(_ error: any Error) -> String {
        switch error {
            case let error as MemoryStoreError        : return "\(error)"
            case let error as MemoryUnavailable       : return error.description
            case let error as AgentCallError          : return "\(error)"
            case let error as BrainApplicationError   : return "\(error)"
            case let error as ObservationContractError: return "\(error)"
            case is CancellationError                 : return "cancelled"
            case let error as CocoaError              : return "file system error \(error.code.rawValue)"
            default                                   : return String(describing: type(of: error))
        }
    }

    /// Whether the error is the caller's cancellation, from the store or from the task.
    nonisolated public static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if case MemoryStoreError.cancelled = error { return true }
        return false
    }

    // MARK: BrainReading

    public func brain(of bundleID: String) async throws -> UIBrain? {
        try await perform { try await $0.brains.brain(of: bundleID) }
    }

    // MARK: BrainApplicationStoring

    public func apply(_ command: BrainApplicationCommand) async throws -> BrainApplicationResult {
        try await perform { try await $0.applications.apply(command) }
    }

    public func application(_ key: BrainApplicationKey) async throws -> BrainApplication? {
        try await perform { try await $0.applications.application(key) }
    }

    // MARK: CaptureStoring

    public func record(_ event: MemoryEventRecord) async throws -> MemoryReceipt {
        try await perform { try await $0.captures.record(event) }
    }

    public func record(_ sample: CaptureSample) async throws -> MemoryReceipt {
        try await perform { try await $0.captures.record(sample) }
    }

    public func event(_ eventID: String) async throws -> MemoryEventRecord? {
        try await perform { try await $0.captures.event(eventID) }
    }

    public func sample(_ key: CaptureSampleKey) async throws -> CaptureSample? {
        try await perform { try await $0.captures.sample(key) }
    }

    // MARK: SceneStoring

    public func scenes(of bundleID: String) async throws -> [SceneDefinition] {
        try await perform { try await $0.scenes.scenes(of: bundleID) }
    }

    public func associate(_ key: CaptureSampleKey, at nowMS: Int64) async throws -> SceneAssociationOutcome {
        try await perform { try await $0.scenes.associate(key, at: nowMS) }
    }

    public func associations(of key: CaptureSampleKey) async throws -> [SceneAssociation] {
        try await perform { try await $0.scenes.associations(of: key) }
    }

    // MARK: AgentCallStoring

    public func record(_ call: AgentCallRecord) async throws -> MemoryReceipt {
        try await perform { try await $0.calls.record(call) }
    }

    public func record(batch: AgentCallRecord, steps: [AgentCallRecord]) async throws -> MemoryReceipt {
        try await perform { try await $0.calls.record(batch: batch, steps: steps) }
    }

    public func advance(_ transitions: [AgentCallTransition]) async throws -> MemoryReceipt {
        try await perform { try await $0.calls.advance(transitions) }
    }

    public func call(_ eventID: String) async throws -> AgentCall? {
        try await perform { try await $0.calls.call(eventID) }
    }

    public func calls(inTrace traceID: String, after localOrder: Int64?, limit: Int) async throws -> [AgentCall] {
        try await perform { try await $0.calls.calls(inTrace: traceID, after: localOrder, limit: limit) }
    }

    public func steps(ofBatch eventID: String) async throws -> [AgentCall] {
        try await perform { try await $0.calls.steps(ofBatch: eventID) }
    }

    // MARK: MemoryTraceReading

    public func traces(before localOrder: Int64?, limit: Int) async throws -> [TraceSummary] {
        try await perform { try await $0.traces.traces(before: localOrder, limit: limit) }
    }

    public func entries(inTrace traceID: String, after localOrder: Int64?, limit: Int) async throws -> [TraceEntry] {
        try await perform { try await $0.traces.entries(inTrace: traceID, after: localOrder, limit: limit) }
    }

    public func observations(originatedBy eventID: String) async throws -> [MemoryEventRecord] {
        try await perform { try await $0.traces.observations(originatedBy: eventID) }
    }

    // MARK: The catalogue

    /// What the archive holds, per application and in total: counts only (`MemoryOverview`), read in
    /// one snapshot. Writes nothing.
    public func overview() async throws -> MemoryOverview {
        try await perform { try await $0.graph.overview() }
    }

    /// Whether the archive's file is there now, without opening it: a diagnosis asks before it opens,
    /// so a missing archive is said as missing and never created to be shown as an empty one.
    public nonisolated var archiveExists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

/// MemoryFinalizationScope is one owner of finalizations, for the memory's budget after a stop: a turn
/// of an agent (`AgentTurnHost` makes one per turn), a tool call outside a turn (`AutomationTools.call`
/// makes one when the host gave none), one invocation of a vertical command (`mecum`'s entry). Its
/// finalizations share the service's `finalizationBudget` from the owner's stop, on the monotonic clock.
/// The owner says when it stopped (`stop()`), or the first of its finalizations whose caller is
/// cancelled says it; the first instant is kept, so later stops and later finalizations never start a
/// new budget. The stop reaches the finalizations waiting at that instant (enrolled with the owner) and
/// every one offered after it, whether or not their callers' tasks are cancelled: a call left to finish
/// its action after a stop is still bounded in what it writes. Nothing here is persisted, and nothing
/// here changes what is written or how facts are compared.
///
/// It reaches the finalizations as `current`, a task-local value bound by the owner around the work
/// that may finalize (`withValue`); `MemoryService.finalize` reads it in the caller's task before it
/// detaches the body, so the detached body needs no task-local. An unstructured `Task` made under the
/// binding inherits it; a detached one does not.
nonisolated public final class MemoryFinalizationScope: Sendable {

    @TaskLocal public static var current: MemoryFinalizationScope?

    /// The owner's state under one lock: the stop once said, and the finalizations waiting for it.
    private struct State {
        var stoppedAt: ContinuousClock.Instant?
        var waiting: [UUID: FinalizationWatch] = [:]
    }

    private let state = Mutex(State())

    /// This owner's number in the opt-in `FinalizationTrace`, nil while the trace is off.
    let traceNumber = FinalizationTrace.numberOwner()

    public init() {}

    /// The owner stopped at `instant`: kept once, a later stop moves nothing. The finalizations waiting
    /// now are told, after the lock is let go, so none of them is called back under it.
    public func stop(at instant: ContinuousClock.Instant = .now) {
        let told: [FinalizationWatch]? = state.withLock { state in
            guard state.stoppedAt == nil else { return nil }
            state.stoppedAt = instant
            return Array(state.waiting.values)
        }
        guard let told else { return }
        FinalizationTrace.stopped(self, waiting: told.count)
        for watch in told { watch.ownerStopped(at: instant) }
    }

    /// When the owner stopped, nil while it has not.
    public var stopInstant: ContinuousClock.Instant? { state.withLock { $0.stoppedAt } }

    /// The owner's deadline for `budget`: its stop plus the budget, the stop being `instant` when none was
    /// said yet. The rule on its own: `stop` once, `stop + budget` for every finalization after it.
    public func deadline(budget: Duration, stoppingAt instant: ContinuousClock.Instant) -> ContinuousClock.Instant {
        stop(at: instant)
        return (stopInstant ?? instant) + budget
    }

    /// How many finalizations are waiting on this owner now: zero once each has ended. Internal, for
    /// the module's tests.
    var waitingFinalizations: Int { state.withLock { $0.waiting.count } }

    /// Enrols a finalization: it is told of the stop when it comes, or now, outside the lock, when the
    /// owner has stopped already. The answer is what `withdraw` takes back.
    fileprivate func enrol(_ watch: FinalizationWatch) -> UUID {
        let id = UUID()
        let stopped: ContinuousClock.Instant? = state.withLock { state in
            if let stopped = state.stoppedAt { return stopped }
            state.waiting[id] = watch
            return nil
        }
        if let stopped { watch.ownerStopped(at: stopped) }
        return id
    }

    /// Takes a finalization back once it has ended, written or not.
    fileprivate func withdraw(_ id: UUID) {
        _ = state.withLock { $0.waiting.removeValue(forKey: id) }
    }
}

/// FinalizationWatch is the budget of one finalization within its owner's: nothing while the owner
/// works, a watchdog from the owner's stop until the owner's deadline, which cuts the detached work then,
/// and nothing once the work has ended. The two events may come in any order and from any thread.
nonisolated private final class FinalizationWatch: Sendable {

    private enum State {
        case waiting
        case watching(Task<Void, Never>)
        case ended
    }

    private let state = Mutex(State.waiting)
    private let budget: Duration
    private let cut: @Sendable () -> Void

    init(budget: Duration, cut: @escaping @Sendable () -> Void) {
        self.budget = budget
        self.cut    = cut
    }

    /// The owner stopped at `instant`: the watchdog waits until `instant + budget`, once, then cuts.
    func ownerStopped(at instant: ContinuousClock.Instant) {
        let deadline = instant + budget, cut = self.cut
        state.withLock { current in
            guard case .waiting = current else { return }
            current = .watching(Task.detached {
                do {
                    try await Task.sleep(until: deadline, clock: .continuous)
                    cut()
                } catch {
                    // Let go of when the work ended first: nothing to cut.
                }
            })
        }
    }

    /// The work ended, written or not: a watchdog still sleeping is let go of.
    func ended() {
        let previous = state.withLock { current in
            let previous = current
            current = .ended
            return previous
        }
        if case .watching(let watchdog) = previous { watchdog.cancel() }
    }
}
