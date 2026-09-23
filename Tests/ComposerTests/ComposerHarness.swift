//
//  ComposerHarness.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import Observation
import Synchronization
import SwiftUI
@testable import Composer

/// ComposerHarness hosts a `ComposerBar` in SwiftUI, floating over the bottom
/// of a stand-in transcript, and plays the model's part: it owns the draft,
/// counts sends and records every value the draft took, so a test can say what
/// reached the draft path and not only what the field shows.
///
/// Offscreen, the window is borderless and never ordered in, and keys are real
/// `NSEvent` key downs through the text view's `keyDown(with:)`. On screen, the
/// window is a titled window made key, keys go through `NSWindow.sendEvent(_:)`
/// as the event loop delivers them, and a second field after the composer gives
/// the key view loop somewhere to go.
@Observable
@MainActor
final class ComposerHarness {

    var draft = "" { didSet { drafts.append(draft) } }
    var isAnswering = false
    var canAnswer   = true
    var stops       = 0

    /// Plays the worker's desktop session: while true the bar offers Release,
    /// which counts and gives the computer back, as `close()` does.
    var holdsComputer = false
    private(set) var releases = 0

    /// Every value the draft was given, in order, by the field or by a test.
    private(set) var drafts: [String] = []
    private(set) var sends = 0

    /// What Send does; by default it counts. A test replaces it to play a refusal.
    @ObservationIgnored
    var onSend: (@MainActor (ComposerHarness) async -> Void)?

    @ObservationIgnored
    private(set) var window: NSWindow?

    let recipient: String
    let surface  : ComposerSurface.Kind?
    let isOnScreen: Bool

    /// On-screen harnesses not yet closed. The input method can end the test
    /// process with status zero mid-run (see `settle()`); an exit while one is
    /// open becomes status one, so a run cut short never reads as a pass.
    nonisolated static let openOnScreen = Atomic<Int>(0)

    /// The stand-in transcript behind the bar; off in the key window tests,
    /// which find the circle by its colour.
    let showsTranscript: Bool

