//
//  WindowIdentityTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import CoreGraphics
@testable import SeatCore
import Testing

@Suite("Window identity")
struct WindowIdentityTests {

    private static func identity(
        lifetime        : UInt32 = 10,
        ownerConnectionID: Int32 = 20
    ) -> WindowIdentity {
        WindowIdentity(
            process: ProcessIdentity(
                processID       : 42,
                serialNumberHigh: 0,
                serialNumberLow : lifetime
            ),
            windowNumber     : 7,
            ownerConnectionID: ownerConnectionID
        )
    }

    @Test("frame changes preserve the whole attested identity")
    func frameReplacement() {
        let original = WindowReference(identity: Self.identity(), frame: .zero)
        let moved = original.replacingFrame(CGRect(x: 50, y: 60, width: 700, height: 500))

        #expect(moved.identity == original.identity)
        #expect(moved.hasSameIdentity(as: original))
    }

    @Test("a reused PID and Window ID do not survive a lifetime change")
    func reusedLifetime() {
        let old = WindowReference(identity: Self.identity(lifetime: 10), frame: .zero)
        let replacement = WindowReference(identity: Self.identity(lifetime: 11), frame: .zero)

        #expect(!old.hasSameIdentity(as: replacement))
    }

    @Test("an owner connection change invalidates the reference")
    func ownerConnectionChange() {
        let old = WindowReference(identity: Self.identity(ownerConnectionID: 20), frame: .zero)
        let replacement = WindowReference(identity: Self.identity(ownerConnectionID: 21), frame: .zero)

        #expect(!old.hasSameIdentity(as: replacement))
    }

    @Test("raw compatibility references never prove identity")
    func unverifiedReference() {
        let first = WindowReference(processID: 42, windowNumber: 7, frame: .zero)
        let second = WindowReference(processID: 42, windowNumber: 7, frame: .zero)

        #expect(!first.hasSameIdentity(as: second))
        #expect(first.identity == nil)
    }
}
