//
//  InputPlatformTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import SeatCore
@testable import SeatInput
import Testing

/// The Preparation policy, per platform and per Command. It is a table because
/// it *is* a table: every row of it was measured against a real target, and a
/// change here means one of those measurements was redone.
@Suite("What each platform prepares")
struct InputPlatformTests {

    private static let anywhere = InputLocation(screenPoint: .zero, windowPointFromTop: .zero)

    private static let commands: [InputCommand] = [
        .key(virtualKey: 6, text: "Z"),
        .text("Z"),
        .insertText("Z"),
        .click(anywhere),
        .drag(points: [anywhere, anywhere, anywhere]),
        .scroll(anywhere, deltaY: -6),
    ]

    @Test("AppKit prepares nothing at all", arguments: commands)
    func appKitPreparesNothing(command: InputCommand) {
        #expect(AppKitPlatform().preparation(for: command) == .none)
    }

    @Test("Chromium prepares the mouse and the bulk insertion, and nothing else")
    func chromiumPreparesTheMouseAndTheBulkInsertion() {
        let platform = ChromiumPlatform()

        #expect(platform.preparation(for: .click(Self.anywhere)) == .internalAppKitState)
        #expect(platform.preparation(for: .drag(points: [
            Self.anywhere, Self.anywhere, Self.anywhere,
        ])) == .internalAppKitState)

        // A key event carrying more than one character is dropped by a Chromium
        // renderer without it, in every window state measured.
        #expect(platform.preparation(for: .insertText("Zz")) == .internalAppKitState)

        #expect(platform.preparation(for: .key(virtualKey: 6, text: "Z")) == .none)
        #expect(platform.preparation(for: .text("Z")) == .none)
        #expect(platform.preparation(for: .scroll(Self.anywhere, deltaY: -6)) == .none)
    }

    /// The one row of this table where preparing is worse than not preparing.
    /// It has a test of its own because it reads like an omission: every other
    /// mouse Command on this family is prepared, and this one must not be.
    @Test("Chromium does not prepare a right click, because the restore closes the menu")
    func chromiumNeverPreparesARightClick() {
        let platform = ChromiumPlatform()

        #expect(platform.preparation(for: .click(Self.anywhere, button: .right)) == .none)
        #expect(platform.preparation(for: .click(Self.anywhere, button: .left))
            == .internalAppKitState)
    }

    @Test("AppKit prepares nothing for either button either")
    func appKitPreparesNothingForEitherButton() {
        for button in MouseButton.allCases {
            #expect(AppKitPlatform().preparation(for: .click(Self.anywhere, button: button))
                == .none)
        }
    }

    /// The keyboard recipe for a window of another process drawn inside a modal
    /// surface. Changing only the recipient left Escape without effect, so the
    /// remote owner is prepared and its key window named before the events; the
    /// mouse on the same endpoint needed none of it.
    @Test("the remote keyboard recipe prepares every Command that carries keys, and no mouse one")
    func remoteKeyboardPreparesTheKeys() {
        let platform = RemoteKeyboardPlatform()

        #expect(platform.preparation(for: .key(virtualKey: 53, text: "")) == .internalAppKitState)
        #expect(platform.preparation(for: .text("Z")) == .internalAppKitState)
        #expect(platform.preparation(for: .insertText("Zz")) == .internalAppKitState)

        #expect(platform.preparation(for: .click(Self.anywhere)) == .none)
        #expect(platform.preparation(for: .scroll(Self.anywhere, deltaY: -6)) == .none)
    }

    @Test("the remote keyboard settle is the recipe's own, and not the shared default")
    func remoteKeyboardCarriesItsOwnSettle() {
        let platform = RemoteKeyboardPlatform()

        for command in Self.commands {
            #expect(platform.preparationSettle(for: command) == .milliseconds(50))
        }
        #expect(platform.preparationSettle(for: .key(virtualKey: 53, text: ""))
            != AppKitPlatform().preparationSettle(for: .key(virtualKey: 53, text: "")))
    }

    @Test("universal is the Chromium policy, which is the safe superset")
    func universalIsChromium() {
        let universal: any InputPlatform = .universal

        for command in Self.commands {
            #expect(universal.preparation(for: command)
                == ChromiumPlatform().preparation(for: command))
        }
    }

    @Test("both platforms take the measured settle and the measured pacing")
    func defaultsAreTheMeasuredOnes() {
        // Both target families applied the preparation within 20 ms, so the
        // default is the smallest value tried plus half again.
        for command in Self.commands {
            #expect(AppKitPlatform().preparationSettle(for: command) == .milliseconds(30))
        }
        #expect(ChromiumPlatform().preparationSettle(for: .click(Self.anywhere))
            == .milliseconds(30))
        #expect(ChromiumPlatform().dragPacing == .realistic)
    }

    /// The one Command that asks for a longer wait, and the reason the wait is
    /// asked per Command instead of per platform.
    @Test("Chromium waits far longer before a bulk insertion than before a click")
    func chromiumWaitsLongerBeforeABulkInsertion() {
        let platform = ChromiumPlatform()

        #expect(platform.preparationSettle(for: .insertText("Zz")) == .milliseconds(150))
        #expect(platform.preparationSettle(for: .text("Zz")) == .milliseconds(30))
        #expect(platform.preparationSettle(for: .insertText("Zz"))
            > platform.preparationSettle(for: .click(Self.anywhere)))
    }

    /// A consumer's own platform: it writes one method and inherits the rest,
    /// which is the whole reason the protocol has defaults.
    private struct SlowFlutterPlatform: InputPlatform {
        func preparation(for command: InputCommand) -> Preparation { .internalAppKitState }
        func preparationSettle(for command: InputCommand) -> Duration { .milliseconds(120) }
    }

    @Test("a platform a consumer writes only has to say when to prepare")
    func aConsumerPlatformInheritsTheRest() {
        let platform = SlowFlutterPlatform()

        #expect(platform.preparation(for: .text("Z")) == .internalAppKitState)
        #expect(platform.preparationSettle(for: .text("Z")) == .milliseconds(120))
        #expect(platform.dragPacing == .realistic)
    }
}
