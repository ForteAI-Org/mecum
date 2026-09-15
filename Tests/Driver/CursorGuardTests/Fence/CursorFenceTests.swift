//
//  CursorFenceTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
@testable import CursorGuard
import Foundation
import SeatCore
import Testing

/// The unit tier of the fence: the same shape as the benchmark behind the saved
/// baseline, which is what makes the numbers comparable.
/// Every fence here is **detached**, so no `CGEventTap` is installed, no event
/// is ever posted and the pointer is never warped: `handle` is called directly
/// with events built in this process and thrown away.
///
/// The suite is serialized because the fence is shared per process by reference
/// count, and that shared slot is exactly one of the things under test.
@Suite("Cursor fence", .serialized)
@MainActor
struct CursorFenceTests {

    /// A region far from any real display, so nothing here depends on the
    /// machine the tests run on.
    static let bounds  = [CGRect(x: 0, y: 0, width: 1000, height: 800)]
    static let other   = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
    static let inside  = CGPoint(x: 500, y: 400)
    static let outside = CGPoint(x: 1600, y: 400)

    /// The nearest allowed point for `outside`: the region's own
    /// `nearestPoint` keeps half a point off the far edge, because
    /// `CGRect.contains` excludes its upper bound.
    static let clamped = CGPoint(x: 999.5, y: 400)

    static func makeFence() throws -> CursorFence {
        try CursorFence.acquireDetached(displayBounds: bounds)
    }

