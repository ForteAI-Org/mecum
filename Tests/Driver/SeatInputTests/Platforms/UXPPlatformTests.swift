//
//  UXPPlatformTests.swift
//  AgentSeatKit
//

import CoreGraphics
import SeatCore
import SeatInput
import Testing

@Suite("UXP surface preparation")
struct UXPPlatformTests {

    @Test("a calibrated wait survives selection of the leaf-modal recipe")
    func calibrationSurvivesLeafSelection() {
        let family = UXPPlatform(keyPreparationSettle: .milliseconds(100))
        let key = InputCommand.key(virtualKey: 53, text: "")
        #expect(family.preparation(for: key) == .none)
        #expect(family.preparingKeys.preparation(for: key) == .internalAppKitState)
        #expect(family.preparingKeys.preparationSettle(for: key) == .milliseconds(100))
    }

    @Test("the production default retains the measured 300 ms wait")
    func measuredDefault() {
        #expect(UXPPlatform().preparingKeys.preparationSettle(for: .text("probe")) == .milliseconds(300))
    }

    @Test("preparing a leaf never prepares pointer commands")
    func pointerCommandsRemainUnprepared() {
        let leaf = UXPPlatform().preparingKeys
        let location = InputLocation(screenPoint: .zero, windowPointFromTop: .zero)
        #expect(leaf.preparation(for: .click(location)) == .none)
        #expect(leaf.preparation(for: .scroll(location, deltaY: 1)) == .none)
    }

    @Test("a native modal keeps calibration and primes only its own keys")
    func nativeModalPriming() {
        let window = WindowReference(processID: 42, windowNumber: 77, frame: .zero)
        let family = UXPPlatform(keyPreparationSettle: .milliseconds(100))
        let native = family.primingKeys(in: window)
        let key = InputCommand.key(virtualKey: 53, text: "")
        #expect(native.preparation(for: key) == .none)
        #expect(native.keyWindowPriming(for: key)?.host == window)
        #expect(native.keyWindowPriming(for: .text("probe"))?.settle == .milliseconds(100))
        #expect(native.keyWindowPriming(for: .click(InputLocation(screenPoint: .zero, windowPointFromTop: .zero))) == nil)
        #expect(family.keyWindowPriming(for: key) == nil)
        #expect(family.preparingKeys.keyWindowPriming(for: key) == nil)
        #expect(native.preparingKeys.preparation(for: key) == .internalAppKitState)
        #expect(native.preparingKeys.keyWindowPriming(for: key) == nil)
    }

    @Test("document left-click calibration leaves other routes unchanged")
    func documentClickCalibration() {
        let location = InputLocation(screenPoint: .zero, windowPointFromTop: .zero)
        let family = UXPPlatform(keyPreparationSettle: .milliseconds(100)).preparingLeftClicks
        #expect(UXPPlatform().preparation(for: .click(location)) == .none)
        #expect(family.preparation(for: .click(location)) == .internalAppKitState)
        #expect(family.preparation(for: .click(location, count: 2)) == .none)
        #expect(family.preparationSettle(for: .click(location)) == .milliseconds(100))
        #expect(family.preparation(for: .click(location, button: .right)) == .none)
        #expect(family.preparation(for: .drag(from: location, to: location)) == .none)
        #expect(family.preparation(for: .scroll(location, deltaY: 1)) == .none)
        #expect(family.preparation(for: .key(virtualKey: 0, text: "")) == .none)
    }

    @Test("attested recipient priming removes document calibration")
    func recipientPrimingDropsCalibration() {
        let location = InputLocation(screenPoint: .zero, windowPointFromTop: .zero)
        let window = WindowReference(processID: 42, windowNumber: 77, frame: .zero)
        let family = UXPPlatform().preparingKeys.preparingLeftClicks
        let native = family.primingKeys(in: window)
        #expect(family.preparation(for: .click(location)) == .internalAppKitState)
        #expect(family.preparation(for: .key(virtualKey: 0, text: "")) == .internalAppKitState)
        #expect(native.preparation(for: .click(location)) == .none)
        #expect(native.preparation(for: .key(virtualKey: 53, text: "")) == .none)
        #expect(native.keyWindowPriming(for: .key(virtualKey: 53, text: ""))?.host == window)
    }

    @Test("document shortcut calibration requires the measured character, flags and press phase")
    func measuredDocumentShortcuts() {
        let family = UXPPlatform().preparingDocumentShortcuts
        let characters: [Character] = ["a", "d", "i", "z", "n", "w"]
        let flagSets: [Modifiers] = [.command, [.command, .shift], [.command, .option]]
        for character in characters {
            for modifiers in flagSets {
                let origin = CharacterShortcutOrigin(
                    character: character, effectiveModifiers: modifiers,
                    commandPlane: true, requiresShift: false
                )
                let command = InputCommand.key(virtualKey: 17, text: "", modifiers: modifiers, origin: origin)
                let measured = modifiers == .command && ["a", "d", "i", "z"].contains(character)
                    || modifiers == [.command, .shift] && character == "z"
                #expect(family.preparation(for: command) == (measured ? .internalAppKitState : .none))
                #expect(family.preparation(for: .key(virtualKey: 17, text: "", modifiers: modifiers,
                                                   phase: .down, origin: origin)) == .none)
            }
        }
        #expect(family.preparation(for: .key(virtualKey: 0, text: "", modifiers: .command)) == .none)
        #expect(family.preparation(for: .key(virtualKey: 36, text: "\r")) == .none)
        #expect(family.preparation(for: .text("probe")) == .none)
        #expect(family.preparation(for: .insertText("probe")) == .none)
    }

}
