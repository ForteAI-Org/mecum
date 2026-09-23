//
//  ComposerHarness.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import Observation
import SwiftUI
@testable import Composer

/// ComposerHarness hosts a `ComposerBar` in SwiftUI inside a borderless window
/// that is never ordered in, and plays the model's part: it owns the draft,
/// counts sends and records every value the draft took, so a test can say what
/// reached the draft path and not only what the field shows.
///
/// Keys are real `NSEvent` key downs through the text view's `keyDown(with:)`,
/// so they go through `interpretKeyEvents` and the standard key bindings.
@Observable
@MainActor
final class ComposerHarness {

    var draft = "" { didSet { drafts.append(draft) } }
    var isAnswering = false
    var notice: String?

    /// Every value the draft was given, in order, by the field or by a test.
    private(set) var drafts: [String] = []
    private(set) var sends = 0

    /// What Send does; by default it counts. A test replaces it to play a refusal.
    @ObservationIgnored
    var onSend: (@MainActor (ComposerHarness) async -> Void)?

    @ObservationIgnored
    private(set) var window: NSWindow?

    let recipient: String

    init(recipient: String = "Milo", width: CGFloat = 600, appearance: NSAppearance.Name = .aqua) {
        self.recipient = recipient
        let hosting = NSHostingView(rootView: Root(harness: self))
        let window  = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 240), styleMask: [.borderless],
                               backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance  = NSAppearance(named: appearance)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        self.window = window
    }

    var hosting: NSView? { window?.contentView }

    var scrollView: ComposerScrollView? { hosting.flatMap { Self.find(in: $0) } }

    var textView: ComposerTextView? { scrollView?.textView }

    /// Lets SwiftUI apply what changed, then lays the window out.
    func settle() async throws {
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(20))
            hosting?.layoutSubtreeIfNeeded()
        }
    }

    func focus() {
        guard let textView else { return }
        window?.makeFirstResponder(textView)
    }

    /// Types `text` one key down per character; letters, spaces and digits only.
    func type(_ text: String) {
        for character in text { press(String(character), keyCode: Self.keyCode(for: character)) }
    }

    func pressReturn(option: Bool = false) {
        press("\r", keyCode: 36, modifiers: option ? [.option] : [])
    }

    func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        guard let textView, let window,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: keyCode)
        else { return }
        textView.keyDown(with: event)
    }

    func close() { window?.close() }

    private func send() {
        guard let onSend else {
            sends += 1
            return
        }
        Task { await onSend(self) }
    }

    private static func find(in view: NSView) -> ComposerScrollView? {
        if let found = view as? ComposerScrollView { return found }
        for subview in view.subviews {
            if let found = find(in: subview) { return found }
        }
        return nil
    }

    /// ANSI key codes, which the input source maps back to the character.
    private static func keyCode(for character: Character) -> UInt16 {
        let codes: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38,
            "k": 40, "n": 45, "m": 46, " ": 49, "1": 18, "2": 19, "3": 20,
        ]
        return codes[character] ?? 0
    }

    private struct Root: View {

        @Bindable var harness: ComposerHarness

        var body: some View {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                ComposerBar(
                    draft      : $harness.draft,
                    recipient  : harness.recipient,
                    notice     : harness.notice,
                    isAnswering: harness.isAnswering,
                    send       : { harness.send() },
                    stop       : { harness.isAnswering = false },
                    chooseModel: {}
                )
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}
