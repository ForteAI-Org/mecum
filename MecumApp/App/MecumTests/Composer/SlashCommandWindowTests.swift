//
//  SlashCommandWindowTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/09/2026.
//

import AppKit
import ChatCore
import Foundation
import ModelTransports
import Observation
import SeatBroker
import SwiftUI
import Synchronization
import Testing
@testable import Mecum

/// The conversation's composer over a `TeamModel`, Atlas on Claude's Sonnet
/// with one turn's usage, in a real key `NSWindow` on screen. Keys go through
/// `NSWindow.sendEvent(_:)`, as `ComposerWindowTests` sends them; clicks, and
/// the Escape the model popup watches for, are posted to the event loop, which
/// hands them to the popups' monitors first, as it does for a person's.
///
/// The window takes only the input the test sends it (`TestInputWindow`), so
/// a person typing or moving the pointer while the tests hold the focus
/// changes nothing in it.
///
/// A popup is found by what it draws: the window's background is magenta,
/// which no popup draws, and a popup is the box of pixels above the composer
/// with more green than it. A shadow only darkens the magenta, so it is not counted.
@MainActor
private final class Harness {

    @Observable
    final class Layout {

        var composerHeight: CGFloat = 0
    }

    let root  : URL
    let store : WorkspaceStore
    let team  : TeamModel
    let atlas : UUID
    let window: TestInputWindow
    let layout = Layout()

    private let preferences: UserDefaults
    private let suite      : String
    private var isClosed   = false

    /// The models Atlas's provider lists, in order.
    static let models = [
        ("claude-opus-5", "Claude Opus 5"),
        ("claude-sonnet-5", "Claude Sonnet 5"),
        ("claude-haiku-4-5", "Claude Haiku 4.5"),
    ]

    init() async throws {
        suite       = "mecum-command-window-\(UUID().uuidString)"
        preferences = try #require(UserDefaults(suiteName: suite))
        root        = URL.temporaryDirectory.appending(path: "mecum-command-window-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at                         : root,
            withIntermediateDirectories: true
        )
        // A command never reaches an agent; should a message be sent, this one answers nothing.
        let agent = root.appending(path: "agent")
        try Data("#!/bin/sh\nexec sleep 600\n".utf8).write(to: agent)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: agent.path
        )

        store = try WorkspaceStore.opening(in: root.appending(path: "store"))
        atlas = try await store.createWorker(
            name      : "Atlas",
            appearance: TemporaryStore.appearance()
        ).id
        try await store.configure(
            worker   : atlas,
            selection: ModelSelection(
                provider: .claudeCode,
                model   : "claude-sonnet-5",
                effort  : .low
            )
        )
        let conversation = try await store.createConversation(
            kind        : .direct,
            participants: [atlas]
        ).id
        try await store.append(NewEvent(
            workspaceID   : UUID(),
            subjectID     : UUID(),
            conversationID: conversation,
            workerID      : atlas,
            timestamp     : Date(),
            type          : .turnUsage,
            payload       : try TurnUsage(
                provider     : .claudeCode,
                model        : "claude-sonnet-5",
                session      : "window-session",
                turn         : ProviderUsage.Tokens(
                    input     : 142_000,
                    cacheReads: 0,
                    output    : 318,
                    reasoning : 0
                ),
                sessionTotal : nil,
                contextTokens: 142_318,
                contextWindow: 200_000,
                rateLimits   : []
            ).encoded()
        ))

        team = TeamModel(
            store           : store,
            connections     : ModelSettingsStore(),
            broker          : SeatBroker(),
            agents          : { _ in (.claude, agent) },
            bridgeExecutable: agent,
            preferences     : preferences
        )
        team.connections.recordCatalogue(
            Self.models.map { model in
                ModelInfo(
                    id     : model.0,
                    title  : model.1,
                    efforts: [.low, .medium, .high]
                )
            },
            for: .claudeCode
        )
        await team.load()
        team.selection = atlas
        await team.openSelectedConversation()

