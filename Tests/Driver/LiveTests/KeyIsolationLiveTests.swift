//
//  KeyIsolationLiveTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

import AppKit
import CoreGraphics
import Foundation
import SeatCore
import SeatInput
import SeatSession
import Testing
import WindowPlacement

/// What a held modifier reaches, and what it does not.
///
/// `KeyHold` is keyed by process id on a **belief**: two windows of one
/// application are one AppKit process with one idea of what is held, so the PID
/// is the boundary the system actually has. Nobody has measured that. This
/// suite is where the belief is confirmed or falsified, and if it is falsified
/// the key of that registry is what changes.
///
/// The observable is `m=` in the probe page's title, the modifier mask of the
/// last key event the page saw. It is the only view from outside onto what a
/// posted event actually said about the modifiers.
@MainActor
struct KeyIsolationLiveTests {

    /// The left shift key, held and released by its own position rather than by
    /// a character: a modifier has no character to resolve.
    static let shift = Shortcut.physical(
        PhysicalKey(name: "ShiftLeft", virtualKey: 56)
    )

    /// A plain letter, sent **as a position and not as a character**.
    ///
    /// That is the whole measurement. A character reference puts the text on
    /// the event, and a target handed a "c" inserts a c whatever the flags say,
    /// so the row would prove nothing about the modifier. A position carries no
    /// text, so the target derives the character itself from the keycode and
    /// the flags. Which position it is still comes from the layout, because on
    /// a Dvorak keyboard c is not where a QWERTY one puts it.
    static func letter(on layout: KeyboardLayout) throws -> Shortcut {
        let virtualKey = try #require(
            layout.virtualKey(producing: "c"),
            "the installed layout cannot produce a plain c"
        )
        return Shortcut(.virtualKey(virtualKey))
    }

    @Test("a modifier held on one window is carried by an event sent to another window of the same app",
          .enabled(if: liveSkipReason(needsChrome: true) == nil,
                   Comment(rawValue: liveSkipReason(needsChrome: true) ?? "")))
    func aHeldModifierCrossesWindowsOfOneProcess() async throws {

        try await LiveStage.run(needsFixture: false, needsChrome: false) { stage in
            try await Self.measure(on: stage)
        }
    }

    /// The row itself, out of the closure so the compiler can type check
    /// it in one piece and say what is wrong when it cannot.
    private static func measure(on stage: LiveStage) async throws {

        let page = try #require(Bundle.module.url(forResource: "probe-page", withExtension: "html"))
        let browser = try OwnBrowserTarget.launched(pageHTML: String(contentsOf: page, encoding: .utf8))
        defer { browser.terminate() }
        let added = try browser.openAdditionalWindow()
        let references = [browser.reference, added]
        let windows = references.map { reference in
            ChromeTarget(window: ChromeWindow(
                processID   : reference.processID,
                windowNumber: reference.windowNumber,
                frame       : reference.frame,
                title       : ""
            ))
        }
        NSRunningApplication(processIdentifier: stage.personBefore.frontmostProcessID)?.activate()
        try #require(LivePump.run(until: {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == stage.personBefore.frontmostProcessID
        }, timeout: 3))
        LivePump.run(for: 0.5)
        #expect(
            windows[0].processID == windows[1].processID,
            "the two probe windows are not the same process, so this row measures nothing"
        )

        var first  = try await adopt(windows[0], onto: stage.seat, bounds: stage.virtualBounds)
        var second = try await adopt(windows[1], onto: stage.seat, bounds: stage.virtualBounds)
        first = try await stage.seat.stage(first)
        let turn   = try await stage.seat.acquire()

        let layout = try #require(
            KeyboardLayoutReader.current(),
            "no layout is installed, so the letter cannot be placed"
        )
        let fieldBefore = windows[1].state()["field"] ?? 0

        // Shift goes down on the first window and is never released until
        // the end. Everything between is about what the second window sees.
        let down = try await stage.seat.send(Self.shift, phase: .down, to: first, turn: turn)
        try #require(LivePump.run(until: {
            windows[0].state()["lastModifiers"] == Double(Modifiers.shift.rawValue)
        }, timeout: 2))
        try stage.seat.confirm(down, .observed)
        _ = await stage.seat.concludeObservation()
        second = try await stage.seat.stage(second)
        let letter = try await stage.seat.send(try Self.letter(on: layout), to: second, turn: turn)
        LivePump.run(for: 0.6)

        let observed   = windows[1].state()["lastModifiers"]
        let fieldAfter = windows[1].state()["field"] ?? 0
        try stage.seat.confirm(letter, fieldAfter > fieldBefore ? .observed : .absent)
        _ = await stage.seat.concludeObservation()
        // Not `observed.map(String.init)`: that initializer has enough overloads
        // to make the type checker give up on the whole function.
        let reading = observed.map { value in "\(value)" } ?? "unreadable"
        print("second window saw modifiers \(reading)")

        if observed == nil {
            Issue.record("the second window published no modifier mask, so nothing is concluded")
        } else {
            // Either answer is a finding. Shift present confirms the per
            // process model; shift absent falsifies it and the registry has
            // to be keyed more narrowly than a PID.
            let detail = "the second window saw \(observed ?? -1) instead of "
                + "\(Modifiers.shift.rawValue): a modifier held on one window of a process "
                + "did not reach another window of the same process, so KeyHold is keyed "
                + "too broadly"
            #expect(observed == Double(Modifiers.shift.rawValue), Comment(rawValue: detail))
        }

        // The half above measures the kit: the event it built carried the
        // shift, which the unit tests already cover. This half measures the
        // **target**. The letter carried no text, so whatever landed in the
        // field is the target's own reading of a keycode and a flag set it was
        // handed, and that is the thing nobody has checked.
        if fieldAfter > fieldBefore {
            print("the second window's field grew by \(fieldAfter - fieldBefore) with shift held")
        } else {
            Issue.record(Comment(rawValue:
                "the letter never reached the second window's field, so what the target made "
                    + "of the held shift cannot be read"
            ))
        }

        first = try await stage.seat.stage(first)
        let up = try await stage.seat.send(Self.shift, phase: .up, to: first, turn: turn)
        try #require(LivePump.run(until: { windows[0].state()["lastModifiers"] == 0 }, timeout: 2))
        try stage.seat.confirm(up, .observed)
        #expect(
            KeyHold.shared.modifiers(processID: windows[0].window.processID).isEmpty,
            "the shift this row pressed was not given back"
        )
        _ = await stage.seat.concludeObservation()
        try stage.seat.release(turn)

        await stage.giveBack(second, of: windows[1], home: nil)
        await stage.giveBack(first,  of: windows[0], home: nil)
    }

}
