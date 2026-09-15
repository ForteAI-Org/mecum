//
//  WindowRelocatorTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import PrivateSymbols
import SeatCore
import Testing
import VirtualScreens
@testable import WindowPlacement

/// The relocator's refusals. Moving a real window needs a real window and the
/// Accessibility grant, so what a unit suite can prove is the half that matters
/// most: every path out of this module that is not a successful move is a
/// refusal, and none of them writes anything.
@Suite("Window relocation refuses rather than guesses")
struct WindowRelocatorTests {

    static let nowhere = WindowReference(
        processID   : 0x7FFF_0000,
        windowNumber: 0x00FF_FFF0,
        frame       : CGRect(x: 0, y: 0, width: 800, height: 600)
    )

    @Test("moving a window of a process that does not exist refuses")
    func moveWithoutAProcess() {
        // Which refusal depends on whether this binary holds the Accessibility
        // grant, and both are correct answers: what must never happen is a
        // write, a trap, or a silent success.
        #expect(throws: DisplayFailure.self) {
            try WindowRelocator.move(Self.nowhere, to: .zero)
        }
    }

    @Test("structural recovery of a window of a process that does not exist refuses")
    func recoverWithoutAProcess() {
        #expect(throws: DisplayFailure.self) {
            try WindowRelocator.recover(
                Self.nowhere,
                expectedTitle      : "anything",
                expectedSize       : CGSize(width: 800, height: 600),
                sourceDisplayBounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                to                 : .zero
            )
        }
    }

    @Test("staging a window that does not exist refuses instead of confirming")
    func stageWithoutAWindow() async {
        await #expect(throws: DisplayFailure.self) {
            try await WindowRelocator.stage(
                Self.nowhere,
                expectedSize : CGSize(width: 800, height: 600),
                within       : CGRect(x: 0, y: 0, width: 2560, height: 1440),
                timeout      : 0.2
            )
        }
    }

    @Test("the relocation primitive is one Ledger row, not a bare dlsym")
    func relocationPrimitiveIsGated() {
        #expect(WindowRelocator.relocationPrimitives == [.symbol(.axUIElementGetWindow)])
    }
}
