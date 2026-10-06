//
//  SeatHost.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import AppKit
import CoreGraphics
import CursorGuard
import Darwin
import Foundation
import os
import PrivateSymbols
import SeatCapture
import SeatCore
import SeatInput
import VirtualScreens

/// SeatHost owns one Virtual Display and the shared Cursor Fence, and creates
/// Agent Seats on them.
///
/// ## The atomic step
///
/// `start` brings the display and the fence up together, and if either fails it
/// takes the other back down. A display with no fence is the one configuration
/// this kit must never be in: the person's cursor could walk onto a screen they
/// cannot see, and every seat invariant is written on the assumption that it
/// cannot.
///
/// ## The fence is alive only while somebody holds it
///
/// The fence is reference counted in the process: the first acquisition
/// installs the tap and the last release removes it. This host holds it for as
/// long as it is running, so while the host is up the person's cursor is
/// confined. Outside that window, **with the virtual display still present, the
/// cursor can enter it**. That is the contract and not a defect: a tap at the
/// head of the HID stream is not something a library leaves installed after the
/// work is over, and a consumer that wants confinement outside an operation
/// holds the fence itself.
///
/// ## Who turns the event loop
///
/// A virtual display makes progress only while `NSApplication` pumps events
/// (ADR 0007), so `VirtualDisplay` has no wait inside it and this host has the
/// waits instead. The waits are `async`, which works when the caller has a live
/// application event loop; a caller that cannot pump gets `pumpTimedOut` with a
/// name on it rather than a display that never appears.
public final class SeatHost {

    private static let log = Logger(subsystem: "dev.forte.AgentSeatKit", category: "Session")

    /// Where the host is.
    public private(set) var state: SeatHostState = .off

    /// The single channel out of the host: its own transitions, the Issues the
    /// watchdog finds with the invariant that broke, the fence's latched
    /// batches, the Monitor's quality changes and the teardown's outcome.
    public let events: AsyncStream<SeatEvent>

    /// The live preview of the virtual display, for the person. It exists from
    /// `start` and is nil before it.
    public private(set) var monitor: Monitor?

    /// The virtual display's id while the host is up.
    public var displayID: CGDirectDisplayID? { display?.displayID }

    /// The seat this host created, nil until `makeSeat`.
    public private(set) var seat: AgentSeat?

    /// The shared Cursor Fence, while the host holds it.
    ///
    /// It is public because the fence's own state is a fact a consumer shows to
    /// a person, and because an anchor or an
    /// audit around a Command the consumer builds itself needs the same fence
    /// the seat uses. Reading it is safe; releasing it out from under the host
    /// is not, so the reference is read only.
    public var fence: CursorFence? { installedFence }

    /// The readings the session layer takes of the running system, for a
    /// consumer that wants its own `SeatObserver` over an interval the kit does
    /// not know about.
    public var sensing: (any SeatSensing)? { systemSensing }

    public let configuration: SeatHostConfiguration

    private let eventChannel: AsyncStream<SeatEvent>.Continuation

    private var display        : VirtualDisplay?
    private var installedFence : CursorFence?
    private var driver         : InputDriver?
    private var systemSensing  : SystemSeatSensing?

    private var watchdogTask        : Task<Void, Never>?
    private var monitorLifecycleTask: Task<Void, Never>?
    private var reconfiguration     : DisplayReconfigurationWatch?
    private var retainedMonitor     : Monitor?

    private var isTearingDown = false
    private var lastTeardown  : TeardownReport?

    /// True while the fail-closed path is running, which is what keeps a
    /// watchdog beat, a caller's `stop` and a display callback from starting
    /// three teardowns of the same display.
    private var isFailingClosed = false

    /// Bumped on every `start`. It travels on every `SeatFrame` so a consumer
    /// can tell a frame of this display from a frame of the previous one with
    /// the same id, which the window server does reuse. The counter belongs to
    /// whoever owns the display, so a consumer never has to keep its own.
    private var displayGeneration: UInt64 = 0

    /// The idle CPU the process costs with no Monitor running, which is what
    /// makes the Monitor's share attributable.
    private var idleCpuBaseline: Double?
    private var lastUsage      : (userSeconds: Double, systemSeconds: Double, at: UInt64)?

