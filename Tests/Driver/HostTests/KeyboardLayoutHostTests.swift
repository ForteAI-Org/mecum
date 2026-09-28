//
//  KeyboardLayoutHostTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

import AppKit
import CoreGraphics
import SeatCore
@testable import SeatInput
import Testing

@MainActor
private final class KeyboardLayoutMenuTarget: NSObject {

    private(set) var actionCount = 0

    @objc func invoke(_ sender: Any?) {
        actionCount += 1
    }
}

/// The unit suite proves what a `KeyboardLayout` value does with a table built
/// by hand. Nothing there touches Carbon, so nothing there would notice if
/// `UCKeyTranslate` were called wrongly and every position came back empty.
/// This suite is the only thing that reads the layout actually installed, which
/// is why it says so little about *which* characters it expects: the machine
/// running it has whatever layout its owner chose.
@MainActor
@Suite("Keyboard layout on the running system", .serialized)
struct KeyboardLayoutHostTests {

    @Test("the reader answers with a usable layout", .enabled(if: tierEnabled()))
    func readerProducesALayout() throws {
        let layout = try #require(
            KeyboardLayoutReader.current(),
            "the current input source published no Unicode layout data"
        )

        #expect(!layout.inputSourceID.isEmpty)
        #expect(layout.generation > 0)
        #expect(layout.tableVersion == KeyNames.version)
    }

    @Test("the letter block produces something, whatever layout is installed", .enabled(if: tierEnabled()))
    func letterBlockIsPopulated() throws {
        let layout = try #require(KeyboardLayoutReader.current())

        // The twelve positions of the home and top letter rows. **Not** that
        // they carry letters: the machine this was first run on is a Dvorak
        // keyboard, where the three positions that carry q, w and e on a QWERTY
        // layout carry an apostrophe, a comma and a full stop. That assertion
        // failed here, and it was the assertion that was wrong. What the kit
        // needs is only that every one of them translates to something, because
        // an empty answer means the translation is broken rather than that the
        // layout is unusual.
        let letterPositions: [CGKeyCode] = [0, 1, 2, 3, 4, 5, 12, 13, 14, 15, 16, 17]
        let produced = letterPositions.compactMap { layout.character(of: $0) }

        #expect(produced.count == letterPositions.count)
    }

    @Test("every character the layout produces resolves back to a position that produces it", .enabled(if: tierEnabled()))
    func resolutionRoundTripsOnTheRealLayout() throws {
        let layout = try #require(KeyboardLayoutReader.current())

        // The property that has to hold on any layout, Dvorak and AZERTY
        // included: resolving a character gives a position, and that position
        // gives the character back. A position that answered some other
        // character would type the wrong glyph and nothing else would notice.
        var mismatches: [(Character, CGKeyCode?)] = []
        for key in KeyNames.all {
            guard let character = layout.character(of: key.virtualKey) else { continue }
            let resolved = layout.virtualKey(producing: character)
            if resolved.flatMap({ layout.character(of: $0) }) != character {
                mismatches.append((character, resolved))
            }
        }

        #expect(mismatches.isEmpty, "\(mismatches)")
    }

    @Test("a control position carries no character", .enabled(if: tierEnabled()))
    func controlPositionsAreExcluded() throws {
        let layout = try #require(KeyboardLayoutReader.current())

        // Return, Tab, Escape and Space. A shortcut names these as positions,
        // so letting them into the character table would give `resolve` two
        // ways to reach the same key and one of them would be a surprise.
        for virtualKey in [CGKeyCode(36), 48, 53, 49] {
            #expect(layout.character(of: virtualKey) == nil)
        }
    }

    @Test("two readings in a row agree and do not invent a generation", .enabled(if: tierEnabled()))
    func repeatedReadingsAreStable() throws {
        let first  = try #require(KeyboardLayoutReader.current())
        let second = try #require(KeyboardLayoutReader.current())

        #expect(first == second)
        #expect(first.generation == second.generation)
    }

    @Test("a character Shortcut invokes an isolated AppKit menu without Unicode injection", .enabled(if: tierEnabled()))
    @MainActor
    func characterShortcutUsesTheResolvedVirtualKey() throws {
        _ = NSApplication.shared
        let layout = try #require(KeyboardLayoutReader.current())
        let shortcut = Shortcut.character("g", holding: [.command, .shift])
        let target = KeyboardLayoutMenuTarget()
        let menu = NSMenu(title: "Keyboard layout regression")
        let item = NSMenuItem(
            title: "Go to Folder",
            action: #selector(KeyboardLayoutMenuTarget.invoke(_:)),
            keyEquivalent: "G"
        )
        item.keyEquivalentModifierMask = [.command, .shift]
        item.target = target
        menu.addItem(item)
        let resolved = try ShortcutResolution.resolve(
            shortcut,
            layout: layout,
            hold: KeyHold(),
            owner: 1,
            processID: 1
        )
        var events: [PreparedEvent] = []
        try InputEvents.append(
            resolved.command,
            source: try #require(CGEventSource(stateID: .privateState)),
            pacing: .realistic,
            correlationID: 700,
            into: &events
        )
        #expect(events.count == 2)
        let event = try #require(events.first?.event)
        let native = try #require(NSEvent(cgEvent: event))

        #expect(menu.performKeyEquivalent(with: native))
        #expect(target.actionCount == 1)
    }
}
