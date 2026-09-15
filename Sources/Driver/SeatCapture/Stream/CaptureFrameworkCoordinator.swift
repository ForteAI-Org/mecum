//
//  CaptureFrameworkCoordinator.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import Foundation

nonisolated enum CaptureFrameworkCallClass: Sendable, Equatable {
    case ordinary
    case cleanup
}

/// CaptureFrameworkCoordinator bounds Apple calls and their waiters across all
/// stream instances and static capture calls.
///
/// `@unchecked Sendable` is the lock invariant: every job, waiter and counter
/// is read and mutated under `lock`. Launches and continuation resumes are
/// copied out and invoked only after unlocking. A framework slot leaves the
/// pending count only in `complete`, called by the real Apple callback, never
/// by a caller deadline or cancellation.
nonisolated final class CaptureFrameworkCoordinator: @unchecked Sendable {

    static let shared = CaptureFrameworkCoordinator()

    private static let maximumPendingCalls         = 4
    private static let maximumOrdinaryPendingCalls = 3
    private static let maximumQueuedJobs           = 16
    private static let maximumOrdinaryQueuedJobs   = 15
    private static let maximumWaiters               = 64
    private static let maximumOrdinaryWaiters       = 63

    private struct OpaqueValue: @unchecked Sendable {
        let value: Any
    }

    private typealias Resolution = @Sendable (Result<OpaqueValue, any Error>) -> Void
    private typealias Completion = @Sendable (Result<OpaqueValue, CaptureFailure>) -> Void
    private typealias Launch = @Sendable (@escaping Completion) -> Void
    private typealias Discard = @Sendable (Result<OpaqueValue, CaptureFailure>) -> Void

    private enum JobState {
        case queued
        case admitted
        case running(startedAt: UInt64)
        case retired(startedAt: UInt64, isLate: Bool)
    }

    private struct Waiter {
        let deadline: UInt64
        let resolve : Resolution
    }

    private struct Job {
        let id        : UInt64
        let key       : CaptureCompatibilityKey?
        let step      : CaptureStep
        let callClass : CaptureFrameworkCallClass
        let createdAt : UInt64
        let deadline  : UInt64
        let launch    : Launch
        let onDiscard : Discard?
        var state     : JobState
        var waiters   : [UInt64: Waiter]
    }

    private final class WaiterCancellation: @unchecked Sendable {

        private let lock = NSLock()
        private var isCancelled = false
        private var action: (@Sendable () -> Void)?

        func install(_ action: @escaping @Sendable () -> Void) {
            lock.lock()
            if isCancelled {
                lock.unlock()
                action()
                return
            }
            self.action = action
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            guard !isCancelled else {
                lock.unlock()
                return
            }
            isCancelled = true
            let action = action
            self.action = nil
            lock.unlock()
            action?()
        }
    }

    private let lock = NSLock()
    private let timerQueue = DispatchQueue(
        label: "dev.forte.AgentSeatKit.capture.deadlines",
        qos  : .userInitiated
    )
    private let timer: any DispatchSourceTimer

    private var nextJobID    : UInt64 = 0
    private var nextWaiterID : UInt64 = 0
    private var jobs         : [UInt64: Job] = [:]
    private var currentJobs  : [CaptureCompatibilityKey: UInt64] = [:]
    private var queuedJobIDs : [UInt64] = []

    private var pendingCalls         = 0
    private var pendingOrdinaryCalls = 0
    private var reservedCalls         = 0
    private var reservedOrdinaryCalls = 0
    private var ordinaryWaiterCount   = 0
    private var peakPendingCalls     = 0
    private var waiterCount          = 0
    private var peakWaiterCount      = 0
    private var rejectedCount        : UInt64 = 0
    private var coalescedCount       : UInt64 = 0
    private var timeoutCount         : UInt64 = 0
    private var cancellationCount    : UInt64 = 0
    private var lateCount            : UInt64 = 0
    private var discardedCount       : UInt64 = 0
    private var admittedCount        : UInt64 = 0
    private var completedCount       : UInt64 = 0
    private var admissionWait        : UInt64 = 0
    private var frameworkExecution   : UInt64 = 0

    init() {
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        self.timer = timer
        timer.setEventHandler { [weak self] in self?.deadlineTimerFired() }
        timer.schedule(deadline: .distantFuture)
        timer.activate()
    }

    deinit {
        timer.cancel()
    }

    var metrics: CaptureRequestMetrics {
        withLock {
            CaptureRequestMetrics(
                pendingFrameworkCalls       : pendingCalls,
                peakPendingFrameworkCalls   : peakPendingCalls,
                queuedFrameworkCalls        : queuedJobIDs.count,
                retainedWaiters             : waiterCount,
                peakRetainedWaiters         : peakWaiterCount,
                rejectedRequests            : rejectedCount,
                coalescedRequests           : coalescedCount,
                timedOutRequests            : timeoutCount,
                cancelledRequests           : cancellationCount,
                lateResults                 : lateCount,
                discardedResults            : discardedCount,
                admittedFrameworkCalls      : admittedCount,
                completedFrameworkCalls     : completedCount,
                cumulativeAdmissionWait     : .captureNanoseconds(clamping: admissionWait),
                completedFrameworkExecution : .captureNanoseconds(clamping: frameworkExecution)
            )
        }
    }

    func isAcceptingWaiters(for key: CaptureCompatibilityKey) -> Bool {
        withLock {
            let now = DispatchTime.now().uptimeNanoseconds
            guard let jobID = currentJobs[key], let job = jobs[jobID] else { return false }
            return job.deadline > now
        }
    }

    func value<Value: Sendable>(
        key        : CaptureCompatibilityKey?,
        step       : CaptureStep,
        callClass  : CaptureFrameworkCallClass = .ordinary,
        allowsQueue: Bool = true,
        deadline   : CaptureDeadline,
        operation  : @escaping @Sendable (
            @escaping @Sendable (Result<Value, CaptureFailure>) -> Void
        ) -> Void,
        onDiscard  : (@Sendable (Result<Value, CaptureFailure>) -> Void)? = nil
    ) async throws -> Value {

        if Task.isCancelled {
            recordUnregisteredCancellation()
            throw CancellationError()
        }
        try checkDeadline(deadline, step: step)
        let cancellation = WaiterCancellation()

        let handoff: Handoff<Value> = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Handoff<Value>, any Error>) in
                let gate = ContinuationGate<Value>(continuation)
                let resolveAdapter: Resolution = { result in
                    switch result {
                    case .success(let opaque):
                        guard let value = opaque.value as? Value else {
                            gate.resolve(.failure(CaptureFailure.frameUnavailable))
                            return
                        }
                        gate.resolve(.success(value))
                    case .failure(let error):
                        gate.resolve(.failure(error))
                    }
                }
                let launchAdapter: Launch = { completion in
                    operation { result in
                        switch result {
                        case .success(let value):
                            completion(.success(OpaqueValue(value: value)))
                        case .failure(let failure):
                            completion(.failure(failure))
                        }
                    }
                }
                let discardAdapter: Discard?
                if let onDiscard {
                    discardAdapter = { result in
                        switch result {
                        case .success(let opaque):
                            guard let value = opaque.value as? Value else {
                                onDiscard(.failure(.frameUnavailable))
                                return
                            }
                            onDiscard(.success(value))
                        case .failure(let failure):
                            onDiscard(.failure(failure))
                        }
                    }
                } else {
                    discardAdapter = nil
                }
                let registration = register(
                    key        : key,
                    step       : step,
                    callClass  : callClass,
                    allowsQueue: allowsQueue,
                    deadline   : deadline,
                    resolve    : resolveAdapter,
                    launch     : launchAdapter,
                    onDiscard  : discardAdapter
                )
                cancellation.install { [weak self] in
                    self?.cancel(
                        waiterID: registration.waiterID,
                        jobID   : registration.jobID
                    )
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        if Task.isCancelled {
            recordUnregisteredCancellation()
            throw CancellationError()
        }
        try checkDeadline(deadline, step: step)
        return handoff.value
    }

    private struct Registration {
        let waiterID: UInt64
        let jobID   : UInt64
    }

    private func register(
        key        : CaptureCompatibilityKey?,
        step       : CaptureStep,
        callClass  : CaptureFrameworkCallClass,
        allowsQueue: Bool,
        deadline   : CaptureDeadline,
        resolve    : @escaping Resolution,
        launch     : @escaping Launch,
        onDiscard  : Discard?
    ) -> Registration {

        let now = DispatchTime.now().uptimeNanoseconds
        var launchAction: (UInt64, Launch)?
        var immediate: (Resolution, Result<OpaqueValue, any Error>)?
        var registration = Registration(waiterID: 0, jobID: 0)

        lock.lock()
        nextWaiterID &+= 1
        let waiterID = nextWaiterID

        guard deadline.expiresAt > now else {
            timeoutCount &+= 1
            immediate = (resolve, .failure(CaptureFailure.timedOut(step)))
            registration = Registration(waiterID: waiterID, jobID: 0)
            lock.unlock()
            if let immediate { immediate.0(immediate.1) }
            return registration
        }

        let hasWaiterCapacity = waiterCount < Self.maximumWaiters
            && (callClass == .cleanup || ordinaryWaiterCount < Self.maximumOrdinaryWaiters)
        guard hasWaiterCapacity else {
            rejectedCount &+= 1
            immediate = (resolve, .failure(CaptureFailure.frameworkCallLimitReached(step)))
            registration = Registration(waiterID: waiterID, jobID: 0)
            lock.unlock()
            if let immediate { immediate.0(immediate.1) }
            return registration
        }

        let jobID: UInt64
        if let key,
           let existingID = currentJobs[key],
           let existing = jobs[existingID],
           existing.deadline > now {
            jobID = existingID
            coalescedCount &+= 1
        } else {
            let canStart = canAdmit(callClass)
            let ordinaryQueued = queuedJobIDs.reduce(into: 0) { count, queuedID in
                if jobs[queuedID]?.callClass == .ordinary { count += 1 }
            }
            let hasQueueCapacity = queuedJobIDs.count < Self.maximumQueuedJobs
                && (callClass == .cleanup || ordinaryQueued < Self.maximumOrdinaryQueuedJobs)
            guard canStart || (allowsQueue && hasQueueCapacity) else {
                rejectedCount &+= 1
                immediate = (resolve, .failure(CaptureFailure.frameworkCallLimitReached(step)))
                registration = Registration(waiterID: waiterID, jobID: 0)
                lock.unlock()
                if let immediate { immediate.0(immediate.1) }
                return registration
            }

            nextJobID &+= 1
            jobID = nextJobID
            jobs[jobID] = Job(
                id        : jobID,
                key       : key,
                step      : step,
                callClass : callClass,
                createdAt : now,
                deadline  : deadline.expiresAt,
                launch    : launch,
                onDiscard : onDiscard,
                state     : .queued,
                waiters   : [:]
            )
            if let key { currentJobs[key] = jobID }

            if canStart {
                launchAction = admit(jobID: jobID, at: now)
            } else {
                queuedJobIDs.append(jobID)
            }
        }

        let waiterDeadline = min(deadline.expiresAt, jobs[jobID]?.deadline ?? deadline.expiresAt)
        jobs[jobID]?.waiters[waiterID] = Waiter(deadline: waiterDeadline, resolve: resolve)
        waiterCount += 1
        if callClass == .ordinary { ordinaryWaiterCount += 1 }
        peakWaiterCount = max(peakWaiterCount, waiterCount)
        registration = Registration(waiterID: waiterID, jobID: jobID)
        scheduleNextDeadlineLocked()
        lock.unlock()

        if let launchAction { beginLaunch(jobID: launchAction.0, launch: launchAction.1) }
        return registration
    }

    private func beginLaunch(jobID: UInt64, launch: Launch) {
        let now = DispatchTime.now().uptimeNanoseconds
        var resolutions: [(Resolution, CaptureStep)] = []
        var followingLaunches: [(UInt64, Launch)] = []

        lock.lock()
        guard var job = jobs[jobID], case .admitted = job.state else {
            lock.unlock()
            return
        }

        reservedCalls -= 1
        if job.callClass == .ordinary { reservedOrdinaryCalls -= 1 }
        guard job.deadline > now, !job.waiters.isEmpty else {
            for waiter in job.waiters.values {
                waiterCount -= 1
                if job.callClass == .ordinary { ordinaryWaiterCount -= 1 }
                timeoutCount &+= 1
                resolutions.append((waiter.resolve, job.step))
            }
            jobs.removeValue(forKey: jobID)
            if let key = job.key, currentJobs[key] == jobID { currentJobs.removeValue(forKey: key) }
            followingLaunches = drainQueue(at: now)
            scheduleNextDeadlineLocked()
            lock.unlock()
            for resolution in resolutions {
                resolution.0(.failure(CaptureFailure.timedOut(resolution.1)))
            }
            for following in followingLaunches {
                beginLaunch(jobID: following.0, launch: following.1)
            }
            return
        }

        job.state = .running(startedAt: now)
        jobs[jobID] = job
        pendingCalls += 1
        if job.callClass == .ordinary { pendingOrdinaryCalls += 1 }
        peakPendingCalls = max(peakPendingCalls, pendingCalls)
        admittedCount &+= 1
        admissionWait &+= now >= job.createdAt ? now - job.createdAt : 0
        lock.unlock()

        launch { [weak self] result in self?.complete(jobID: jobID, result: result) }
    }

    private func complete(jobID: UInt64, result: Result<OpaqueValue, CaptureFailure>) {
        let now = DispatchTime.now().uptimeNanoseconds
        var resolutions: [(Resolution, Result<OpaqueValue, any Error>)] = []
        var discard: Discard?
        var launches: [(UInt64, Launch)] = []

        lock.lock()
        guard let job = jobs.removeValue(forKey: jobID) else {
            lock.unlock()
            return
        }
        if let key = job.key, currentJobs[key] == jobID { currentJobs.removeValue(forKey: key) }

        let startedAt: UInt64
        let jobIsLate: Bool
        switch job.state {
        case .queued, .admitted:
            lock.unlock()
            return
        case .running(let start):
            startedAt = start
            jobIsLate = now >= job.deadline
        case .retired(let start, let retiredLate):
            startedAt = start
            jobIsLate = retiredLate || now >= job.deadline
        }

        pendingCalls -= 1
        if job.callClass == .ordinary { pendingOrdinaryCalls -= 1 }
        completedCount &+= 1
        frameworkExecution &+= now >= startedAt ? now - startedAt : 0

        var deliveredCount = 0
        for waiter in job.waiters.values {
            waiterCount -= 1
            if job.callClass == .ordinary { ordinaryWaiterCount -= 1 }
            if waiter.deadline <= now {
                timeoutCount &+= 1
                resolutions.append((waiter.resolve, .failure(CaptureFailure.timedOut(job.step))))
            } else {
                deliveredCount += 1
                resolutions.append((waiter.resolve, result.mapError { $0 as any Error }))
            }
        }

        if jobIsLate {
            lateCount &+= 1
        }
        if jobIsLate || deliveredCount == 0 {
            discardedCount &+= 1
            discard = job.onDiscard
        }

        launches = drainQueue(at: now)
        scheduleNextDeadlineLocked()
        lock.unlock()

        for resolution in resolutions { resolution.0(resolution.1) }
        if let discard { discard(result) }
        for launch in launches { beginLaunch(jobID: launch.0, launch: launch.1) }
    }

    private func deadlineTimerFired() {
        let now = DispatchTime.now().uptimeNanoseconds
        var resolutions: [(Resolution, CaptureStep)] = []
        var launches: [(UInt64, Launch)] = []

        lock.lock()
        for jobID in Array(jobs.keys) {
            guard var job = jobs[jobID] else { continue }
            let expiredWaiterIDs = job.waiters.compactMap { waiterID, waiter in
                waiter.deadline <= now ? waiterID : nil
            }
            for waiterID in expiredWaiterIDs {
                guard let waiter = job.waiters.removeValue(forKey: waiterID) else { continue }
                waiterCount -= 1
                if job.callClass == .ordinary { ordinaryWaiterCount -= 1 }
                timeoutCount &+= 1
                resolutions.append((waiter.resolve, job.step))
            }

            let jobExpired = job.deadline <= now
            if jobExpired {
                for waiter in job.waiters.values {
                    waiterCount -= 1
                    if job.callClass == .ordinary { ordinaryWaiterCount -= 1 }
                    timeoutCount &+= 1
                    resolutions.append((waiter.resolve, job.step))
                }
                job.waiters.removeAll()
            }

            if job.waiters.isEmpty {
                retireOrRemove(
                    job   : job,
                    isLate: jobExpired || !expiredWaiterIDs.isEmpty
                )
            } else {
                jobs[jobID] = job
            }
        }
        launches = drainQueue(at: now)
        scheduleNextDeadlineLocked()
        lock.unlock()

        for resolution in resolutions {
            resolution.0(.failure(CaptureFailure.timedOut(resolution.1)))
        }
        for launch in launches { beginLaunch(jobID: launch.0, launch: launch.1) }
    }

    private func cancel(waiterID: UInt64, jobID: UInt64) {
        guard jobID != 0 else { return }
        var resolution: Resolution?
        var launches: [(UInt64, Launch)] = []

        lock.lock()
        if var job = jobs[jobID], let waiter = job.waiters.removeValue(forKey: waiterID) {
            waiterCount -= 1
            if job.callClass == .ordinary { ordinaryWaiterCount -= 1 }
            cancellationCount &+= 1
            resolution = waiter.resolve
            if job.waiters.isEmpty {
                retireOrRemove(job: job, isLate: false)
            } else {
                jobs[jobID] = job
            }
            launches = drainQueue(at: DispatchTime.now().uptimeNanoseconds)
            scheduleNextDeadlineLocked()
        }
        lock.unlock()

        resolution?(.failure(CancellationError()))
        for launch in launches { beginLaunch(jobID: launch.0, launch: launch.1) }
    }

    private func retireOrRemove(job: Job, isLate: Bool) {
        if let key = job.key, currentJobs[key] == job.id { currentJobs.removeValue(forKey: key) }
        switch job.state {
        case .queued:
            jobs.removeValue(forKey: job.id)
            queuedJobIDs.removeAll { $0 == job.id }
        case .admitted:
            reservedCalls -= 1
            if job.callClass == .ordinary { reservedOrdinaryCalls -= 1 }
            jobs.removeValue(forKey: job.id)
        case .running(let startedAt):
            var retired = job
            retired.state = .retired(startedAt: startedAt, isLate: isLate)
            retired.waiters.removeAll()
            jobs[job.id] = retired
        case .retired(let startedAt, let wasLate):
            var retired = job
            retired.state = .retired(startedAt: startedAt, isLate: wasLate || isLate)
            retired.waiters.removeAll()
            jobs[job.id] = retired
        }
    }

    private func canAdmit(_ callClass: CaptureFrameworkCallClass) -> Bool {
        let occupiedCalls = pendingCalls + reservedCalls
        guard occupiedCalls < Self.maximumPendingCalls else { return false }
        switch callClass {
        case .ordinary:
            return pendingOrdinaryCalls + reservedOrdinaryCalls < Self.maximumOrdinaryPendingCalls
        case .cleanup:
            return true
        }
    }

    private func admit(jobID: UInt64, at now: UInt64) -> (UInt64, Launch)? {
        guard var job = jobs[jobID], canAdmit(job.callClass) else { return nil }
        queuedJobIDs.removeAll { $0 == jobID }
        job.state = .admitted
        jobs[jobID] = job
        reservedCalls += 1
        if job.callClass == .ordinary { reservedOrdinaryCalls += 1 }
        return (jobID, job.launch)
    }

    private func drainQueue(at now: UInt64) -> [(UInt64, Launch)] {
        var launches: [(UInt64, Launch)] = []
        let ordered = queuedJobIDs.sorted { first, second in
            guard let firstJob = jobs[first], let secondJob = jobs[second] else { return first < second }
            if firstJob.callClass != secondJob.callClass { return firstJob.callClass == .cleanup }
            return firstJob.createdAt < secondJob.createdAt
        }
        for jobID in ordered {
            guard let job = jobs[jobID], job.deadline > now else { continue }
            if let launch = admit(jobID: jobID, at: now) { launches.append(launch) }
        }
        return launches
    }

    private func scheduleNextDeadlineLocked() {
        let deadlines = jobs.values.flatMap { job -> [UInt64] in
            var values = job.waiters.values.map(\.deadline)
            switch job.state {
            case .queued, .admitted, .running:
                values.append(job.deadline)
            case .retired:
                break
            }
            return values
        }
        guard let next = deadlines.min() else {
            timer.schedule(deadline: .distantFuture)
            return
        }
        timer.schedule(deadline: DispatchTime(uptimeNanoseconds: next), leeway: .milliseconds(1))
    }

    private func withLock<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func recordUnregisteredCancellation() {
        withLock { cancellationCount &+= 1 }
    }

    private func checkDeadline(_ deadline: CaptureDeadline, step: CaptureStep) throws {
        do {
            try deadline.check(step)
        } catch {
            withLock { timeoutCount &+= 1 }
            throw error
        }
    }
}