        window = TestInputWindow(
            contentRect: NSRect(
                x     : 200,
                y     : 200,
                width : 640,
                height: 480
            ),
            styleMask  : [.titled, .closable],
            backing    : .buffered,
            defer      : false
        )
        window.isReleasedWhenClosed = false
        window.appearance           = NSAppearance(named: .aqua)
        window.contentView          = NSHostingView(rootView: Root(
            team       : team,
            layout     : layout,
            preferences: preferences
        ))

        if ComposerHarness.openOnScreen.add(
            1,
            ordering: .sequentiallyConsistent
        ).oldValue == 0 {
            atexit(failIfCutShort)
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// A harness whose window is key with the keyboard in the field.
    static func keyWindow() async throws -> Harness {
        let harness = try await Harness()
        harness.becomeKey()
        try await harness.settle()
        harness.focus()
        try await harness.settle()
        // Another app can take the focus meanwhile, on a Mac someone is using; ask again.
        harness.becomeKey()
        try #require(harness.window.isKeyWindow)
        try #require(harness.window.firstResponder === harness.textView)
        try #require(harness.team.slashCommandContext?.showsRing == true)
        return harness
    }

    var textView: ComposerTextView? { window.contentView.flatMap { Self.find(ComposerTextView.self, in: $0) } }

    var isFieldFocused: Bool { window.firstResponder === textView }

    /// The rows the popup lists for the draft as it is.
    var titles: [String] {
        guard let context = team.slashCommandContext else { return [] }

        return SlashCommandSuggestions(
            draft  : team.draft,
            context: context
        ).rows.map(\.title)
    }

    /// What the person wrote in Atlas's conversation.
    func personMessages() async throws -> [String] {
        let conversation = try #require(try await store.conversations().first { $0.participantIDs == [atlas] })
        return try await store.messages(in: conversation.id)
            .filter { $0.authorWorkerID == nil }
            .map(\.text)
    }

    // MARK: Settling

    /// Lets SwiftUI apply what changed, and the event loop deliver what was posted.
    func settle() async throws {
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(20))
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    /// Settles past a popup's 0.2 s rise or sink.
    func settleAnimation() async throws {
        for _ in 0..<6 { try await settle() }
    }

    /// Waits until `condition` holds, five seconds at most.
    func wait(for condition: () async throws -> Bool) async throws {
        for _ in 0..<250 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(try await condition())
    }

    private func becomeKey() {
        for attempt in 0..<100 where !window.isKeyWindow {
            if attempt.isMultiple(of: 10) {
                NSApplication.shared.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
            spin(seconds: 0.05)
        }
    }

    private func focus() {
        guard let textView else { return }
        window.makeFirstResponder(textView)
    }

    private func spin(seconds: TimeInterval) {
        let application = NSApplication.shared
        let deadline    = Date(timeIntervalSinceNow: seconds)
        while Date.now < deadline {
            RunLoop.current.run(
                mode  : .default,
                before: deadline
            )
            while let event = application.nextEvent(
                matching: .any,
                until   : .now,
                inMode  : .default,
                dequeue : true
            ) {
                application.sendEvent(event)
            }
        }
    }

    // MARK: Keys

    /// Types `text` one key down per character, letters, spaces and the slash, and waits
    /// until the input context has handed all of it to the draft, which it may do later.
    func type(_ text: String) async throws {
        let expected = team.draft + text
        for character in text {
            press(
                String(character),
                keyCode: Self.keyCodes[character] ?? 0
            )
        }
        try await wait { team.draft == expected }
    }

    func pressDown() {
        press(
            "\u{F701}",
            keyCode  : 125,
            modifiers: [.numericPad, .function]
        )
    }

    func pressUp() {
        press(
            "\u{F700}",
            keyCode  : 126,
            modifiers: [.numericPad, .function]
        )
    }

    func pressTab() {
        press(
            "\t",
            keyCode: 48
        )
    }

    func pressReturn(shift: Bool = false) {
        press(
            "\r",
            keyCode  : 36,
            modifiers: shift ? .shift : []
        )
    }

    func pressEscape() {
        press(
            "\u{1b}",
            keyCode: 53
        )
    }

    /// Escape through the event loop, where a popup that closes on Escape watches for it.
    func postEscape() throws {
        NSApplication.shared.postEvent(
            try keyEvent(
                "\u{1b}",
                keyCode: 53
            ),
            atStart: false
        )
    }

    private func press(
        _ characters: String,
        keyCode     : UInt16,
        modifiers   : NSEvent.ModifierFlags = []
    ) {
        guard let event = try? keyEvent(
            characters,
            keyCode  : keyCode,
            modifiers: modifiers
        ) else { return }

        window.send(event)
    }

    private func keyEvent(
        _ characters: String,
        keyCode     : UInt16,
        modifiers   : NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with                       : .keyDown,
            location                   : .zero,
            modifierFlags              : modifiers,
            timestamp                  : ProcessInfo.processInfo.systemUptime,
            windowNumber               : window.windowNumber,
            context                    : nil,
            characters                 : characters,
            charactersIgnoringModifiers: characters,
            isARepeat                  : false,
            keyCode                    : keyCode
        ))
    }

