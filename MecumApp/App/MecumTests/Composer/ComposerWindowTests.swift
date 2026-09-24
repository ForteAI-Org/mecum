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
///
/// Every check runs inside one test, each in a window of its own: once the
/// process has been active, the input method can end it with status zero. For
/// the same reason the suite's name sorts after every offscreen suite of this
/// target, so they all run first.
@Suite("Composer in a key window", .serialized)
@MainActor
struct ComposerWindowTests {

    @Test("Line breaks, indentation and Control-Tab, the pinned circle, Stop, and Release, in key windows")
    func keyWindows() async throws {
        try await lineBreaksAndSend()
        try await indentation()
        try await circleStaysPinned()
        try await circleBecomesStop()
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
        try await harness.settle()
        #expect(harness.sends == 0)
        #expect(harness.draft == "a\nb\nc")
        harness.pressReturn()
        try await harness.settle()
        #expect(harness.sends == 1)
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
        try await harness.settle()
        #expect(harness.draft == "if x\n    go\n    on")

        harness.pressTab(shift: true)
        try await harness.settle()
        #expect(harness.draft == "if x\n    go\non")
        #expect(textView.selectedRange() == NSRange(location: 14, length: 0))

        // A selection across lines indents each of them, and Shift-Tab takes the level back.
        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
        harness.pressTab()
        try await harness.settle()
        #expect(harness.draft == "    if x\n        go\n    on")
        harness.pressTab(shift: true)
        try await harness.settle()
        #expect(harness.draft == "if x\n    go\non")

        // Undo takes the outdent back as one change.
        textView.undoManager?.undo()
        try await harness.settle()
        #expect(harness.draft == "    if x\n        go\n    on")

        harness.pressTab(control: true)
        try await harness.settle()
        #expect(window.firstResponder !== textView)
        #expect(harness.draft == "    if x\n        go\n    on")
        harness.focus()
        harness.pressTab(shift: true, control: true)
        try await harness.settle()
        #expect(window.firstResponder !== textView)
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
            harness.draft = (1...lines).map { "line \($0)" }.joined(separator: "\n")
            try await harness.settleAnimation()
            let circle = try #require(harness.drawnCircle()).frame
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
        try await harness.settleAnimation()
        let send = try #require(harness.drawnCircle())

        harness.isAnswering = true
        try await harness.settle()
        let stop = try #require(harness.drawnCircle())
        print("send \(send), stop \(stop)")
        #expect(stop.frame == send.frame)
        #expect(stop.glyphPixels != send.glyphPixels)

        harness.pressReturn()
        try await harness.settle()
        #expect(harness.sends == 0)

        let window = try #require(harness.window)
        let period = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: ".", charactersIgnoringModifiers: ".", isARepeat: false, keyCode: 47
        ))
        NSApplication.shared.sendEvent(period)
        try await harness.settle()
        #expect(harness.stops == 1)
        #expect(!harness.isAnswering)
        let back = try #require(harness.drawnCircle())
        #expect(back.frame == send.frame && back.glyphPixels == send.glyphPixels)
    }

    /// Release shows only while the worker holds the computer, left of the circle, and releases.
    private func releaseButton() async throws {
        let harness    = try await keyWindowHarness()
        defer { harness.close() }
        let scrollView = try #require(harness.scrollView)
        let window     = try #require(harness.window)
        harness.type("hold")
        try await harness.settleAnimation()
        let circle = try #require(harness.drawnCircle()).frame
        let alone  = scrollView.convert(scrollView.bounds, to: nil)
        // Only the bar's spacing lies between the field and the circle: nothing else is drawn there.
        #expect(abs(circle.minX - alone.maxX - 8) <= 1)
        #expect(harness.drawnMark(between: alone.maxX, and: circle.minX, alongside: circle) == nil)

        harness.holdsComputer = true
        for _ in 0..<8 { try await harness.settle() }
        let field   = scrollView.convert(scrollView.bounds, to: nil)
        let release = try #require(harness.drawnMark(between: field.maxX, and: circle.minX, alongside: circle))
        print("circle \(circle), release glyph \(release), field \(alone.maxX) -> \(field.maxX)")
        #expect(try #require(harness.drawnCircle()).frame == circle)
        #expect(abs(alone.maxX - field.maxX - (ComposerBar.circleSide + 6)) <= 1)
        #expect(release.maxX < circle.minX && release.minX > field.maxX)
        #expect(abs(release.midY - circle.midY) <= 1.5)

        let point = NSPoint(x: release.midX, y: release.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let click = try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            window.sendEvent(click)
        }
        for _ in 0..<8 { try await harness.settle() }
        #expect(harness.releases == 1)
        #expect(!harness.holdsComputer)
        #expect(try #require(harness.drawnCircle()).frame == circle)
        #expect(abs(scrollView.convert(scrollView.bounds, to: nil).maxX - alone.maxX) <= 1)
    }
}
