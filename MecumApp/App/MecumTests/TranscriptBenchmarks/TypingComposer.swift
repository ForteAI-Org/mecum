//
//  TypingComposer.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import Observation
import SwiftUI
@testable import Mecum

/// TypingComposer is the composer as the conversation view hosts it, a
/// `ComposerBar` in SwiftUI whose draft is an observed property, placed under
/// a transcript in a benchmark window, and typed into one synthetic key at a time.
///
/// A key is a real `NSEvent` through the text view's `keyDown(with:)`, and it
/// counts as landed once the layout manager has laid its character out. The
/// SwiftUI update the draft change causes runs later on the main thread, so
/// it shows as waiting in the keys that follow it.
@Observable
@MainActor
final class TypingComposer {

    var draft = ""

    /// Keys whose character reached the text and was laid out.
    @ObservationIgnored
    private(set) var landed = 0

    @ObservationIgnored
    private var typed = 0

    @ObservationIgnored
    private var textView: ComposerTextView?

    private static let sentence = Array("the quick brown fox jumps over the lazy dog and keeps typing ")

    /// Hosts the bar along the bottom `height` points of `container`.
    init(in container: NSView, height: CGFloat) {
        let hosting = NSHostingView(rootView: ComposerBar(
            draft      : Binding(get: { [weak self] in self?.draft ?? "" }, set: { [weak self] in self?.draft = $0 }),
            recipient  : "Worker",
            canAnswer  : true,
            isAnswering: false,
            send       : {},
            stop       : {}
        ))
        hosting.frame = NSRect(x: 0, y: 0, width: container.bounds.width, height: height)
        hosting.autoresizingMask = [.width]
        container.addSubview(hosting)
        hosting.layoutSubtreeIfNeeded()
        textView = Self.find(in: hosting)?.textView
        if let textView { container.window?.makeFirstResponder(textView) }
    }

    var isReady: Bool { textView != nil }

    /// Delivers the next character's key down and lays it out.
    func typeNextKey() {
        guard let textView, let storage = textView.textStorage, let layout = textView.layoutManager,
              let window = textView.window
        else { return }
        let character = String(Self.sentence[typed % Self.sentence.count])
        typed += 1
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: character, charactersIgnoringModifiers: character,
                                           isARepeat: false, keyCode: 0)
        else { return }
        let before = storage.length
        textView.keyDown(with: event)
        guard storage.length == before + 1 else { return }
        layout.ensureLayout(forCharacterRange: NSRange(location: before, length: 1))
        landed += 1
    }

    private static func find(in view: NSView) -> ComposerScrollView? {
        if let found = view as? ComposerScrollView { return found }
        for subview in view.subviews {
            if let found = find(in: subview) { return found }
        }
        return nil
    }
}