    /// ANSI key codes, which the input source maps back to the character.
    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "c": 8, "v": 9, "b": 11, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "k": 40, "n": 45, "m": 46, " ": 49,
        "x": 7, "/": 44,
    ]

    // MARK: Clicks

    /// A click at `point`, in window coordinates, posted to the event loop.
    func click(at point: NSPoint) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApplication.shared.postEvent(
                try #require(NSEvent.mouseEvent(
                    with         : type,
                    location     : point,
                    modifierFlags: [],
                    timestamp    : ProcessInfo.processInfo.systemUptime,
                    windowNumber : window.windowNumber,
                    context      : nil,
                    eventNumber  : TestInputWindow.clickNumber,
                    clickCount   : 1,
                    pressure     : 1
                )),
                atStart: false
            )
        }
    }

    // MARK: Drawing

    /// The composer's top, in window coordinates.
    var composerTop: CGFloat { layout.composerHeight }

    /// The box, in window coordinates, of what a popup draws above the composer; nil while none is drawn.
    /// A pixel counts when it has more green than the background's corner. It is drawn into a bitmap
    /// of a known shape, 8-bit RGBA at twice the window's points, so its bytes can be read directly.
    func drawnPopup() throws -> NSRect? {
        let hosting = try #require(window.contentView)
        let bitmap  = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide      : Int(hosting.bounds.width * 2),
            pixelsHigh      : Int(hosting.bounds.height * 2),
            bitsPerSample   : 8,
            samplesPerPixel : 4,
            hasAlpha        : true,
            isPlanar        : false,
            colorSpaceName  : .deviceRGB,
            bytesPerRow     : 0,
            bitsPerPixel    : 0
        ))
        bitmap.size = hosting.bounds.size
        hosting.cacheDisplay(
            in: hosting.bounds,
            to: bitmap
        )
        let data        = try #require(bitmap.bitmapData)
        let bytesPerRow = bitmap.bytesPerRow
        let green       = { (pixel: Int) in Int(data[pixel + 1]) }

        let scale      = CGFloat(bitmap.pixelsWide) / hosting.bounds.width
        let height     = hosting.bounds.height
        let rows       = Int(((height - composerTop) * scale).rounded(.down))
        let background = green(0)
        var box        = (minX: Int.max, minY: Int.max, maxX: -1, maxY: -1)
        for y in 0..<rows {
            for x in 0..<bitmap.pixelsWide where green(y * bytesPerRow + x * 4) - background > 64 {
                if x < box.minX { box.minX = x }
                if x > box.maxX { box.maxX = x }
                if y < box.minY { box.minY = y }
                if y > box.maxY { box.maxY = y }
            }
        }
        guard box.maxX >= 0 else { return nil }

        // Bitmap rows run from the top, and the window's coordinates from the bottom.
        return NSRect(
            x     : CGFloat(box.minX) / scale,
            y     : height - CGFloat(box.maxY + 1) / scale,
            width : CGFloat(box.maxX - box.minX + 1) / scale,
            height: CGFloat(box.maxY - box.minY + 1) / scale
        )
    }

    /// The command popup's height with `rows` rows, which it grows by up to about eight.
    static func commandPopupHeight(rows: Int) -> CGFloat {
        2 * SlashCommandPopup.padding + CGFloat(rows) * SlashCommandRow.height
            + CGFloat(rows - 1) * SlashCommandPopup.rowSpacing
    }

    /// The middle of row `index` of `popup`, counted from its top, in window coordinates.
    static func row(
        _ index : Int,
        of popup: NSRect
    ) -> NSPoint {
        let step = SlashCommandRow.height + SlashCommandPopup.rowSpacing
        return NSPoint(
            x: popup.minX + 80,
            y: popup.maxY - SlashCommandPopup.padding - SlashCommandRow.height / 2 - CGFloat(index) * step
        )
    }

    // MARK: Closing

    /// Closes the window, once, and lets the input method's last replies arrive before the test goes on.
    func close() {
        guard !isClosed else { return }

        isClosed = true
        window.close()
        spin(seconds: 0.2)
        ComposerHarness.openOnScreen.subtract(
            1,
            ordering: .sequentiallyConsistent
        )
    }

    /// Closes the window first, so nothing drawn in it reads the store once it is gone.
    func discard() async {
        close()
        await team.closeAgentHosts()
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private static func find<View: NSView>(
        _ type : View.Type,
        in view: NSView
    ) -> View? {
        if let found = view as? View { return found }
        for subview in view.subviews {
            if let found = find(
                type,
                in: subview
            ) {
                return found
            }
        }
        return nil
    }

    /// The conversation's composer at the bottom of a magenta window, for the worker as the team has it now.
    private struct Root: View {

        let team: TeamModel

        @Bindable var layout: Layout

        let preferences: UserDefaults

        var body: some View {
            Group {
                if let worker = team.selectedWorker {
                    ConversationComposer(
                        team  : team,
                        worker: worker,
                        height: $layout.composerHeight
                    )
                }
            }
            .frame(
                maxWidth : .infinity,
                maxHeight: .infinity,
                alignment: .bottom
            )
            .background(
                Color(
                    red  : 1,
                    green: 0,
                    blue : 1
                )
            )
            .defaultAppStorage(preferences)
        }
    }
}

