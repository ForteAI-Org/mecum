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
import Testing
@testable import Mecum

/// ComposerHarness hosts a `ComposerBar` in SwiftUI, floating over the bottom
/// of a stand-in transcript, and plays the model's part: it owns the draft,
/// counts sends and records every value the draft took, so a test can say what
/// reached the draft path and not only what the field shows.
///
/// Offscreen, the window is borderless and never ordered in, and keys are real
/// `NSEvent` key downs through the text view's `keyDown(with:)`. On screen, the
/// window is a titled window made key, keys go through `NSWindow.sendEvent(_:)`
/// as the event loop delivers them, and a second field after the composer gives
/// the key view loop somewhere to go. The window takes only the input the test
/// sends it (`TestInputWindow`), so a person typing or moving the pointer while
/// the tests hold the focus changes nothing in it.
@Observable
@MainActor
final class ComposerHarness {

    var draft = "" { didSet { drafts.append(draft) } }
    var isAnswering = false
    var canAnswer   = true
    var stops       = 0

    /// The words a reply strip quotes above the pill, nil for no strip. Escape
    /// in the field takes it away, as the conversation's composer does.
    var quote: String?

    /// The queued messages a queue strip shows above the reply strip, none for no strip.
    var queued: [String] = []

    /// Whether Return during a turn hands the draft to Send, as a composer that queues does.
    var queues = false

    /// Whether Return sends, or starts a new line with Command-Return sending.
    var returnSends = true

    /// The bar's height as SwiftUI laid it out, strip included.
    private(set) var barHeight: CGFloat = 0

    /// Moved by a test to ask the bar to put the keyboard in its field.
    var focusRequest = 0

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
    private(set) var window: TestInputWindow?

    let recipient: String
    let surface  : ComposerSurface.Kind?
    let isOnScreen: Bool

