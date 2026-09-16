//
//  CursorFenceHostTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import CursorGuard
import Foundation
import PrivateSymbols
import SeatCore
import Testing

/// The person's real displays. The fence's region has to be built from these,
/// because a tap installed against invented bounds would confine the pointer to
/// somewhere the person is not.
nonisolated func physicalDisplayBounds() -> [CGRect] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &displayIDs, &count)
    return displayIDs.map { CGDisplayBounds($0) }
}

/// Accessibility gates a mutating HID tap. When it is missing the fence
/// refuses, which is itself the assertion: a host tier that silently passed
/// without a tap would prove nothing. The gate is at file scope because a
/// `.enabled(if:)` trait is evaluated outside the suite's isolation.
nonisolated func fenceTierEnabled() -> Bool {
    tierEnabled() && Permissions.preflight(.accessibility)
}

/// The host tier of the fence: it installs a real mutating `CGEventTap` at the
/// head of the HID stream on the machine that runs the tests, asks it the
/// questions a Seat Host asks, and takes it down again.
///
/// What it deliberately does not do: post an event, warp the person's pointer,
/// or hold the tap for longer than the assertions need. Everything the fence
/// does to the cursor here happens only if the pointer is already outside the
/// person's own displays, which on a machine with a physical display it is not.
@Suite("Cursor fence on the running host", .serialized)
@MainActor
struct CursorFenceHostTests {

    @Test("without Accessibility the fence refuses instead of installing", .enabled(if: tierEnabled()))
    func refusesWithoutAccessibility() throws {
        guard !Permissions.preflight(.accessibility) else { return }

        #expect(throws: FenceFailure.accessibilityPermissionMissing) {
            try CursorFence.acquire(displayBounds: physicalDisplayBounds())
        }
    }

    @Test("the tap installs, answers, and comes down clean", .enabled(if: fenceTierEnabled()))
    func installsAndTearsDown() throws {
        let bounds = physicalDisplayBounds()
        let fence  = try CursorFence.acquire(displayBounds: bounds)

        #expect(fence.isActive)

        let snapshot = fence.snapshot()
        #expect(snapshot.isActive)
        #expect(snapshot.physicalDisplayCount == bounds.count)
        #expect(snapshot.disableCount         == 0)
        #expect(snapshot.holderCount          == 1)

        // The region answers about the person's own pixels, border included.
        let inside = try #require(bounds.first).origin
        #expect(fence.containsPhysicalPoint(inside))
        #expect(!fence.containsPhysicalPoint(CGPoint(x: -100_000, y: -100_000)))

        // Nothing has happened yet, so the watchdog's batch is empty and says
        // so, which is the difference between quiet and no evidence.
        #expect(fence.drainSignals().isEmpty)

        #expect(fence.release())
        #expect(!fence.isActive)
    }

    @Test("a second acquisition shares the one tap of the process", .enabled(if: fenceTierEnabled()))
    func sharedByReferenceCount() throws {
        let bounds = physicalDisplayBounds()
        let first  = try CursorFence.acquire(displayBounds: bounds)
        let second = try CursorFence.acquire(displayBounds: bounds)

        #expect(first === second)
        #expect(first.snapshot().holderCount == 2)

        // Releasing one holder leaves the tap up: the other one still needs it.
        #expect(first.release())
        #expect(first.isActive)

        #expect(second.release())
        #expect(!second.isActive)
    }

    @Test("an acquisition with a different region is refused", .enabled(if: fenceTierEnabled()))
    func regionMismatchRefused() throws {
        let fence = try CursorFence.acquire(displayBounds: physicalDisplayBounds())
        defer { fence.release() }

        let different = physicalDisplayBounds().map { $0.insetBy(dx: 10, dy: 10) }
        #expect(throws: FenceFailure.self) {
            try CursorFence.acquire(displayBounds: different)
        }
        #expect(fence.isActive)
        #expect(fence.snapshot().holderCount == 1)
    }

    @Test("an anchor is evidence only while the tap holds", .enabled(if: fenceTierEnabled()))
    func anchorNeedsTheTap() throws {
        let fence = try CursorFence.acquire(displayBounds: physicalDisplayBounds())
        defer { fence.release() }

        try fence.beginAnchor(forSyntheticMarker: 4_242)
        #expect(fence.isAnchored(forSyntheticMarker: 4_242))

        fence.endAnchor(forSyntheticMarker: 4_242)
        #expect(!fence.isAnchored(forSyntheticMarker: 4_242))
    }

    @Test("an audit opens on the live tap and closes into a result", .enabled(if: fenceTierEnabled()))
    func auditRoundTrip() throws {
        let fence = try CursorFence.acquire(displayBounds: physicalDisplayBounds())
        defer { fence.release() }

        try fence.beginAudit(forSyntheticMarker: 4_243)
        fence.sampleAudit(
            forSyntheticMarker: 4_243,
            point             : CGEvent(source: nil)?.location,
            timestamp         : DispatchTime.now().uptimeNanoseconds
        )
        fence.finishAuditSampling(forSyntheticMarker: 4_243)

        let result = try #require(fence.endAudit(forSyntheticMarker: 4_243))
        #expect(result.sampleCount >= 1)
        #expect(fence.endAudit(forSyntheticMarker: 4_243) == nil)
    }
}
