//
//  ComposerTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Mecum

/// The composer's contract (§13.1, §13.2, §19.3), driven through SwiftUI with
/// real key events and `setMarkedText`, the way an input method drives it.
@Suite("Composer")
@MainActor
struct ComposerTests {

    private static let notFound = NSRange(location: NSNotFound, length: 0)

    @Test("Return sends, and the text it sent is the draft")
    func returnSends() async throws {
        let harness = ComposerHarness()
        defer { harness.close() }
        harness.focus()
        harness.type("hi")
        try await harness.settle()
        harness.pressReturn()
        try await harness.settle()
        #expect(harness.sends == 1)
        #expect(harness.draft == "hi")
        #expect(harness.textView?.string == "hi")
    }

    @Test("Option-Return inserts a line break and sends nothing")
    func optionReturnBreaks() async throws {
        let harness = ComposerHarness()
        defer { harness.close() }
        harness.focus()
        harness.type("a")
        harness.pressReturn(option: true)
        harness.type("b")
        try await harness.settle()
        #expect(harness.sends == 0)
        #expect(harness.draft == "a\nb")
    }

    @Test("Return during marked text commits the composition and does not send")
    func returnCommitsComposition() async throws {
        let harness   = ComposerHarness()
        defer { harness.close() }
        let textView  = try #require(harness.textView)
        harness.focus()
        harness.type("ok")
        try await harness.settle()
        textView.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0),
                               replacementRange: Self.notFound)
        #expect(textView.hasMarkedText())
        harness.pressReturn()
        try await harness.settle()
        #expect(harness.sends == 0)
        #expect(!textView.hasMarkedText())
        #expect(harness.draft == "okにほん")
        harness.pressReturn()
        try await harness.settle()
        #expect(harness.sends == 1)
    }

    @Test("Text inserted by an input method or dictation never sends, even with a line break in it")
    func insertedTextNeverSends() async throws {
        let harness  = ComposerHarness()
        defer { harness.close() }
        let textView = try #require(harness.textView)
        harness.focus()
        textView.insertText("dictated line\nand the next", replacementRange: Self.notFound)
        try await harness.settle()
        #expect(harness.sends == 0)
        #expect(harness.draft == "dictated line\nand the next")
    }

    @Test("The draft path receives committed text and never a half-composed character")
    func draftNeverHalfComposed() async throws {
        let harness  = ComposerHarness()
        defer { harness.close() }
        let textView = try #require(harness.textView)
        harness.focus()
        harness.type("ab")
        try await harness.settle()
        textView.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0), replacementRange: Self.notFound)
        try await harness.settle()
        textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: Self.notFound)
        try await harness.settle()
        #expect(textView.string == "abか")
        #expect(harness.draft == "ab")
        // A change notice while composing, as some input methods cause, still writes nothing.
        textView.didChangeText()
        try await harness.settle()
        #expect(harness.draft == "ab")
        textView.insertText("か", replacementRange: Self.notFound)
        try await harness.settle()
        #expect(harness.draft == "abか")
        #expect(!harness.drafts.contains { $0.contains("k") })
        #expect(harness.drafts == ["a", "ab", "abか"])
    }

    @Test("The field grows with its text up to its maximum, then scrolls inside")
    func growsThenScrolls() async throws {
        let harness    = ComposerHarness()
        defer { harness.close() }
        let scrollView = try #require(harness.scrollView)
        let textView   = scrollView.textView
        let empty      = scrollView.frame.height

        harness.draft = "one\ntwo\nthree"
        try await harness.settle()
        let three = scrollView.frame.height
        #expect(three > empty * 2)
        #expect(textView.frame.height <= scrollView.contentView.bounds.height + 1)

        harness.draft = (1...20).map { "line \($0)" }.joined(separator: "\n")
        try await harness.settle()
        let full = scrollView.frame.height
        #expect(full == scrollView.fittingHeight)
        #expect(full < three * 3)
        #expect(full > three)
        #expect(textView.frame.height > scrollView.contentView.bounds.height * 2)

        harness.draft = (1...40).map { "line \($0)" }.joined(separator: "\n")
        try await harness.settle()
        #expect(scrollView.frame.height == full)

        // Typing at the end keeps the caret in view, so the clip view is at the bottom.
        harness.focus()
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        harness.type(" z")
        try await harness.settle()
        #expect(abs(scrollView.contentView.bounds.maxY - textView.frame.maxY) < 2)
    }

    @Test("A refused send puts the text back into the field and the draft")
    func refusedSendRestores() async throws {
        let harness = ComposerHarness()
        defer { harness.close() }
        harness.onSend = { harness in
            // The model's order: the text leaves the draft, the store refuses, the text comes back.
            let typed = harness.draft
            harness.draft = ""
            for _ in 0..<5 { await Task.yield() }
            harness.draft = typed
        }
        harness.focus()
        harness.type("keep this")
        try await harness.settle()
        harness.pressReturn()
        try await harness.settle()
        try await harness.settle()
        #expect(harness.textView?.string == "keep this")
        #expect(harness.draft == "keep this")
        #expect(harness.drafts.suffix(2) == ["", "keep this"])
    }

    @Test("While a turn runs Send is disabled and Return does nothing, and editing still works")
    func sendWaitsForTheTurn() async throws {
        let harness = ComposerHarness()
        defer { harness.close() }
        harness.isAnswering = true
        try await harness.settle()
        harness.focus()
        harness.type("next")
        try await harness.settle()
        harness.pressReturn()
        try await harness.settle()
        #expect(harness.sends == 0)
        #expect(harness.draft == "next")
        #expect(!bar(draft: "next", isAnswering: true).canSend)
        #expect(bar(draft: "next", isAnswering: false).canSend)
        #expect(!bar(draft: " \n ", isAnswering: false).canSend)

        harness.isAnswering = false
        try await harness.settle()
        harness.pressReturn()
        try await harness.settle()
        #expect(harness.sends == 1)
    }

    @Test("The field is labelled with its recipient for VoiceOver, and its help names the keys")
    func accessibility() async throws {
        let harness  = ComposerHarness(recipient: "Atlas")
        defer { harness.close() }
        let textView = try #require(harness.textView)
        #expect(textView.accessibilityLabel() == "Message Atlas")
        #expect(textView.accessibilityPlaceholderValue() == "Message Atlas")
        #expect(textView.accessibilityHelp()?.contains("Control-Tab moves to the next control") == true)
        #expect(textView.accessibilityHelp()?.contains("Shift-Return") == true)
    }

    @Test("A recipient that cannot answer shows the model placeholder, and neither Send nor Return sends")
    func cannotAnswer() async throws {
        let harness = ComposerHarness(recipient: "Milo")
        defer { harness.close() }
        harness.canAnswer = false
        try await harness.settle()
        let textView = try #require(harness.textView)
        #expect(textView.placeholder == "Choose a model to message Milo")
        #expect(textView.accessibilityLabel() == "Choose a model to message Milo")
        harness.focus()
        harness.type("saved anyway")
        try await harness.settle()
        harness.pressReturn()
        try await harness.settle()
        #expect(harness.sends == 0)
        #expect(harness.draft == "saved anyway")
        #expect(!bar(draft: "saved anyway", canAnswer: false).canSend)
        #expect(bar(draft: "saved anyway", canAnswer: true).canSend)
    }

    private func bar(draft: String, isAnswering: Bool = false, canAnswer: Bool = true) -> ComposerBar {
        ComposerBar(draft: .constant(draft), recipient: "Milo", canAnswer: canAnswer, isAnswering: isAnswering,
                    send: {}, stop: {})
    }
}