    /// On-screen harnesses not yet closed. The input method can end a test
    /// process with status zero mid-run; an exit while one is open becomes
    /// status one, so a run cut short never reads as a pass.
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
        let window  = TestInputWindow(
            contentRect: frame,
            styleMask  : onScreen ? [.titled, .closable] : [.borderless],
            backing    : .buffered,
            defer      : false
        )
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
            window.undoManager?.groupsByEvent = false
        }
        self.window = window
    }

    var hosting: NSView? { window?.contentView }

    var scrollView: ComposerScrollView? { hosting.flatMap { Self.find(ComposerScrollView.self, in: $0) } }

    var textView: ComposerTextView? { scrollView?.textView }

    /// Lets SwiftUI apply what changed, then lays the window out.
    ///
    /// It suspends, so the event loop of the app hosting the tests turns: it
    /// delivers what the window server queued, activation included, and closes
    /// the undo group the keys since the last settle opened, as it does between
    /// the keys a person presses.
    func settle() async throws {
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(20))
            hosting?.layoutSubtreeIfNeeded()
        }
    }

    /// Settles past the circle's 0.2 s change of colour, before its pixels are read.
    func settleAnimation() async throws {
        for _ in 0..<5 { try await settle() }
    }

    /// Waits until `condition` holds, five seconds at most, laying the window out between tries.
    func wait(
        sourceLocation: SourceLocation = #_sourceLocation,
        for condition : () throws -> Bool
    ) async throws {
        for _ in 0..<250 {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(20))
            hosting?.layoutSubtreeIfNeeded()
        }
        try #require(
            try condition(),
            "draft \(draft.debugDescription), field \((textView?.string ?? "").debugDescription)",
            sourceLocation: sourceLocation
        )
    }

    /// Waits until the circle is drawn at its full side, its pixels as they were on the try before,
    /// so no change of colour or glyph is under way, and `condition` holds for it; then returns it.
    func waitForCircle(
        sourceLocation : SourceLocation = #_sourceLocation,
        where condition: ((frame: NSRect, glyphPixels: Int)) -> Bool = { _ in true }
    ) async throws -> (frame: NSRect, glyphPixels: Int) {
        var found : (frame: NSRect, glyphPixels: Int)?
        var pixels: Data?
        try await wait(sourceLocation: sourceLocation) {
            let last = pixels
            found    = drawnCircle()
            pixels   = found.flatMap { drawnPixels(in: $0.frame.insetBy(dx: -2, dy: -2)) }
            guard let circle = found, pixels != nil, pixels == last else { return false }

            return abs(circle.frame.width - ComposerBar.circleSide) <= 1
                && abs(circle.frame.height - ComposerBar.circleSide) <= 1
                && condition(circle)
        }
        return try #require(found)
    }

    /// The bytes drawn inside `rect`, in window coordinates, row by row, to tell whether a region still changes.
    private func drawnPixels(in rect: NSRect) -> Data? {
        guard let hosting,
              let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
        else { return nil }

        hosting.cacheDisplay(
            in: hosting.bounds,
            to: bitmap
        )
        guard let data = bitmap.bitmapData else { return nil }

        let scale  = CGFloat(bitmap.pixelsWide) / hosting.bounds.width
        let span   = hosting.convert(rect, from: nil)
        let top    = hosting.isFlipped ? span.minY : hosting.bounds.height - span.maxY
        let rows   = max(Int(top * scale), 0)..<min(Int((top + span.height) * scale), bitmap.pixelsHigh)
        let offset = max(Int(span.minX * scale), 0) * bitmap.bitsPerPixel / 8
        let length = min(Int(span.width * scale), bitmap.pixelsWide) * bitmap.bitsPerPixel / 8
        var bytes  = Data()
        for row in rows {
            bytes.append(
                data + row * bitmap.bytesPerRow + offset,
                count: min(length, bitmap.bytesPerRow - offset)
            )
        }
        return bytes
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
              let event = keyEvent(
                  characters,
                  keyCode  : keyCode,
                  modifiers: modifiers
              )
        else { return }
        guard isOnScreen else { return textView.keyDown(with: event) }

        // Each key is one undo group, as the event loop of an app makes it; the loop running the tests
        // closes none, so the window's undo manager groups by hand (see `init`).
        window.undoManager?.beginUndoGrouping()
        window.send(event)
        window.undoManager?.endUndoGrouping()
    }

    /// Presses a key through the application, which offers it to the buttons' shortcuts before
    /// the field, as it does a person's. The application hands keys only to its key window, so
    /// the window is made key again first, should another app have taken the focus meanwhile.
    func pressThroughApplication(
        _ characters: String,
        keyCode     : UInt16,
        modifiers   : NSEvent.ModifierFlags
    ) throws {
        becomeKey()
        let window = try #require(window)
        try #require(
            window.isKeyWindow,
            "another app holds the focus"
        )
        window.sendThroughApplication(try #require(keyEvent(
            characters,
            keyCode  : keyCode,
            modifiers: modifiers
        )))
    }

    private func keyEvent(
        _ characters: String,
        keyCode     : UInt16,
        modifiers   : NSEvent.ModifierFlags
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with                       : .keyDown,
            location                   : .zero,
            modifierFlags              : modifiers,
            timestamp                  : ProcessInfo.processInfo.systemUptime,
            windowNumber               : window?.windowNumber ?? 0,
            context                    : nil,
            characters                 : characters,
            charactersIgnoringModifiers: characters,
            isARepeat                  : false,
            keyCode                    : keyCode
        )
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
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { harness.barHeight = $0 }
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
                .sendsOnReturn(harness.returnSends)
                .queuesWhileAnswering(harness.queues)
                .onEscape(harness.quote == nil ? nil : { harness.quote = nil })
                .focusRequest(harness.focusRequest)
                .strip {
                    VStack(spacing: 0) {
                        if !harness.queued.isEmpty {
                            ConversationQueueStrip(
                                queue      : harness.queued.map { QueuedMessage(text: $0) },
                                shown      : 0,
                                isAnswering: harness.isAnswering,
                                next       : {},
                                sendNow    : {},
                                edit       : {},
                                remove     : {}
                            )
                        }
                        if let quote = harness.quote {
                            ComposerStrip(
                                symbol           : "arrowshape.turn.up.left",
                                title            : "Atlas",
                                text             : quote,
                                accessibilityText: quote,
                                roundsTop        : harness.queued.isEmpty,
                                open             : {}
                            ) {
                                ComposerStripCancelButton(
                                    help  : "Don’t reply to this message.",
                                    label : "Cancel Reply",
                                    action: { harness.quote = nil }
                                )
                            }
                        }
                    }
                }
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
