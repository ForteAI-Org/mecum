//
//  CursorFence.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreFoundation
import CoreGraphics
import Darwin
import Foundation
import os
import PrivateSymbols
import SeatCore

/// CursorFence keeps the person's pointer on the person's own displays. It is a
/// mutating `CGEventTap` at the head of the HID stream, so it rewrites the
/// global mouse events **before** any application is told about them: a point
/// outside the physical region is pulled back to its nearest allowed pixel, and
/// a press that started outside is dropped together with its release, so no
/// application ever sees half a click. It does not create a second User Seat
/// and it posts nothing.
///
/// Four properties are load bearing, and each of them is a decision:
///
/// 1. **Its own thread.** The tap's run loop source is on a dedicated
///    `.userInteractive` thread (`FenceRunLoopThread`), never on the
///    consumer's main run loop. A tap that answers late is a tap WindowServer
///    disables, and the consumer's UI is exactly the thing that answers late.
/// 2. **Zero allocations in the callback**, at rest, with an anchor in flight
///    and with an audit recording. This is a measured budget, not an
///    aspiration: `SeatBench fence-callback` fails the build if a single
///    allocation appears, and the two that the obvious shape costs are designed
///    out: the anchor walk copies no keys and the audit's traces are
///    preallocated.
/// 3. **One tap per process, shared by reference count.** The physical region
///    is a property of the machine, not of a caller, so the first acquisition
///    installs the tap and the last release removes it. An acquisition asking
///    for a *different* region is `FenceFailure.regionMismatch`, never a second
///    tap: two taps would mean two answers to the same question.
/// 4. **Signals, not polling.** What the callback sees (a disabled tap, a
///    pointer already outside the region) is latched into preallocated state
///    and drained by `drainSignals()`. See `FenceSignals` for why the callback
///    cannot publish and what the seat watchdog gets instead.
///
/// The fence reports; it does not decide. `disableCount > 0` is a fact it hands
/// over, and whether that means the seat fails closed belongs to the consumer.
nonisolated public final class CursorFence: @unchecked Sendable {

    /// The mouse buttons whose press was suppressed, so that the matching
    /// release can be suppressed too. An `OptionSet` over one byte, because the
    /// callback touches it on every press and release.
    private struct MouseButtons: OptionSet {
        let rawValue: UInt8

        static let left  = MouseButtons(rawValue: 1 << 0)
        static let right = MouseButtons(rawValue: 1 << 1)
        static let other = MouseButtons(rawValue: 1 << 2)
    }

    /// Every mouse event the fence has an opinion about: movement and drags
    /// carry the pointer, presses and releases carry the click that must not
    /// land on the virtual display. Scroll and keyboard are not asked for, so
    /// they never reach the callback at all.
    private static let eventsOfInterest: CGEventMask =
        (1 << CGEventType.mouseMoved.rawValue)
        | (1 << CGEventType.leftMouseDragged.rawValue)
        | (1 << CGEventType.rightMouseDragged.rawValue)
        | (1 << CGEventType.otherMouseDragged.rawValue)
        | (1 << CGEventType.leftMouseDown.rawValue)
        | (1 << CGEventType.rightMouseDown.rawValue)
        | (1 << CGEventType.otherMouseDown.rawValue)
        | (1 << CGEventType.leftMouseUp.rawValue)
        | (1 << CGEventType.rightMouseUp.rawValue)
        | (1 << CGEventType.otherMouseUp.rawValue)

    // MARK: Shared instance

    /// The one fence of this process. It lives on the main actor, which is
    /// where a Seat Host runs (spec section 7), so the slot itself needs no
    /// lock; the hold count sits next to the rest of the state, behind the
    /// fence's own lock, so `snapshot()` can report it from any thread.
    @MainActor private static var installed: CursorFence?

    // MARK: Immutable state

    /// The region the pointer is confined to, fixed for the life of the tap.
    public let region: PhysicalCursorRegion

    /// Whether this fence may move the physical pointer. False only for a
    /// detached fence: it owns no tap, so it has no right to warp the person's
    /// cursor either, and that is exactly what lets the unit tier and the
    /// benchmark walk the clamp branch with synthetic events.
    private let movesPhysicalCursor: Bool

    /// The timebase the audit needs to tell a Mach tick timestamp from a
    /// nanosecond one. Read once: `mach_timebase_info` in the callback would be
    /// a syscall per event.
    private let eventTimebase: mach_timebase_info_data_t

    /// The lock the tap callback writes under and every consumer reads under.
    /// An `os_unfair_lock` and not an `actor`, because an actor hop costs about
    /// one measured allocation per call and the callback's budget
    /// is zero. It is heap allocated once so its address never moves, which
    /// `os_unfair_lock` requires.
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    // MARK: State behind the lock

    private var eventTap          : CFMachPort?
    private var runLoopThread     : FenceRunLoopThread?
    private var suppressionSources: [(source: CGEventSource, previousInterval: TimeInterval)] = []

    private var anchors = MarkerTable<CGPoint>()
    private var audits  = MarkerTable<CursorMotionAudit>()

    private var suppressedMouseButtons: MouseButtons = []

    private var observedEventCount         : UInt64 = 0
    private var clampedEventCount          : UInt64 = 0
    private var suppressedButtonEventCount : UInt64 = 0
    private var disableCount               : UInt64 = 0
    private var outOfRegionEventCount      : UInt64 = 0

    private var lastDisableReason   : FenceDisableReason?
    private var lastOutOfRegionPoint: CGPoint?

    /// How many holders acquired the shared fence and have not released it.
    private var holders = 0

    /// The undrained half of the same facts. `FenceSignals` explains why these
    /// exist next to the cumulative counters instead of replacing them.
    private var pendingDisableCount    : UInt64 = 0
    private var pendingOutOfRegionCount: UInt64 = 0
    private var pendingDisableReason   : FenceDisableReason?
    private var pendingOutOfRegionPoint: CGPoint?

    // MARK: Life cycle

    private init(region: PhysicalCursorRegion, movesPhysicalCursor: Bool) {
        self.region              = region
        self.movesPhysicalCursor = movesPhysicalCursor

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        eventTimebase = timebase

        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// acquire hands back the process's fence, installing it on the first call.
    /// The region is rebuilt from the bounds every time and compared, so a
    /// caller that meanwhile saw the topology change is told rather than
    /// silently fenced to the old shape.
    ///
    /// Accessibility is checked with `Permissions.preflight`, which never
    /// prompts: a library that opens System Settings on its own is
    /// indistinguishable from a broken application.
    @MainActor
    public static func acquire(displayBounds: [CGRect]) throws -> CursorFence {
        try acquire(displayBounds: displayBounds, installingTap: true)
    }

    /// The same reference counting with no tap installed, for the benchmark and
    /// the unit tier: both drive `handle` with synthetic events that are never
    /// posted, exactly as the benchmark behind the baseline does.
    @MainActor
    package static func acquireDetached(displayBounds: [CGRect]) throws -> CursorFence {
        try acquire(displayBounds: displayBounds, installingTap: false)
    }

    @MainActor
    private static func acquire(
        displayBounds: [CGRect],
        installingTap: Bool
    ) throws -> CursorFence {
        guard let region = PhysicalCursorRegion(displayBounds: displayBounds) else {
            throw FenceFailure.noPhysicalDisplays
        }

        if let installed {
            guard installed.region == region else {
                throw FenceFailure.regionMismatch(
                    active   : installed.region.bounds,
                    requested: region.bounds
                )
            }
            installed.withFenceLock { installed.holders += 1 }
            return installed
        }

        let fence = CursorFence(region: region, movesPhysicalCursor: installingTap)
        if installingTap {
            guard Permissions.preflight(.accessibility) else {
                throw FenceFailure.accessibilityPermissionMissing
            }
            try fence.install()
            try fence.confineCurrentCursor()
        }

        fence.withFenceLock { fence.holders = 1 }
        installed = fence
        return fence
    }

    /// release gives back one hold. The last one takes the tap down, restores
    /// the event source suppression intervals it changed and invalidates every
    /// audit still open, because an audit that loses the fence mid action can
    /// no longer prove anything.
    ///
    /// True means the hold is gone. False means this was the last holder and
    /// the tap is somehow *still* enabled, which is the fail closed case the
    /// consumer has to report rather than ignore.
    @MainActor
    @discardableResult
    public func release() -> Bool {
        guard Self.installed === self else { return !isActive }

        let remaining = withFenceLock { () -> Int in
            holders = Swift.max(0, holders - 1)
            return holders
        }
        guard remaining == 0 else { return true }

        Self.installed = nil
        uninstall()
        return !isActive
    }

    /// Whether the tap is installed and enabled. The tap is read out from under
    /// the lock and asked afterwards, so a consumer polling `isActive` never
    /// makes the callback wait on a WindowServer round trip.
    public var isActive: Bool {
        guard let tap = withFenceLock({ eventTap }) else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// containsPhysicalPoint answers the fence's own admission test, so a
    /// consumer never has to rebuild the region to ask it.
    public func containsPhysicalPoint(_ point: CGPoint) -> Bool {
        region.contains(point)
    }

    /// Every counter and last value as one consistent set of fields. `isActive`
    /// is resolved first, deliberately: it is the only field that needs to talk
    /// to WindowServer, and it must not do that with the lock held.
    public func snapshot() -> FenceSnapshot {
        let active = isActive

        return withFenceLock {
            FenceSnapshot(
                physicalDisplayCount      : region.bounds.count,
                observedEventCount        : observedEventCount,
                clampedEventCount         : clampedEventCount,
                suppressedButtonEventCount: suppressedButtonEventCount,
                disableCount              : disableCount,
                outOfRegionEventCount     : outOfRegionEventCount,
                isActive                  : active,
                lastDisableReason         : lastDisableReason,
                lastOutOfRegionPoint      : lastOutOfRegionPoint,
                holderCount               : holders
            )
        }
    }

    /// drainSignals turns the state the callback latched into one batch of
    /// events and resets it, so nothing is reported twice and nothing between
    /// two calls is lost. This is the seam the seat watchdog is built on;
    /// `FenceSignals` states the contract in full.
    public func drainSignals() -> FenceSignals {
        withFenceLock {
            let signals = FenceSignals(
                tapDisabled         : pendingDisableCount,
                lastDisableReason   : pendingDisableReason,
                pointerOutOfRegion  : pendingOutOfRegionCount,
                lastOutOfRegionPoint: pendingOutOfRegionPoint
            )
            pendingDisableCount     = 0
            pendingOutOfRegionCount = 0
            pendingDisableReason    = nil
            pendingOutOfRegionPoint = nil
            return signals
        }
    }

    // MARK: Anchors

    /// The driver's mouse events carry virtual display coordinates in the
    /// routed record, and they must not drag the person's pointer along.
    /// beginAnchor remembers where the physical pointer is for one synthetic
    /// marker: while the anchor exists, every event carrying that marker is
    /// rewritten to it, and every real movement of the person moves the anchor.
    ///
    /// If the pointer is somehow already outside the region it is confined
    /// first, so the anchor is never a point the fence would refuse.
    public func beginAnchor(forSyntheticMarker marker: Int64) throws {
        guard marker != 0 else { throw FenceFailure.markerReserved }
        guard let point = CGEvent(source: nil)?.location else {
            throw FenceFailure.cursorPositionUnavailable
        }

        let anchorPoint = region.nearestPoint(to: point)
        if anchorPoint != point { warpCursor(to: anchorPoint) }
        anchor(anchorPoint, forSyntheticMarker: marker)
    }

    /// Places an anchor without reading or moving the physical cursor. The
    /// benchmark and the unit tier use it to reach the anchored branch of the
    /// callback without touching the person's pointer.
    package func anchor(_ point: CGPoint, forSyntheticMarker marker: Int64) {
        withFenceLock { anchors.insert(point, for: marker) }
    }

    /// Drops the anchor for a marker. Safe to call for a marker that has none,
    /// which is what makes it usable from a `defer`.
    public func endAnchor(forSyntheticMarker marker: Int64) {
        withFenceLock { _ = anchors.remove(marker) }
    }

    /// True only if the anchor exists **and** the fence was never disabled: an
    /// anchor is evidence the pointer was held still, and a tap that dropped
    /// out cannot offer that evidence.
    public func isAnchored(forSyntheticMarker marker: Int64) -> Bool {
        let active = isActive
        return withFenceLock {
            anchors.value(for: marker) != nil && active && disableCount == 0
        }
    }

    // MARK: Audits

    /// beginAudit opens a `CursorMotionAudit` for one synthetic marker. The
    /// audit object never leaves the fence: the callback writes HID input into
    /// it on the fence thread while the consumer feeds cursor samples from its
    /// own thread, so every access goes through the fence's lock and the
    /// consumer gets values back instead of a shared object.
    public func beginAudit(forSyntheticMarker marker: Int64) throws {
        guard marker != 0 else { throw FenceFailure.markerReserved }
        guard isActive, withFenceLock({ disableCount }) == 0 else {
            throw FenceFailure.eventTapUnavailable
        }
        guard let point = CGEvent(source: nil)?.location else {
            throw FenceFailure.cursorPositionUnavailable
        }

        attachAudit(
            CursorMotionAudit(
                marker   : marker,
                point    : point,
                timestamp: DispatchTime.now().uptimeNanoseconds
            ),
            forSyntheticMarker: marker
        )
    }

    /// Registers a prepared audit without reading the cursor, for the benchmark
    /// and the unit tier.
    package func attachAudit(_ audit: CursorMotionAudit, forSyntheticMarker marker: Int64) {
        withFenceLock { audits.insert(audit, for: marker) }
    }

    /// Records one reading of the global cursor against the audit. The
    /// consumer's sampler calls this; the HID side is recorded by the callback.
    public func sampleAudit(
        forSyntheticMarker marker: Int64,
        point                    : CGPoint?,
        timestamp                : UInt64
    ) {
        withFenceLock { audits.value(for: marker)?.sample(point: point, timestamp: timestamp) }
    }

    /// Closes the sampled interval after the last input and its settle. The tap
    /// stays attached, so late callbacks can still be reconciled.
    public func finishAuditSampling(forSyntheticMarker marker: Int64) {
        withFenceLock { audits.value(for: marker)?.finishSampling() }
    }

    /// Records the first reason the audit cannot conclude, from the consumer's
    /// side. The fence records its own reasons the same way.
    public func invalidateAudit(forSyntheticMarker marker: Int64, reason: String) {
        withFenceLock { audits.value(for: marker)?.invalidate(reason) }
    }

    /// Removes the audit and correlates the two traces. The removal happens
    /// under the lock and the correlation outside it, on an object nobody else
    /// can reach any more: `result()` sorts up to 8192 points twice, and doing
    /// that with the lock held would stall the callback for milliseconds.
    /// Returns nil when the marker had no audit, so a `defer` can call it after
    /// the real reader already did.
    @discardableResult
    public func endAudit(forSyntheticMarker marker: Int64) -> CursorMotionAudit.Result? {
        let audit = withFenceLock { audits.remove(marker) }
        return audit?.result()
    }

    // MARK: The callback

    /// The C entry point. It has no captures, does one unretained bridge back
    /// to the fence and calls straight into `handle`: no actor hop, no `Task`,
    /// no escaping closure, no `OSSignposter`, because each of those allocates
    /// and the budget here is zero.
    private static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        return Unmanaged<CursorFence>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
            .handle(type: type, event: event)
    }

    /// handle is the whole hot path, and its semantics are the measured ones:
    /// correct a point outside the region, suppress a press that
    /// started outside together with its release, pin a synthetic event to its
    /// anchor, follow the person's real movement while an anchor exists, and
    /// record every event into every open audit.
    ///
    /// The lock is held across the body, warps included. That is safe and not
    /// just convenient: the tap is delivered by a run loop source on a thread
    /// this fence owns and schedules nothing else on, so a `CGWarpMouseCursorPosition`
    /// here cannot re-enter the callback and deadlock on a non recursive lock.
    /// The only other users of the lock are consumer reads, which can wait.
    package func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let reason = type == .tapDisabledByTimeout ? FenceDisableReason.timeout : .userInput
            if let tap = recordDisable(reason) {
                // Re-arm at once to shorten the unprotected window. The consumer
                // still sees the disable in the signals: a fence that dropped out
                // for one event never regains the evidence it lost.
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        observedEventCount &+= 1

        let marker          = event.getIntegerValueField(.eventSourceUserData)
        let sourceProcessID = event.getIntegerValueField(.eventSourceUnixProcessID)
        let sourceStateID   = event.getIntegerValueField(.eventSourceStateID)
        let isMovement      = type == .mouseMoved || type == .leftMouseDragged
            || type == .rightMouseDragged || type == .otherMouseDragged

        // The audits read the location after the possible confinement, so a
        // suppressed or corrected event never counts as physical movement.
        defer {
            let receivedAt = DispatchTime.now().uptimeNanoseconds
            let point      = event.location
            for entry in audits.entries {
                entry.value.recordInput(
                    point              : point,
                    timestamp          : event.timestamp,
                    sourceProcessID    : sourceProcessID,
                    sourceStateID      : sourceStateID,
                    userData           : marker,
                    isMovement         : isMovement,
                    receivedAt         : receivedAt,
                    timebaseNumerator  : eventTimebase.numer,
                    timebaseDenominator: eventTimebase.denom
                )
            }
        }

        if let anchor = anchors.value(for: marker) {
            if event.location != anchor {
                clampedEventCount &+= 1
                event.location = anchor
            }
            return Unmanaged.passUnretained(event)
        }

        let location = event.location
        let clamped  = region.nearestPoint(to: location)
        let button   = Self.mouseButton(for: type)

        if clamped != location { recordOutOfRegion(location) }

        if let button, Self.isMouseDown(type), clamped != location {
            suppressedMouseButtons.insert(button)
            suppressedButtonEventCount &+= 1
            clampedEventCount &+= 1
            warpCursor(to: clamped)
            return nil
        }

        if let button, Self.isMouseUp(type), suppressedMouseButtons.contains(button) {
            suppressedMouseButtons.remove(button)
            suppressedButtonEventCount &+= 1
            if clamped != location {
                clampedEventCount &+= 1
                warpCursor(to: clamped)
            }
            return nil
        }

        if clamped != location {
            clampedEventCount &+= 1
            event.location = clamped
            warpCursor(to: clamped)
        } else if !anchors.isEmpty {
            // Follow the person's real movement: the next synthetic event stays
            // pinned to the most recent physical position, not to the one that
            // happened to be current when a long action started. `setAll` is
            // what removes the `Array(keys)` copy, and with it one allocation
            // per physical event during every action.
            anchors.setAll(location)
        }

        return Unmanaged.passUnretained(event)
    }

    /// Latches a disable and invalidates every open audit, then hands back the
    /// tap so the caller can re-arm it outside the lock.
    private func recordDisable(_ reason: FenceDisableReason) -> CFMachPort? {
        withFenceLock {
            for entry in audits.entries {
                entry.value.invalidate("HID tap disabled during the action")
            }
            disableCount        &+= 1
            pendingDisableCount &+= 1
            lastDisableReason    = reason
            pendingDisableReason = reason
            return eventTap
        }
    }

    /// Latches a pointer position the fence had to correct. Called with the
    /// lock already held, from inside the callback.
    private func recordOutOfRegion(_ point: CGPoint) {
        outOfRegionEventCount   &+= 1
        pendingOutOfRegionCount &+= 1
        lastOutOfRegionPoint     = point
        pendingOutOfRegionPoint  = point
    }

    // MARK: Install and uninstall

    private func install() throws {
        // Nothing here takes the lock: no run loop source exists yet, so the
        // callback cannot be running while this runs.
        // Zero suppression means a warp is not followed by a blind interval in
        // which the person's own movement is dropped. The previous values are
        // restored on teardown.
        for stateID in [CGEventSourceStateID.hidSystemState, .combinedSessionState] {
            guard let source = CGEventSource(stateID: stateID) else { continue }
            suppressionSources.append((
                source          : source,
                previousInterval: source.localEventsSuppressionInterval
            ))
            source.localEventsSuppressionInterval = 0
        }

        guard let tap = CGEvent.tapCreate(
            tap             : .cghidEventTap,
            place           : .headInsertEventTap,
            options         : .defaultTap,
            eventsOfInterest: Self.eventsOfInterest,
            callback        : Self.tapCallback,
            userInfo        : Unmanaged.passUnretained(self).toOpaque()
        ) else {
            uninstall()
            throw FenceFailure.eventTapUnavailable
        }
        eventTap = tap

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            uninstall()
            throw FenceFailure.eventTapUnavailable
        }

        let thread = FenceRunLoopThread(source: source)
        runLoopThread = thread
        guard thread.startAndWait() else {
            uninstall()
            throw FenceFailure.fenceThreadUnavailable
        }

        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            uninstall()
            throw FenceFailure.eventTapUnavailable
        }
    }

    /// Takes everything down in the order that keeps the mach port alive until
    /// nobody reads it: disable, stop the run loop and wait for the thread to
    /// leave it, only then invalidate the port.
    private func uninstall() {
        let tap = withFenceLock { eventTap }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }

        // Past this point no callback can run: the run loop that delivered them
        // has returned, so the state below is cleared with nobody reading it.
        runLoopThread?.stopAndWait()
        runLoopThread = nil
        if let tap { CFMachPortInvalidate(tap) }

        withFenceLock {
            eventTap = nil
            for entry in audits.entries {
                entry.value.invalidate("HID fence released during the action")
            }
            audits.removeAll()
            anchors.removeAll()
            suppressedMouseButtons = []
        }

        for entry in suppressionSources {
            entry.source.localEventsSuppressionInterval = entry.previousInterval
        }
        suppressionSources.removeAll()
    }

    private func confineCurrentCursor() throws {
        guard let point = CGEvent(source: nil)?.location else {
            uninstall()
            throw FenceFailure.cursorPositionUnavailable
        }
        let clamped = region.nearestPoint(to: point)
        if clamped != point { warpCursor(to: clamped) }
    }

    // MARK: Helpers

    /// A non escaping closure under the lock: measured at zero allocations,
    /// which is why the hot path can use the same shape as the cold accessors.
    @inline(__always)
    private func withFenceLock<Value>(_ body: () -> Value) -> Value {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return body()
    }

    /// The one place the physical pointer is moved, so a detached fence can
    /// refuse to move it in exactly one line.
    @inline(__always)
    private func warpCursor(to point: CGPoint) {
        guard movesPhysicalCursor else { return }
        CGWarpMouseCursorPosition(point)
    }

    private static func mouseButton(for type: CGEventType) -> MouseButtons? {
        switch type {
        case .leftMouseDown,  .leftMouseUp : .left
        case .rightMouseDown, .rightMouseUp: .right
        case .otherMouseDown, .otherMouseUp: .other
        default                            : nil
        }
    }

    private static func isMouseDown(_ type: CGEventType) -> Bool {
        type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
    }

    private static func isMouseUp(_ type: CGEventType) -> Bool {
        type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp
    }
}