/// TestInputWindow is a key window that takes only the input its test sends:
/// the keys given to `send(_:)`, and the clicks posted with `clickNumber`.
/// Once the test app activates itself, the keys and the pointer of the person
/// using the Mac reach the window through the event loop, and they would type
/// into the field or move the popup's selection; every other key or pointer
/// event is dropped. Events of other kinds pass.
@MainActor
final class TestInputWindow: NSWindow {

    /// The event number of a test's clicks, which no event from the pointer carries.
    static let clickNumber = 0x7E57

    private var isSending = false

    /// Hands `event`, a key the test pressed, to the window as the event loop would.
    func send(_ event: NSEvent) {
        isSending = true
        defer { isSending = false }
        sendEvent(event)
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown, .keyUp, .flagsChanged:
            guard isSending else { return }

        case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp,
             .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged, .mouseMoved:
            guard event.eventNumber == Self.clickNumber else { return }

        case .mouseEntered, .mouseExited, .scrollWheel:
            return

        default:
            break
        }
        super.sendEvent(event)
    }
}

/// Runs at exit, on no actor: a closure written inside the harness would be
/// main actor isolated, and its isolation check traps while the process ends.
private func failIfCutShort() {
    guard ComposerHarness.openOnScreen.load(ordering: .sequentiallyConsistent) > 0 else { return }
    fputs(
        "SlashCommandWindowTests: the process exited during a key window test; failing the run.\n",
        stderr
    )
    _exit(1)
}

/// The composer's command popup, and its model popup, in real key windows.
/// Every check runs inside one test, each in a window of its own, for the
/// reason `ComposerWindowTests` gives: once the process has been active, the
/// input method can end it with status zero. The suite's name sorts after
/// that one's, and after every offscreen suite of this target.
@Suite("Composer in a key window, with its popups", .serialized)
@MainActor
struct SlashCommandWindowTests {