    static func makeEvent(_ type: CGEventType, at point: CGPoint, marker: Int64 = 0) throws -> CGEvent {
        let source = try #require(CGEventSource(stateID: .hidSystemState))
        let event  = try #require(
            CGEvent(
                mouseEventSource   : source,
                mouseType          : type,
                mouseCursorPosition: point,
                mouseButton        : .left
            )
        )
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        return event
    }

    // MARK: Clamping

    @Test("an event inside the region passes through untouched")
    func insideEventPassesThrough() throws {
        let fence = try Self.makeFence()
        defer { fence.release() }

        let event = try Self.makeEvent(.mouseMoved, at: Self.inside)
        #expect(fence.handle(type: .mouseMoved, event: event) != nil)
        #expect(event.location == Self.inside)

        let snapshot = fence.snapshot()
        #expect(snapshot.observedEventCount     == 1)
        #expect(snapshot.clampedEventCount      == 0)
        #expect(snapshot.outOfRegionEventCount  == 0)
        #expect(snapshot.lastOutOfRegionPoint   == nil)
    }

    @Test("an event outside the region is corrected to the nearest allowed point")
    func outsideEventClamped() throws {
        let fence = try Self.makeFence()
        defer { fence.release() }

        let event = try Self.makeEvent(.mouseMoved, at: Self.outside)
        #expect(fence.handle(type: .mouseMoved, event: event) != nil)
        #expect(event.location == Self.clamped)
        #expect(fence.containsPhysicalPoint(event.location))

        let snapshot = fence.snapshot()
        #expect(snapshot.clampedEventCount     == 1)
        #expect(snapshot.outOfRegionEventCount == 1)
        #expect(snapshot.lastOutOfRegionPoint  == Self.outside)
    }

    @Test("a press that starts outside is suppressed together with its release")
    func pressStartedOutsideSuppressed() throws {
        let fence = try Self.makeFence()
        defer { fence.release() }

        let down = try Self.makeEvent(.leftMouseDown, at: Self.outside)
        #expect(fence.handle(type: .leftMouseDown, event: down) == nil)

        // The release is inside by now, because the press warped the pointer
        // back. It is suppressed anyway: the target must never see half a click.
        let up = try Self.makeEvent(.leftMouseUp, at: Self.inside)
        #expect(fence.handle(type: .leftMouseUp, event: up) == nil)

        // The next release belongs to no suppressed press and goes through.
        let second = try Self.makeEvent(.leftMouseUp, at: Self.inside)
        #expect(fence.handle(type: .leftMouseUp, event: second) != nil)

        #expect(fence.snapshot().suppressedButtonEventCount == 2)
    }

    @Test("a press that starts inside is left alone")
    func pressStartedInsideAllowed() throws {
        let fence = try Self.makeFence()
        defer { fence.release() }

        let down = try Self.makeEvent(.leftMouseDown, at: Self.inside)
        #expect(fence.handle(type: .leftMouseDown, event: down) != nil)

        let up = try Self.makeEvent(.leftMouseUp, at: Self.inside)
        #expect(fence.handle(type: .leftMouseUp, event: up) != nil)

        #expect(fence.snapshot().suppressedButtonEventCount == 0)
    }

    // MARK: Anchors

    @Test("a synthetic event carrying an anchored marker is pinned to the anchor")
    func syntheticEventPinnedToAnchor() throws {
        let fence = try Self.makeFence()
        defer { fence.release() }

        fence.anchor(Self.inside, forSyntheticMarker: 42)
        let event = try Self.makeEvent(.mouseMoved, at: CGPoint(x: 100, y: 100), marker: 42)
        #expect(fence.handle(type: .mouseMoved, event: event) != nil)
        #expect(event.location == Self.inside)
        #expect(fence.snapshot().clampedEventCount == 1)
    }

    @Test("the anchor follows the person's real movement while an action runs")
    func anchorFollowsRealMovement() throws {
        let fence = try Self.makeFence()
        defer { fence.release() }

        fence.anchor(Self.inside, forSyntheticMarker: 42)

        let moved = CGPoint(x: 120, y: 640)
        let user  = try Self.makeEvent(.mouseMoved, at: moved)
        #expect(fence.handle(type: .mouseMoved, event: user) != nil)
        #expect(user.location == moved)

        // The next synthetic event is pinned to where the person is now, not to
        // where they were when the action started.
        let synthetic = try Self.makeEvent(.mouseMoved, at: CGPoint(x: 900, y: 100), marker: 42)
        #expect(fence.handle(type: .mouseMoved, event: synthetic) != nil)
        #expect(synthetic.location == moved)
    }

    @Test("an anchored marker reports as anchored only until it is dropped")
    func anchorLifetime() throws {
        let fence = try Self.makeFence()
        defer { fence.release() }

        fence.anchor(Self.inside, forSyntheticMarker: 42)
        // A detached fence has no tap, so `isAnchored` is false by design: the
        // anchor is evidence only while the fence can actually hold the cursor.
        #expect(!fence.isAnchored(forSyntheticMarker: 42))

        fence.endAnchor(forSyntheticMarker: 42)
        let event = try Self.makeEvent(.mouseMoved, at: CGPoint(x: 900, y: 100), marker: 42)
        #expect(fence.handle(type: .mouseMoved, event: event) != nil)
        #expect(event.location == CGPoint(x: 900, y: 100))
    }

    @Test("marker zero is refused, because an untagged event carries it")
    func markerZeroRefused() throws {
        let fence = try Self.makeFence()
        defer { fence.release() }

        #expect(throws: FenceFailure.markerReserved) {
            try fence.beginAnchor(forSyntheticMarker: 0)
        }
        #expect(throws: FenceFailure.markerReserved) {
            try fence.beginAudit(forSyntheticMarker: 0)
        }
    }

    // MARK: Audits

    @Test("the callback feeds every open audit, and ending it hands back a result")
    func auditRecordsTheDriverMarker() throws {
        let fence = try Self.makeFence()
        defer { fence.release() }

        let audit = CursorMotionAudit(
            marker   : 42,
            point    : Self.inside,
            timestamp: DispatchTime.now().uptimeNanoseconds
        )
        fence.attachAudit(audit, forSyntheticMarker: 42)

        let event = try Self.makeEvent(.mouseMoved, at: Self.inside, marker: 42)
        _ = fence.handle(type: .mouseMoved, event: event)

        let result = try #require(fence.endAudit(forSyntheticMarker: 42))
        #expect(result.driverEventCount == 1)

        // Ending it twice is safe: the second call finds nothing, which is what
        // makes it usable from a `defer` after the real reader already ran.
        #expect(fence.endAudit(forSyntheticMarker: 42) == nil)
    }

    @Test("a consumer's cursor sample and its verdict travel through the fence")
    func auditSampleAndInvalidation() throws {
        let fence = try Self.makeFence()
        defer { fence.release() }

        let now   = DispatchTime.now().uptimeNanoseconds
        let audit = CursorMotionAudit(marker: 7, point: Self.inside, timestamp: now)
        fence.attachAudit(audit, forSyntheticMarker: 7)

        fence.sampleAudit(forSyntheticMarker: 7, point: Self.inside, timestamp: now + 1_000)
        fence.finishAuditSampling(forSyntheticMarker: 7)
        fence.invalidateAudit(forSyntheticMarker: 7, reason: "fence released in the test")

        let result = try #require(fence.endAudit(forSyntheticMarker: 7))
        #expect(result.sampleCount == 1)
        #expect(result.failure     == "fence released in the test")
        #expect(!result.passed)
    }

    // MARK: Signals

    @Test("an out of region pointer is latched once and drained once")
    func signalsLatchAndReset() throws {
        let fence = try Self.makeFence()
        defer { fence.release() }

        #expect(fence.drainSignals().isEmpty)

        let event = try Self.makeEvent(.mouseMoved, at: Self.outside)
        _ = fence.handle(type: .mouseMoved, event: event)

        let signals = fence.drainSignals()
        #expect(!signals.isEmpty)
        #expect(signals.pointerOutOfRegion   == 1)
        #expect(signals.lastOutOfRegionPoint == Self.outside)
        #expect(signals.tapDisabled          == 0)
        #expect(signals.lastDisableReason    == nil)

        // Draining resets the batch and leaves the cumulative total alone: the
        // watchdog gets each occurrence exactly once, a report still gets the
        // running count.
        #expect(fence.drainSignals().isEmpty)
        #expect(fence.snapshot().outOfRegionEventCount == 1)
        #expect(fence.snapshot().lastOutOfRegionPoint  == Self.outside)
    }

    @Test("a disabled tap is latched, and the audits it interrupted are invalidated")
    func disabledTapLatched() throws {
        let fence = try Self.makeFence()
        defer { fence.release() }

        let audit = CursorMotionAudit(
            marker   : 3,
            point    : Self.inside,
            timestamp: DispatchTime.now().uptimeNanoseconds
        )
        fence.attachAudit(audit, forSyntheticMarker: 3)

        let event = try Self.makeEvent(.mouseMoved, at: Self.inside)
        #expect(fence.handle(type: .tapDisabledByTimeout, event: event) != nil)
        #expect(fence.handle(type: .tapDisabledByUserInput, event: event) != nil)

        let signals = fence.drainSignals()
        #expect(signals.tapDisabled       == 2)
        #expect(signals.lastDisableReason == .userInput)

        let snapshot = fence.snapshot()
        #expect(snapshot.disableCount      == 2)
        #expect(snapshot.lastDisableReason == .userInput)
        // A disabled-tap notification is not an observed HID event.
        #expect(snapshot.observedEventCount == 0)

        let result = try #require(fence.endAudit(forSyntheticMarker: 3))
        #expect(result.failure == "HID tap disabled during the action")
    }

    // MARK: Reference counting

    @Test("the first acquisition builds the fence and the last release drops it")
    func referenceCounting() throws {
        let first  = try Self.makeFence()
        let second = try Self.makeFence()

        #expect(first === second)
        #expect(first.snapshot().holderCount == 2)

        // One holder left: the fence is still the process's fence.
        #expect(first.release())
        #expect(first.snapshot().holderCount == 1)
        #expect(try Self.makeFence() === first)
        #expect(first.release())

        #expect(first.release())
        #expect(first.snapshot().holderCount == 0)

        // With no holder left the slot is empty, so the next acquisition builds
        // a new fence rather than handing back the released one.
        let third = try Self.makeFence()
        defer { third.release() }
        #expect(third !== first)
    }

    @Test("an acquisition with a different region is refused, not given a second tap")
    func regionMismatchRefused() throws {
        let fence = try Self.makeFence()
        defer { fence.release() }

        #expect(throws: FenceFailure.self) {
            try CursorFence.acquireDetached(displayBounds: Self.other)
        }
        #expect(fence.snapshot().holderCount == 1)
    }

    @Test("no usable display bound means no fence at all")
    func noPhysicalDisplays() {
        #expect(throws: FenceFailure.noPhysicalDisplays) {
            try CursorFence.acquireDetached(displayBounds: [])
        }
        #expect(throws: FenceFailure.noPhysicalDisplays) {
            try CursorFence.acquireDetached(displayBounds: [.null, .infinite, .zero])
        }
    }
}