    init(
        recipient : String = "Milo",
        width     : CGFloat = 600,
        height    : CGFloat = 240,
        appearance: NSAppearance.Name = .aqua,
        surface   : ComposerSurface.Kind? = nil,
        onScreen  : Bool = false,
        transcript: Bool? = nil
    ) {
        self.recipient       = recipient
        self.surface         = surface
        self.isOnScreen      = onScreen
        self.showsTranscript = transcript ?? !onScreen
        let hosting = NSHostingView(rootView: Root(harness: self))
        let frame   = NSRect(x: 200, y: 200, width: width, height: height)
        let window  = onScreen
            ? NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            : NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance  = NSAppearance(named: appearance)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        if onScreen {
            if Self.openOnScreen.add(1, ordering: .sequentiallyConsistent).oldValue == 0 {
                atexit(failIfCutShort)
            }
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        self.window = window
    }

    var hosting: NSView? { window?.contentView }

    var scrollView: ComposerScrollView? { hosting.flatMap { Self.find(ComposerScrollView.self, in: $0) } }

    var textView: ComposerTextView? { scrollView?.textView }

    /// Lets SwiftUI apply what changed, then lays the window out.
    ///
    /// On screen it waits inside a nested run loop and never suspends, and it
    /// delivers what the window server queued, activation included, since no
    /// event loop runs in a test process. Once the process has been active, the
    /// input method stops the main run loop as its replies arrive; when that is
    /// the outermost loop, the process exits with status zero mid-run. So no
    /// test in this process may suspend after an on-screen one, which is why
    /// the on-screen suites are named to sort, and so run, after the others.
    func settle() async throws {
        for _ in 0..<3 {
            if isOnScreen { spin(seconds: 0.02) } else { try await Task.sleep(for: .milliseconds(20)) }
            hosting?.layoutSubtreeIfNeeded()
        }
    }

    /// Settles past the circle's 0.2 s change of colour, before its pixels are read.
    func settleAnimation() async throws {
        for _ in 0..<5 { try await settle() }
    }

    /// Asks for activation until the window is key, for at most five seconds.
    func becomeKey() {
        for attempt in 0..<100 where window?.isKeyWindow == false {
            if attempt.isMultiple(of: 10) {
                NSApplication.shared.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
            }
            spin(seconds: 0.05)
        }
    }

    private func spin(seconds: TimeInterval) {
        let application = NSApplication.shared
        let deadline    = Date(timeIntervalSinceNow: seconds)
        while Date.now < deadline {
            RunLoop.current.run(mode: .default, before: deadline)
            while let event = application.nextEvent(matching: .any, until: .now, inMode: .default, dequeue: true) {
                application.sendEvent(event)
            }
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

    func pressReturn(option: Bool = false, shift: Bool = false) {
        var modifiers: NSEvent.ModifierFlags = []
        if option { modifiers.insert(.option) }
        if shift { modifiers.insert(.shift) }
        press("\r", keyCode: 36, modifiers: modifiers)
    }

    /// Tab, with Shift as the backtab character a keyboard produces for it.
    func pressTab(shift: Bool = false, control: Bool = false) {
        var modifiers: NSEvent.ModifierFlags = []
        if shift { modifiers.insert(.shift) }
        if control { modifiers.insert(.control) }
        press(shift ? "\u{19}" : "\t", keyCode: 48, modifiers: modifiers)
    }

    func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        guard let textView, let window,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: keyCode)
        else { return }
        if isOnScreen { window.sendEvent(event) } else { textView.keyDown(with: event) }
    }

    /// The circle as it is drawn: the box of accent-coloured pixels trailing the
    /// field, in window coordinates, and how many light pixels its glyph has,
    /// which tells the send arrow from the stop square. SwiftUI builds no
    /// accessibility tree in a test process, so the pixels are the measurement.
    func drawnCircle() -> (frame: NSRect, glyphPixels: Int)? {
        guard let hosting, let scrollView,
              let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
        else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        var accent: NSColor?
        hosting.effectiveAppearance.performAsCurrentDrawingAppearance {
            accent = NSColor.controlAccentColor.usingColorSpace(bitmap.colorSpace)
        }
        guard let accent else { return nil }
        let scale     = CGFloat(bitmap.pixelsWide) / hosting.bounds.width
        let fieldEnd  = Int((hosting.convert(scrollView.bounds, from: scrollView).maxX * scale).rounded(.up))
        var box       = (minX: Int.max, minY: Int.max, maxX: -1, maxY: -1)
        for y in 0..<bitmap.pixelsHigh {
            for x in fieldEnd..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y), Self.isClose(color, to: accent) else { continue }
                box = (min(box.minX, x), min(box.minY, y), max(box.maxX, x), max(box.maxY, y))
            }
        }
        guard box.maxX >= 0 else { return nil }
        var glyphPixels = 0
        for y in box.minY...box.maxY {
            for x in box.minX...box.maxX where Self.isLight(bitmap.colorAt(x: x, y: y)) {
                glyphPixels += 1
            }
        }
        // Bitmap rows run from the top; the hosting view's coordinates may not.
        let height = CGFloat(box.maxY - box.minY + 1) / scale
        let top    = CGFloat(box.minY) / scale
        let rect   = NSRect(x: CGFloat(box.minX) / scale,
                            y: hosting.isFlipped ? top : hosting.bounds.height - top - height,
                            width: CGFloat(box.maxX - box.minX + 1) / scale, height: height)
        return (hosting.convert(rect, to: nil), glyphPixels)
    }

    /// The box, in window coordinates, of what is drawn between two x positions
    /// within `row`'s height: pixels that differ from the surface at the left
    /// edge of that span. Nil when nothing is drawn there.
    func drawnMark(between minX: CGFloat, and maxX: CGFloat, alongside row: NSRect) -> NSRect? {
        guard let hosting, maxX - minX > 2,
              let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
        else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let scale  = CGFloat(bitmap.pixelsWide) / hosting.bounds.width
        let span   = hosting.convert(NSRect(x: minX + 1, y: row.minY, width: maxX - minX - 2, height: row.height),
                                     from: nil)
        let rows   = Int(span.minY * scale)..<Int(span.maxY * scale)
        let pixelsHigh = bitmap.pixelsHigh
        let top    = hosting.isFlipped ? rows : (pixelsHigh - rows.upperBound)..<(pixelsHigh - rows.lowerBound)
        let xs     = Int(span.minX * scale)..<Int(span.maxX * scale)
        guard let surface = bitmap.colorAt(x: xs.lowerBound, y: top.lowerBound) else { return nil }
        var box = (minX: Int.max, minY: Int.max, maxX: -1, maxY: -1)
        for y in top {
            for x in xs {
                guard let color = bitmap.colorAt(x: x, y: y), !Self.isClose(color, to: surface, within: 0.15)
                else { continue }
                box = (min(box.minX, x), min(box.minY, y), max(box.maxX, x), max(box.maxY, y))
            }
        }
        guard box.maxX >= 0 else { return nil }
        let height = CGFloat(box.maxY - box.minY + 1) / scale
        let rowTop = CGFloat(box.minY) / scale
        let rect   = NSRect(x: CGFloat(box.minX) / scale,
                            y: hosting.isFlipped ? rowTop : hosting.bounds.height - rowTop - height,
                            width: CGFloat(box.maxX - box.minX + 1) / scale, height: height)
        return hosting.convert(rect, to: nil)
    }

    private static func isLight(_ color: NSColor?) -> Bool {
        guard let color else { return false }
        return min(color.redComponent, color.greenComponent, color.blueComponent) > 0.9
    }

    private static func isClose(_ color: NSColor, to reference: NSColor, within tolerance: CGFloat = 0.06) -> Bool {
        abs(color.redComponent - reference.redComponent) < tolerance
            && abs(color.greenComponent - reference.greenComponent) < tolerance
            && abs(color.blueComponent - reference.blueComponent) < tolerance
    }

    /// Closes the window. On screen, the input method's last replies are
    /// absorbed by a nested run loop before the test returns.
    func close() {
        window?.close()
        guard isOnScreen else { return }
        spin(seconds: 0.2)
        Self.openOnScreen.subtract(1, ordering: .sequentiallyConsistent)
    }

    private func send() {
        guard let onSend else {
            sends += 1
            return
        }
        Task { await onSend(self) }
    }

    private static func find<View: NSView>(_ type: View.Type, in view: NSView) -> View? {
        if let found = view as? View { return found }
        for subview in view.subviews {
            if let found = find(type, in: subview) { return found }
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

        @State private var other = ""

        var body: some View {
            content
                .overlay(alignment: .bottom) {
                    VStack(spacing: 0) {
                        if harness.isOnScreen && !harness.showsTranscript {
                            TextField("After the composer", text: $other)
                        }
                        bar
                    }
                }
                .background(Color(nsColor: .windowBackgroundColor))
        }

        @ViewBuilder
        private var content: some View {
            if harness.showsTranscript {
                StandInTranscript()
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }

        private var bar: ComposerBar {
            var bar = ComposerBar(
                draft      : $harness.draft,
                recipient  : harness.recipient,
                canAnswer  : harness.canAnswer,
                isAnswering: harness.isAnswering,
                send       : { harness.send() },
                stop       : {
                    harness.stops      += 1
                    harness.isAnswering = false
                },
                release    : harness.holdsComputer ? {
                    harness.releases     += 1
                    harness.holdsComputer = false
                } : nil
            )
            bar.surface     = harness.surface
            // The circle is measured from what the view draws, and glass draws only in the window server.
            bar.buttonGlass = false
            return bar
        }
    }
}

/// Runs at exit, on no actor: a closure written inside the harness would be
/// main actor isolated, and its isolation check traps while the process ends.
private func failIfCutShort() {
    guard ComposerHarness.openOnScreen.load(ordering: .sequentiallyConsistent) > 0 else { return }
    fputs("ComposerTests: the process exited during a key window test; failing the run.\n", stderr)
    _exit(1)
}