    @Test("The command popup's filter, keys, clicks and closing, and the model popup, in key windows")
    func keyWindows() async throws {
        try await filterMoveAndComplete()
        try await returnRunsOrWaits()
        try await escapeThenQuote()
        try await clicks()
        try await modelPopup()
    }

    /// `/co` opens the popup at the composer's leading edge with its two
    /// commands; ↓ moves, Tab completes, and `/model ` lists the models.
    private func filterMoveAndComplete() async throws {
        let harness  = try await Harness.keyWindow()
        defer { harness.close() }
        let textView = try #require(harness.textView)

        try await harness.type("/co")
        try await harness.settleAnimation()
        #expect(harness.titles == ["/compact", "/context"])
        let popup = try #require(try harness.drawnPopup())
        print("/co popup \(popup), composer top \(harness.composerTop)")
        #expect(abs(popup.minX - 16) <= 1.5)
        #expect(abs(popup.width - SlashCommandPopup.width) <= 1.5)
        #expect(abs(popup.minY - (harness.composerTop + 12)) <= 1.5)
        #expect(abs(popup.height - Harness.commandPopupHeight(rows: 2)) <= 1.5)
        #expect(harness.isFieldFocused)

        harness.pressDown()
        harness.pressTab()
        // The draft changes at once; the field takes it on SwiftUI's next update.
        try await harness.wait { textView.string == "/context" }
        #expect(harness.team.draft == "/context", "↓ moved to the second row, and Tab put it in the draft")
        #expect(textView.selectedRange() == NSRange(
            location: 8,
            length  : 0
        ))

        harness.team.draft = ""
        try await harness.settleAnimation()
        #expect(try harness.drawnPopup() == nil)

        try await harness.type("/mo")
        harness.pressTab()
        try await harness.wait { harness.team.draft == "/model " }
        try await harness.settleAnimation()
        #expect(harness.titles == Harness.models.map(\.1))
        let models = try #require(try harness.drawnPopup())
        #expect(abs(models.height - Harness.commandPopupHeight(rows: 3)) <= 1.5)

        // ↑ from the first row wraps to the last.
        harness.pressDown()
        harness.pressUp()
        harness.pressUp()
        harness.pressTab()
        try await harness.wait { harness.team.draft == "/model claude-haiku-4-5" }
        #expect(harness.isFieldFocused)
        await harness.discard()
    }

    /// Return does nothing on a row that cannot run, `/stop` while Atlas is idle
    /// among them, and runs an available row through the send path;
    /// Shift-Return still breaks the line.
    private func returnRunsOrWaits() async throws {
        let harness = try await Harness.keyWindow()
        defer { harness.close() }

        // `/stop` while Atlas is idle does not apply, and says why.
        try await harness.type("/stop")
        try await harness.settleAnimation()
        #expect(harness.titles == ["/stop"])
        #expect(try harness.drawnPopup() != nil)
        harness.pressReturn()
        try await harness.settleAnimation()
        #expect(harness.team.draft == "/stop")
        #expect(try harness.drawnPopup() != nil)
        harness.team.draft = ""
        try await harness.settleAnimation()

        try await harness.type("/mo")
        harness.pressTab()
        try await harness.wait { harness.team.draft == "/model " }
        harness.pressReturn()
        try await harness.wait { harness.team.worker(harness.atlas)?.configuration?.model == "claude-opus-5" }
        #expect(harness.team.draft.isEmpty)
        try await harness.settleAnimation()
        #expect(try harness.drawnPopup() == nil)

        try await harness.type("/compact now")
        try await harness.settleAnimation()
        #expect(harness.titles == ["/compact"])
        #expect(try harness.drawnPopup() != nil, "a command given an argument it cannot take still shows")
        harness.pressReturn()
        try await harness.settleAnimation()
        #expect(harness.team.draft == "/compact now")
        #expect(!harness.team.isCompacting(harness.atlas))

        harness.pressReturn(shift: true)
        try await harness.wait { harness.team.draft == "/compact now\n" }
        #expect(try await harness.personMessages().isEmpty)
        #expect(harness.isFieldFocused)
        await harness.discard()
    }

    /// A first Escape closes the popup and keeps the reply's quote; the next
    /// drops the quote, as Escape always did; typing opens the popup again.
    private func escapeThenQuote() async throws {
        let harness = try await Harness.keyWindow()
        defer { harness.close() }
        let quote   = MessageQuote(
            messageID     : UUID(),
            authorWorkerID: nil,
            text          : "Rerun the capture suite."
        )
        harness.team.draftQuote = quote
        try await harness.settle()

        try await harness.type("/co")
        try await harness.settleAnimation()
        #expect(harness.team.draft == "/co")
        #expect(try harness.drawnPopup() != nil)

        harness.pressEscape()
        try await harness.wait { try harness.drawnPopup() == nil }
        #expect(harness.team.draftQuote == quote)
        #expect(harness.team.draft == "/co")

        harness.pressEscape()
        try await harness.wait { harness.team.draftQuote == nil }

        try await harness.type("m")
        try await harness.settleAnimation()
        #expect(try harness.drawnPopup() != nil)
        #expect(harness.isFieldFocused)
        await harness.discard()
    }

    /// A click outside closes the popup and leaves the draft; a click on a row
    /// does what Return does, and the keyboard stays in the field.
    private func clicks() async throws {
        let harness = try await Harness.keyWindow()
        defer { harness.close() }

        try await harness.type("/")
        try await harness.settleAnimation()
        let all = try #require(try harness.drawnPopup())
        try harness.click(at: NSPoint(
            x: 600,
            y: all.maxY + 20
        ))
        try await harness.settleAnimation()
        #expect(try harness.drawnPopup() == nil)
        #expect(harness.team.draft == "/")
        #expect(harness.isFieldFocused)

        try await harness.type("n")
        try await harness.settleAnimation()
        #expect(harness.titles == ["/new", "/context"])
        let popup = try #require(try harness.drawnPopup())
        try harness.click(at: Harness.row(
            0,
            of: popup
        ))
        try await harness.wait { harness.team.draft.isEmpty }
        let conversation = try #require(try await harness.store.conversations().first {
            $0.participantIDs == [harness.atlas]
        })
        try await harness.wait {
            try await harness.store.events(matching: EventQuery(scope: .conversation(conversation.id)))
                .contains { $0.type == .contextReset }
        }
        #expect(harness.isFieldFocused, "the popup never takes the keyboard")
        #expect(try await harness.personMessages().isEmpty)
        await harness.discard()
    }

    /// `/model` alone opens the model popup, which sits over the composer's
    /// trailing side, closes on Escape wherever the keyboard is, and on a click outside.
    private func modelPopup() async throws {
        let harness = try await Harness.keyWindow()
        defer { harness.close() }

        try await harness.type("/model")
        harness.pressReturn()
        try await harness.wait { harness.team.modelPopupRequest == 1 }
        try await harness.settleAnimation()
        #expect(harness.team.draft.isEmpty)
        let popup = try #require(try harness.drawnPopup())
        print("model popup \(popup), composer top \(harness.composerTop)")
        #expect(abs(popup.width - ConversationModelPopup.width) <= 1.5)
        #expect(abs(popup.maxX - (640 - 16)) <= 1.5, "centred on the button, kept inside the composer")
        #expect(abs(popup.minY - (harness.composerTop + 12)) <= 1.5)

        try harness.postEscape()
        try await harness.settleAnimation()
        #expect(try harness.drawnPopup() == nil)

        harness.team.modelPopupRequest += 1
        try await harness.settleAnimation()
        let again = try #require(try harness.drawnPopup())
        try harness.click(at: NSPoint(
            x: 40,
            y: again.maxY + 20
        ))
        try await harness.settleAnimation()
        #expect(try harness.drawnPopup() == nil)
        #expect(harness.isFieldFocused)
        await harness.discard()
    }
}
