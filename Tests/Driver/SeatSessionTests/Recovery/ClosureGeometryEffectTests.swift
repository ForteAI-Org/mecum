//
//  ClosureGeometryEffectTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/09/2026.
//

import CoreGraphics
import SeatCore
@testable import SeatSession
import Testing

/// What a verified dialog closure did to the geometry of the window
/// underneath, measured from two frames. The live case is the host that moved
/// after an Escape closed a remote panel: the movement was never measured, so
/// an effect the seat could describe and one nobody could looked the same.
@Suite("Closure geometry effect")
struct ClosureGeometryEffectTests {

    static let before = FakeGeometry.adoptedWindow

    static func after(_ frame: CGRect, lifetime: UInt32 = 1) -> WindowReference {
        FakeGeometry.reference(frame: frame, lifetime: lifetime)
    }

    @Test("the same frame is no effect at all")
    func unchanged() {
        #expect(ClosureGeometryEffect.classify(
            before: Self.before,
            after : Self.before,
            within: FakeGeometry.virtual
        ) == .unchanged)
    }

    /// The oracle is the arithmetic and not the classifier: 120 points right
    /// and 60 down, the same 800 by 600, still inside the display.
    @Test("a translation at the same size on the same display is a host movement")
    func aDeterministicMovement() {

        let moved = CGRect(
            origin: CGPoint(x: FakeGeometry.windowOrigin.x + 120,
                            y: FakeGeometry.windowOrigin.y + 60),
            size  : FakeGeometry.windowSize
        )

        #expect(ClosureGeometryEffect.classify(
            before: Self.before,
            after : Self.after(moved),
            within: FakeGeometry.virtual
        ) == .hostMoved(from: Self.before.frame, to: moved))
    }

    @Test("a size that changed as well is an unknown effect")
    func aSizeThatChanged() {

        let both = CGRect(
            origin: CGPoint(x: FakeGeometry.windowOrigin.x + 120,
                            y: FakeGeometry.windowOrigin.y + 60),
            size  : CGSize(width: 880, height: 640)
        )

        #expect(ClosureGeometryEffect.classify(
            before: Self.before,
            after : Self.after(both),
            within: FakeGeometry.virtual
        ) == .unknownEffect)
    }

    @Test("a window that left the display is an unknown effect")
    func aWindowOffTheDisplay() {

        let escaped = CGRect(origin: CGPoint(x: 10, y: 10), size: FakeGeometry.windowSize)

        #expect(ClosureGeometryEffect.classify(
            before: Self.before,
            after : Self.after(escaped),
            within: FakeGeometry.virtual
        ) == .unknownEffect)
    }

    @Test("an unreadable window is an unknown effect and never a movement")
    func anUnreadableWindow() {
        #expect(ClosureGeometryEffect.classify(
            before: Self.before,
            after : nil,
            within: FakeGeometry.virtual
        ) == .unknownEffect)
    }

    /// A Window ID the system handed out again names another window, and a
    /// movement measured between two different windows is not a movement.
    @Test("another lifetime of the same window id is an unknown effect")
    func aReusedWindowID() {

        let moved = CGRect(
            origin: CGPoint(x: FakeGeometry.windowOrigin.x + 120,
                            y: FakeGeometry.windowOrigin.y),
            size  : FakeGeometry.windowSize
        )

        #expect(ClosureGeometryEffect.classify(
            before: Self.before,
            after : Self.after(moved, lifetime: 9),
            within: FakeGeometry.virtual
        ) == .unknownEffect)
    }
}
