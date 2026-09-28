//
//  ComposerWindowTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import Foundation
import Testing
@testable import Mecum

/// The composer's keys and layout in a real key `NSWindow` on screen, with
/// every key sent through `NSWindow.sendEvent(_:)` as the event loop delivers
/// it, because offscreen calls into the text view missed bugs a person found.
/// The window takes only what the test sends it (`TestInputWindow`), and each
/// check waits for what it looks at, since the input method may hand a key's
/// text to the field later.
///
/// Every check runs inside one test, each in a window of its own: once the
/// process has been active, the input method can end it with status zero. For
/// the same reason the suite's name sorts after every offscreen suite of this
/// target, so they all run first.
@Suite("Composer in a key window", .serialized)
@MainActor
struct ComposerWindowTests {

    @Test("Line breaks, indentation and Control-Tab, the pinned circle, Stop, queueing, and Release, in key windows")
    func keyWindows() async throws {
        try await lineBreaksAndSend()
        try await indentation()
        try await circleStaysPinned()
        try await circleBecomesStop()
        try await commandReturnQueues()
        try await releaseButton()
    }

    /// A key window whose bar is on the material surface, where the circle is measured from what the view draws.
    private func keyWindowHarness() async throws -> ComposerHarness {
        let harness = ComposerHarness(surface: .material, onScreen: true)
        harness.becomeKey()
        harness.focus()
        try await harness.settle()
        // Another app can take the focus meanwhile, on a Mac someone is using; ask again.
        harness.becomeKey()
        let window = try #require(harness.window)
        #expect(window.isVisible)
        #expect(window.isKeyWindow)
        #expect(window.firstResponder === harness.textView)
        return harness
    }

    /// Shift-Return and Option-Return break the line, and Return sends.
    private func lineBreaksAndSend() async throws {
        let harness = try await keyWindowHarness()
        defer { harness.close() }
        harness.type("a")
        harness.pressReturn(shift: true)
        harness.type("b")
        harness.pressReturn(option: true)
        harness.type("c")
        try await harness.wait { harness.draft == "a\nb\nc" }
        #expect(harness.sends == 0)
        // Return sends once the bar has taken the draft, which the circle shows by taking the accent.
        _ = try await harness.waitForCircle()
        harness.pressReturn()
        try await harness.wait { harness.sends == 1 }
        #expect(harness.textView?.string == "a\nb\nc")
    }