    public init(configuration: SeatHostConfiguration = .default) {
        self.configuration = configuration

        var channel: AsyncStream<SeatEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(128)) { channel = $0 }
        self.eventChannel = channel
    }

    // MARK: Start and stop

    /// start brings up the virtual display and the fence as one step.
    ///
    /// The order is the measured one: create the display, wait for AppKit to
    /// publish an `NSScreen`, attach and verify the topology, wait for the
    /// refreshed screen, check that nothing of the person's moved, then install
    /// the fence and prove it is confining before anything else happens. There
    /// is no settle in the middle: a benchmark verified the topology immediately
    /// and again 300 ms later across forty cycles and the two readings never
    /// disagreed, so the 300 ms wait came out and the setup went from 646 ms to
    /// about 350.
    ///
    /// The Monitor is the one part that is allowed to fail without failing the
    /// start: the person loses the preview, the seat works, and the host says
    /// `degraded` with `monitorUnavailable`.
    ///
    /// A start waits for a fail-closed teardown to finish first. `failClosed`
    /// leaves the host `failed` and schedules its own `stop`, so without the
    /// wait a restart could run before that `stop` and be torn down by it, or
    /// run beside a teardown that outlived the five seconds `stop` waits.
    public func start() async throws {

        guard await EventLoopWait.until(
            { !self.isFailingClosed && !self.isTearingDown },
            timeout: .seconds(5)
        ) else {
            throw SessionFailure.hostNotReady(state)
        }

        guard state == .off || state == .failed else {
            throw SessionFailure.hostNotReady(state)
        }

        transition(to: .starting, reason: .requested)
        EventLoopWait.installPump(configuration.eventLoopPump)
        await retryRetainedMonitorStop()

        do {
            let created = try VirtualDisplay.create(configuration.display)
            display = created

            guard await EventLoopWait.until(
                { created.appKitScreen != nil },
                timeout: configuration.pumpTimeout
            ) else {
                throw SessionFailure.pumpTimedOut(
                    seconds: Double(configuration.pumpTimeout.components.seconds)
                )
            }

            try created.configureTopology()
            try created.verifyTopology()

            // AppKit republishes the screen after the topology transaction, and
            // the frame it publishes before it is the one at the requested
            // origin rather than the attached one.
            _ = await EventLoopWait.until(
                { created.appKitScreen != nil },
                timeout: .seconds(2)
            )

            guard created.physicalOverlapArea < 0.5 else {
                throw SeatInterruption(issues: [.displayChanged])
            }
            guard created.maximumPhysicalPortalLength <= 1.5 else {
                throw SeatInterruption(issues: [.displayChanged])
            }

            let installed = try CursorFence.acquire(
                displayBounds: created.topology.physicalDisplays.map(\.currentBounds)
            )
            installedFence = installed

            let snapshot = installed.snapshot()
            guard snapshot.isActive, snapshot.disableCount == 0 else {
                throw SeatInterruption(issues: [.fenceUnavailable])
            }
            guard let cursor = CGEvent(source: nil)?.location,
                  installed.containsPhysicalPoint(cursor),
                  !created.quartzBounds.contains(cursor)
            else {
                throw SeatInterruption(issues: [.cursorInterference])
            }

            self.systemSensing = SystemSeatSensing(display: created, fence: installed)
            self.driver        = try InputDriver()

            displayGeneration &+= 1

            startWatchdog(expectedMainDisplayID: created.topology.mainDisplayID)
            transition(to: .ready, reason: .requested)

            // The Monitor exists only when a preview was asked for. It is not
            // frugality: a `Monitor` built and never started is a capture
            // stream nobody configured, and tearing that down again segfaults
            // in `objc_release` on the next display of the process.
            if let monitorConfiguration = configuration.monitor {
                if retainedMonitor != nil {
                    raiseHostIssue(.monitorUnavailable)
                    Self.log.error("""
                        monitor unavailable: a previous capture stop remains unconfirmed
                        """)
                } else {
                    let preview = Monitor(
                        displayID        : created.displayID,
                        displayGeneration: displayGeneration
                    )
                    monitor = preview
                    do {
                        try await preview.start(configuration: monitorConfiguration)
                        observeMonitorLifecycle(preview)
                    } catch {
                        raiseHostIssue(.monitorUnavailable)
                        Self.log.error("""
                            monitor unavailable: \(String(describing: error), privacy: .public)
                            """)
                    }
                }
            }

        } catch {
            // The atomic half of the contract: whatever came up goes back down,
            // and the caller gets the reason rather than a half started host.
            await dismantle()
            transition(to: .failed, reason: .cancelled)
            throw error
        }
    }

    /// makeSeat hands out the seat. v1 is one seat per host and one host per
    /// process, and the second call is `seatLimitReached`: the model admits
    /// `n` and this is the only line that has to change for it.
    public func makeSeat() throws -> AgentSeat {

        guard state.canAdopt else { throw SessionFailure.hostNotReady(state) }
        guard seat == nil else { throw SessionFailure.seatLimitReached }

        guard let display, let systemSensing, let driver else {
            throw SessionFailure.hostNotReady(state)
        }

        // The observation source is the shipped adapter over the capture module.
        // It supports a window Still and a content clock tied to the documented
        // WindowServer Mach timestamp. The menu surface remains unqualified.
        let created = AgentSeat(
            sensing              : systemSensing,
            placing              : SystemWindowPlacing(),
            sender               : driver,
            fence                : installedFence,
            displayID            : display.displayID,
            expectedMainDisplayID: display.topology.mainDisplayID,
            defaultPlatform      : configuration.platform,
            observationSource    : SeatCaptureObservationSource(
                displayGeneration: displayGeneration
            ),
            contentClock         : MachAbsoluteContentClock(),
            observationProfile   : configuration.observationProfile
        )

        created.hiddenReturns               = .shared
        created.transfersFullScreenWindows  = configuration.transfersFullScreenWindows
        created.restoresFullScreenOnRelease = configuration.restoresFullScreenOnRelease
        created.reportMonitorHealth(currentMonitorHealth)

        if configuration.followsNewWindows { created.enableWindowFollowing() }

        if configuration.restoresUserFocus {
            try created.enableFocusRecovery(driver: driver,
                allowUnvalidatedBuild: configuration.allowUnvalidatedFocusRecovery,
                usesKeyRecords: configuration.focusRecoveryUsesKeyRecords)
        }
        seat = created
        return created
    }

    /// stop lets every window go, removes the display and puts the person's
    /// topology back. Single flight: a second caller waits for the first one's
    /// report rather than tearing the same display down twice.
    ///
    /// The teardown runs **inline** and not inside a child task, which is not
    /// cosmetic. Awaiting a child task is a real suspension, and a suspension
    /// here is the one thing a caller that pumps its own event loop cannot
    /// afford: the display only goes away while the loop turns, and this way
    /// `stop` never leaves the actor it was called on.
    @discardableResult
    public func stop() async -> TeardownReport {

        if isTearingDown {
            _ = await EventLoopWait.until({ !self.isTearingDown }, timeout: .seconds(5))
            return lastTeardown ?? Self.nothingToTearDown
        }

        isTearingDown = true
        let report = await performTeardown()
        lastTeardown  = report
        isTearingDown = false
        return report
    }

    /// The report of a host that had nothing to take down.
    private static let nothingToTearDown = TeardownReport(
        displayRemoved     : true,
        fenceReleased      : true,
        mainDisplayRestored: true,
        topologyRestoration: nil,
        windows            : [:],
        removalNanoseconds : 0
    )

    // MARK: The watchdog

    /// The watchdog runs on events where events exist and on one heartbeat a
    /// second for what nothing reports.
    ///
    /// The display and the topology have `CGDisplayRegisterReconfigurationCallback`,
    /// so a display going away is answered in the callback rather than up to a
    /// second later. The fence latches its own occurrences, so nothing is lost
    /// between two beats. What is left for the beat is the state with no
    /// notification: the cursor's position now, the tap's enabled bit, the CPU
    /// sample the Monitor's quality policy needs, and the one question a
    /// `waiting` seat has (did the person leave the target application).
    private func startWatchdog(expectedMainDisplayID: CGDirectDisplayID) {

        watchdogTask?.cancel()

        reconfiguration = DisplayReconfigurationWatch { [weak self] in
            self?.check(expectedMainDisplayID: expectedMainDisplayID)
        }

        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await EventLoopWait.sleep(SeatWatchdog.heartbeat)
                guard let self, !Task.isCancelled else { return }
                self.check(expectedMainDisplayID: expectedMainDisplayID)
                await self.evaluateMonitor()
                self.seat?.heartbeat()
            }
        }
    }

    /// One pass of the nine checks. The readings are gathered into one value
    /// first, so the whole verdict is about one instant.
    private func check(expectedMainDisplayID: CGDirectDisplayID) {

        guard state == .ready || state == .degraded,
              let systemSensing, !isFailingClosed
        else { return }

        let readings = SeatReadings(
            sensing              : systemSensing,
            expectedMainDisplayID: expectedMainDisplayID
        )
        let signals = systemSensing.drainFenceSignals()

        if !signals.isEmpty { eventChannel.yield(.fenceSignals(signals)) }

        let violations = SeatWatchdog.violations(readings: readings, signals: signals)
        guard !violations.isEmpty else { return }

        for violation in violations {
            eventChannel.yield(.issueDetected(violation.issue, cause: .watchdog(violation)))
        }

        failClosed(violations.map(\.issue), causes: violations.map { .watchdog($0) })
    }

    /// The Monitor's quality pass, fed with the share of CPU the host can
    /// attribute to it.
    ///
    /// Attribution is the whole point of this being here. A Monitor costing 3 %
    /// net was measured degrading itself because it was judged against the
    /// process total, and the scene it was filming cost 6,5 %: so the
    /// number passed is the process cost **above the idle baseline this host
    /// sampled before the Monitor started**, and nil until there is a baseline
    /// to subtract. It is a heuristic with a stated ceiling: anything else the
    /// consumer's process took up after the baseline is charged to the Monitor
    /// too, which is why the policy only ever uses it as the secondary signal
    /// behind coalescence.
    private func evaluateMonitor() async {

        let now = processCpuPercent()

        guard let monitor, monitor.configuration != nil else {
            if let now { idleCpuBaseline = idleCpuBaseline.map { min($0, now) } ?? now }
            return
        }

        var share: Double?
        if let now, let baseline = idleCpuBaseline { share = max(0, now - baseline) }

        guard let change = await monitor.evaluate(attributableCpuPercent: share) else { return }
        eventChannel.yield(.monitorQualityChanged(change))
    }

    /// The Monitor's health as this host reads it now.
    ///
    /// A Monitor nobody asked for is not a fault and implies no obligation to run
    /// one. A Monitor that was asked for and is not running is an **isolated**
    /// fault: the person loses the preview, the agent's observation and input are
    /// untouched, and whatever image is still on the layer is stale. The shared
    /// fault is set by the fail-closed path, where the display or the capture the
    /// observation needs is gone too.
    private var currentMonitorHealth: SeatMonitorHealth {
        guard configuration.monitor != nil else { return .notRequested }
        guard let monitor, monitor.isRunning else {
            return .isolatedFault(lastImageIsStale: monitor != nil)
        }
        return .live
    }

    /// Observes the Monitor's own lifecycle so a spontaneous ScreenCaptureKit
    /// stop is reported as soon as its delegate fires. The heartbeat remains
    /// responsible for quality; capture ownership is event driven.
    private func observeMonitorLifecycle(_ observed: Monitor) {

        monitorLifecycleTask?.cancel()
        monitorLifecycleTask = Task { @MainActor [weak self, weak observed] in
            guard let observed else { return }

            for await lifecycle in observed.stateChanges {
                guard let self, !Task.isCancelled else { return }
                guard self.monitor === observed, !self.isTearingDown else { return }

                if case .failed = lifecycle {
                    self.raiseHostIssue(.monitorUnavailable)
                    // Isolated: whatever the layer still shows is marked stale
                    // and kept, and the agent's own observation is not affected.
                    observed.markPresentationStale()
                    self.seat?.reportMonitorHealth(
                        .isolatedFault(lastImageIsStale: observed.presentation.hasImage)
                    )
                    return
                }
            }
        }
    }

    /// Retries the exact Monitor resource a previous stop could not confirm.
    /// A new preview is never created while that resource may still be active.
    private func retryRetainedMonitorStop() async {
        guard let retainedMonitor else { return }
        await retainedMonitor.stop()
        if !retainedMonitor.hasUnconfirmedResource { self.retainedMonitor = nil }
    }

    /// The process's CPU as a percentage of one core since the previous sample,
    /// from `proc_pid_rusage` with its ticks converted.
    private func processCpuPercent() -> Double? {

        var info = rusage_info_v6()
        let taken = withUnsafeMutablePointer(to: &info) { pointer -> Bool in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(getpid(), RUSAGE_INFO_V6, rebound) == 0
            }
        }
        guard taken else { return nil }

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let scale = Double(timebase.numer) / Double(timebase.denom)

        let user   = Double(info.ri_user_time)   * scale / 1e9
        let system = Double(info.ri_system_time) * scale / 1e9
        let now    = mach_absolute_time()

        defer { lastUsage = (user, system, now) }

        guard let previous = lastUsage else { return nil }

        let wall = Double(now &- previous.at) * scale / 1e9
        guard wall > 0 else { return nil }

        let cpu = (user - previous.userSeconds) + (system - previous.systemSeconds)
        return cpu / wall * 100
    }

    // MARK: Fail closed

    /// The fail-closed path: block new input at once, let what is running
    /// finish, release the windows best effort, tear the display down.
    ///
    /// The order matters and it was arrived at the hard way: cancel the work
    /// **before** destroying the display, because the
    /// work holds coordinates that only mean anything while the display is
    /// there.
    private func failClosed(_ issues: [SeatIssue], causes: [SeatIssueCause] = []) {

        guard !isFailingClosed, state == .ready || state == .degraded else { return }
        isFailingClosed = true

        transition(to: .failed, reason: .issues(issues))
        // The display, the fence or the capture the observation needs is gone, so
        // this is the shared fault and not the isolated one.
        seat?.reportMonitorHealth(.sharedFault)
        seat?.failFromHost(issues, causes: causes)

        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.stop()
            self.isFailingClosed = false
        }
    }

    /// Raises a host Issue that is not fatal. Today that is only
    /// `monitorUnavailable`: the person loses the preview, the seat works.
    private func raiseHostIssue(_ issue: SeatIssue) {

        eventChannel.yield(.issueDetected(issue, cause: nil))

        guard !issue.isCritical, state == .ready else { return }
        transition(to: .degraded, reason: .issues([issue]))
    }

    // MARK: Teardown

    private func performTeardown() async -> TeardownReport {

        seat?.stopFocusRecovery()

        await retryRetainedMonitorStop()

        watchdogTask?.cancel()
        watchdogTask    = nil
        monitorLifecycleTask?.cancel()
        monitorLifecycleTask = nil
        reconfiguration = nil

        let windows = await seat?.releaseAllWindows(.returnToUserSeat) ?? [:]

        if let monitor {
            await monitor.stop()
            if monitor.hasUnconfirmedResource { retainedMonitor = monitor }
        }
        monitor = nil

        let removed = display
        let start   = DispatchTime.now().uptimeNanoseconds

        removed?.invalidate()

        let fenceReleased = installedFence.map { $0.release() && !$0.isActive } ?? true
        installedFence = nil
        driver         = nil
        systemSensing  = nil
        display        = nil

        // The display is not gone when `invalidate` returns, and it only goes
        // while the caller's application event loop turns (ADR 0007). Two
        // seconds is the contract's ceiling; the measured removal is 47 to
        // 66 ms.
        var isRemoved = removed == nil
        if let removed {
            isRemoved = await EventLoopWait.until(
                { (try? removed.isOnline) == false },
                timeout: .seconds(2)
            )
        }
        let removalNanoseconds = DispatchTime.now().uptimeNanoseconds &- start

        // The person's own arrangement wins. If the display set differs from
        // the baseline they plugged or unplugged a screen during the session,
        // so nothing is written and the report says whose decision it was, a
        // distinction a plain "restore refused" cannot make.
        let restoration = removed.flatMap { try? $0.restoreTopology() }

        let mainRestored = removed.map { CGMainDisplayID() == $0.topology.mainDisplayID } ?? true

        seat = nil
        transition(to: .off, reason: .requested)

        let report = TeardownReport(
            displayRemoved     : isRemoved,
            fenceReleased      : fenceReleased,
            mainDisplayRestored: mainRestored,
            topologyRestoration: restoration,
            windows            : windows,
            removalNanoseconds : removalNanoseconds
        )

        eventChannel.yield(.teardownFinished(report))
        return report
    }

    /// The half of the teardown a failed `start` needs: take back whatever came
    /// up, without a report nobody asked for.
    private func dismantle() async {

        await retryRetainedMonitorStop()

        watchdogTask?.cancel()
        watchdogTask    = nil
        monitorLifecycleTask?.cancel()
        monitorLifecycleTask = nil
        reconfiguration = nil

        if let monitor {
            await monitor.stop()
            if monitor.hasUnconfirmedResource { retainedMonitor = monitor }
        }
        monitor = nil

        let removed = display
        removed?.invalidate()

        _ = installedFence?.release()
        installedFence = nil
        driver         = nil
        systemSensing  = nil
        display        = nil
        seat           = nil

        if let removed {
            _ = await EventLoopWait.until(
                { (try? removed.isOnline) == false },
                timeout: .seconds(2)
            )
        }
        _ = try? removed?.restoreTopology()
    }

    private func transition(to next: SeatHostState, reason: SeatTransitionReason) {

        guard next != state else { return }

        let previous = state
        state = next
        eventChannel.yield(.hostStateChanged(from: previous, to: next, reason: reason))

        Self.log.notice("""
            host \(previous.rawValue, privacy: .public) -> \
            \(next.rawValue, privacy: .public)
            """)
    }

    deinit { eventChannel.finish() }
}