    /// Tab and Shift-Tab indent and outdent, a line break keeps the indentation, Control-Tab leaves.
    private func indentation() async throws {
        let harness  = try await keyWindowHarness()
        defer { harness.close() }
        let textView = try #require(harness.textView)
        let window   = try #require(harness.window)

        harness.type("if x")
        harness.pressReturn(shift: true)
        harness.pressTab()
        harness.type("go")
        harness.pressReturn(shift: true)
        harness.type("on")
        try await harness.wait { harness.draft == "if x\n    go\n    on" }

        harness.pressTab(shift: true)
        try await harness.wait { harness.draft == "if x\n    go\non" }
        #expect(textView.selectedRange() == NSRange(
            location: 14,
            length  : 0
        ))

        // A selection across lines indents each of them, and Shift-Tab takes the level back.
        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
        harness.pressTab()
        try await harness.wait { harness.draft == "    if x\n        go\n    on" }
        harness.pressTab(shift: true)
        try await harness.wait { harness.draft == "if x\n    go\non" }

        // Undo takes the outdent back as one change.
        textView.undoManager?.undo()
        try await harness.wait { harness.draft == "    if x\n        go\n    on" }

        harness.pressTab(control: true)
        try await harness.wait { window.firstResponder !== textView }
        #expect(harness.draft == "    if x\n        go\n    on")
        harness.focus()
        harness.pressTab(
            shift  : true,
            control: true
        )
        try await harness.wait { window.firstResponder !== textView }
    }

    /// The circle stays at the bottom-trailing corner at one, three and six lines.
    private func circleStaysPinned() async throws {
        let harness    = try await keyWindowHarness()
        defer { harness.close() }
        let scrollView = try #require(harness.scrollView)
        let hosting    = try #require(harness.hosting)
        var circles: [NSRect] = []
        var fields : [NSRect] = []
        for lines in [1, 3, 6] {
            let draft = (1...lines).map { "line \($0)" }.joined(separator: "\n")
            harness.draft = draft
            // The field takes the draft on SwiftUI's next update, and grows past the last field it drew.
            try await harness.wait {
                harness.textView?.string == draft
                    && scrollView.convert(scrollView.bounds, to: nil).maxY > (fields.last?.maxY ?? 0)
            }
            let circle = try await harness.waitForCircle().frame
            circles.append(circle)
            fields.append(scrollView.convert(scrollView.bounds, to: nil))
            print("lines \(lines): circle \(circle), field \(fields.last ?? .zero), window \(hosting.bounds.size)")
        }
        // Window coordinates, origin at the bottom left: the circle does not move while the field grows up.
        #expect(circles.allSatisfy { $0 == circles[0] })
        #expect(fields[0].maxY < fields[1].maxY && fields[1].maxY < fields[2].maxY)
        let circle = circles[0]
        // The antialiased rim is not the solid accent, so the drawn box is up to a point smaller.
        #expect(abs(circle.width - ComposerBar.circleSide) <= 1 && abs(circle.height - ComposerBar.circleSide) <= 1)
        // Inset from the window's trailing and bottom edges by the bar's margins and the pill's padding.
        #expect(abs(hosting.bounds.maxX - circle.maxX - (16 + ComposerBar.padding)) <= 1)
        #expect(abs(circle.minY - (12 + ComposerBar.padding)) <= 1)
        #expect(fields.allSatisfy { $0.maxX < circle.minX && $0.minY < circle.maxY })
    }

    /// During a turn the circle becomes Stop in the same place, and Command-Period stops.
    private func circleBecomesStop() async throws {
        let harness = try await keyWindowHarness()
        defer { harness.close() }
        harness.type("next")
        try await harness.wait { harness.draft == "next" }
        let send = try await harness.waitForCircle()

        harness.isAnswering = true
        let stop = try await harness.waitForCircle { $0.glyphPixels != send.glyphPixels }
        print("send \(send), stop \(stop)")
        #expect(stop.frame == send.frame)
        #expect(stop.glyphPixels != send.glyphPixels)

        harness.pressReturn()
        try await harness.settle()
        #expect(harness.sends == 0)

        // Through the application, which offers Command-Period to the Stop button's shortcut.
        try harness.pressThroughApplication(
            ".",
            keyCode  : 47,
            modifiers: .command
        )
        try await harness.wait { harness.stops == 1 }
        #expect(!harness.isAnswering)
        let back = try await harness.waitForCircle { $0.glyphPixels == send.glyphPixels }
        #expect(back.frame == send.frame && back.glyphPixels == send.glyphPixels)
    }

    /// During a turn a composer that queues takes Command-Return as Send, where
    /// Return starts a new line, though the circle is Stop and answers Command-Period.
    private func commandReturnQueues() async throws {
        let harness = try await keyWindowHarness()
        defer { harness.close() }
        harness.queues      = true
        harness.returnSends = false
        harness.isAnswering = true
        harness.type("next")
        try await harness.wait { harness.draft == "next" }
        // The button that takes Command-Return for a draft draws nothing, so its arrival cannot be
        // waited on; a settle lets SwiftUI apply the draft to the bar.
        try await harness.settle()

        // Through the application, which offers Command-Return to the Send shortcut.
        try harness.pressThroughApplication(
            "\r",
            keyCode  : 36,
            modifiers: .command
        )
        try await harness.wait { harness.sends == 1 }
        // A line break or a stop would come with the send; settling gives either the time to show.
        try await harness.settle()
        #expect(harness.stops == 0)
        #expect(harness.draft == "next", "Command-Return adds no line break")
    }

    /// Release shows only while the worker holds the computer, left of the circle, and releases.
    private func releaseButton() async throws {
        let harness    = try await keyWindowHarness()
        defer { harness.close() }
        let scrollView = try #require(harness.scrollView)
        let window     = try #require(harness.window)
        harness.type("hold")
        try await harness.wait { harness.draft == "hold" }
        let circle = try await harness.waitForCircle().frame
        let alone  = scrollView.convert(scrollView.bounds, to: nil)
        // Only the bar's spacing lies between the field and the circle: nothing else is drawn there.
        #expect(abs(circle.minX - alone.maxX - 8) <= 1)
        #expect(harness.drawnMark(between: alone.maxX, and: circle.minX, alongside: circle) == nil)

        harness.holdsComputer = true
        // The field gives Release its room with a spring, and the glyph grows in it; both
        // have come to rest once the field is where it ends and the glyph draws as it did last time.
        var lastMark: NSRect?
        try await harness.wait {
            let field   = scrollView.convert(scrollView.bounds, to: nil)
            let mark    = harness.drawnMark(
                between  : field.maxX,
                and      : circle.minX,
                alongside: circle
            )
            let isStill = mark != nil && mark == lastMark
            lastMark    = mark
            return isStill && abs(alone.maxX - field.maxX - (ComposerBar.circleSide + 6)) <= 1
        }
        let field   = scrollView.convert(scrollView.bounds, to: nil)
        let release = try #require(harness.drawnMark(
            between  : field.maxX,
            and      : circle.minX,
            alongside: circle
        ))
        print("circle \(circle), release glyph \(release), field \(alone.maxX) -> \(field.maxX)")
        #expect(try #require(harness.drawnCircle()).frame == circle)
        #expect(abs(alone.maxX - field.maxX - (ComposerBar.circleSide + 6)) <= 1)
        #expect(release.maxX < circle.minX && release.minX > field.maxX)
        #expect(abs(release.midY - circle.midY) <= 1.5)

        // The click carries the test's event number, which the window lets through.
        let point = NSPoint(
            x: release.midX,
            y: release.midY
        )
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let click = try #require(NSEvent.mouseEvent(
                with         : type,
                location     : point,
                modifierFlags: [],
                timestamp    : ProcessInfo.processInfo.systemUptime,
                windowNumber : window.windowNumber,
                context      : nil,
                eventNumber  : TestInputWindow.clickNumber,
                clickCount   : 1,
                pressure     : 1
            ))
            window.sendEvent(click)
        }
        try await harness.wait { harness.releases == 1 }
        #expect(!harness.holdsComputer)
        // The field takes its room back once Release is gone.
        try await harness.wait { abs(scrollView.convert(scrollView.bounds, to: nil).maxX - alone.maxX) <= 1 }
        #expect(try #require(harness.drawnCircle()).frame == circle)
        #expect(abs(scrollView.convert(scrollView.bounds, to: nil).maxX - alone.maxX) <= 1)
    }
}
