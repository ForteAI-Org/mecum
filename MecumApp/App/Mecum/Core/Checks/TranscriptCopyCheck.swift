//
//  TranscriptCopyCheck.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import SwiftUI
import TeamShell

/// TranscriptCopyCheck shows the team shell in a real key window when the app
/// is launched with MECUM_WINDOW_CHECK=copy, focuses the composer, drags across
/// a reply with real mouse events, then copies through the app's own Edit
/// menu, by its Copy item and by its Command C key equivalent. It prints each
/// step and quits with 0 when both copies put the dragged text on the
/// pasteboard, 1 otherwise.
///
/// The team is `WindowSnapshots`'s synthetic one, in a temporary store; the
/// person's workspace is never opened. The general pasteboard's contents are
/// saved before the check and put back after it.
@MainActor
enum TranscriptCopyCheck {

    static var isRequested: Bool { ProcessInfo.processInfo.environment["MECUM_WINDOW_CHECK"] == "copy" }

    static func runAndQuit() async {
        let store = URL.temporaryDirectory.appending(
            path         : "MecumCopyCheck-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let pasteboard = NSPasteboard.general
        let saved      = pasteboard.pasteboardItems?.map(Self.copy) ?? []
        var status: Int32 = 1

        do {
            let team = try await WindowSnapshots.syntheticTeam(in: store)
            status = try await check(team) ? 0 : 1
        } catch {
            FileHandle.standardError.write(Data("copy check failed: \(error)\n".utf8))
        }

        pasteboard.clearContents()
        pasteboard.writeObjects(saved)
        // A leftover temporary store is reclaimed by the system; it must not change the exit status.
        do { try FileManager.default.removeItem(at: store) } catch {}
        exit(status)
    }

    private static func check(_ team: TeamModel) async throws -> Bool {
        let hosting = NSHostingView(rootView: WindowSnapshots.Root(
            team                : team,
            isInspectorRequested: false
        ))
        hosting.sceneBridgingOptions = [.toolbars, .title]

        let window = NSWindow(
            contentRect: NSRect(
                x     : 120,
                y     : 120,
                width : 1000,
                height: 640
            ),
            styleMask  : [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing    : .buffered,
            defer      : false
        )
        window.isReleasedWhenClosed = false
        window.contentView          = hosting
        window.makeKeyAndOrderFront(nil)

        // An inactive app takes a click as the one that activates it, so the check waits to be active.
        for _ in 0..<10 where !NSApp.isActive {
            NSApp.activate()
            try await Task.sleep(for: .seconds(1))
        }
        try await Task.sleep(for: .seconds(2))
        defer { window.close() }
        print("copy check: active \(NSApp.isActive), key \(window.isKeyWindow), "
              + "first responder \(describe(window.firstResponder))")

        let transcript = firstView(
            in   : hosting,
            named: "TranscriptCollectionView"
        ) as? NSCollectionView
        guard let transcript,
              let reply = transcript.visibleItems().first(where: {
                  $0.view.accessibilityLabel()?.hasPrefix("Atlas,") == true
              })?.view
        else {
            print("copy check: no transcript or reply on screen")
            return false
        }

        // The person was typing: the composer holds the keyboard when the reply is dragged across.
        let composer = firstView(
            in   : hosting,
            where: { $0 is NSTextView }
        )
        if let composer { window.makeFirstResponder(composer) }
        print("copy check: before the drag, first responder \(describe(window.firstResponder))")

        // The reply's last line sits above its bubble's bottom padding and the time line under the bubble.
        let line  = reply.isFlipped ? reply.bounds.height - 34 : 34
        let start = reply.convert(
            NSPoint(
                x: 70,
                y: line
            ),
            to: nil
        )
        let end   = reply.convert(
            NSPoint(
                x: 320,
                y: line
            ),
            to: nil
        )
        window.sendEvent(try mouse(
            .leftMouseDown,
            start,
            window
        ))
        for step in 1...5 {
            let x = start.x + (end.x - start.x) * CGFloat(step) / 5
            window.sendEvent(try mouse(
                .leftMouseDragged,
                NSPoint(
                    x: x,
                    y: start.y
                ),
                window
            ))
        }
        window.sendEvent(try mouse(
            .leftMouseUp,
            end,
            window
        ))
        print("copy check: after the drag, first responder \(describe(window.firstResponder))")

        guard let edit = NSApp.mainMenu?.items.compactMap(\.submenu).first(where: { menu in
                  menu.items.contains { $0.action == #selector(NSText.copy(_:)) }
              }),
              let copyIndex = edit.items.firstIndex(where: { $0.action == #selector(NSText.copy(_:)) })
        else {
            print("copy check: the main menu has no Copy item")
            return false
        }

        let item = edit.items[copyIndex]
        edit.update()
        let target = NSApp.target(
            forAction: #selector(NSText.copy(_:)),
            to       : nil,
            from     : item
        )
        print("copy check: Edit menu '\(edit.title)', item '\(item.title)' key '\(item.keyEquivalent)', "
              + "enabled \(item.isEnabled), target \(describe(target))")

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        edit.performActionForItem(at: copyIndex)
        let byItem = pasteboard.string(forType: .string)
        print("copy check: Edit > Copy put \(byItem.map { "\"\($0)\"" } ?? "nothing")")

        pasteboard.clearContents()
        let key = try require(NSEvent.keyEvent(
            with                       : .keyDown,
            location                   : .zero,
            modifierFlags              : .command,
            timestamp                  : ProcessInfo.processInfo.systemUptime,
            windowNumber               : window.windowNumber,
            context                    : nil,
            characters                 : "c",
            charactersIgnoringModifiers: "c",
            isARepeat                  : false,
            keyCode                    : 8
        ))
        let handled = NSApp.mainMenu?.performKeyEquivalent(with: key) ?? false
        let byKey   = pasteboard.string(forType: .string)
        print("copy check: Command C handled by the menu \(handled), put \(byKey.map { "\"\($0)\"" } ?? "nothing")")

        let passed = byItem?.isEmpty == false && byKey == byItem
        print("copy check: \(passed ? "passed" : "failed")")
        return passed
    }

    // MARK: Helpers

    private struct Missing: Error {}

    private static func require<Value>(_ value: Value?) throws -> Value {
        guard let value else { throw Missing() }

        return value
    }

    private static func mouse(
        _ type  : NSEvent.EventType,
        _ point : NSPoint,
        _ window: NSWindow
    ) throws -> NSEvent {
        try require(NSEvent.mouseEvent(
            with         : type,
            location     : point,
            modifierFlags: [],
            timestamp    : ProcessInfo.processInfo.systemUptime,
            windowNumber : window.windowNumber,
            context      : nil,
            eventNumber  : 0,
            clickCount   : 1,
            pressure     : type == .leftMouseUp ? 0 : 1
        ))
    }

    private static func firstView(
        in view   : NSView,
        named name: String
    ) -> NSView? {
        firstView(in: view) { String(describing: type(of: $0)) == name }
    }

    private static func firstView(
        in view      : NSView,
        where matches: (NSView) -> Bool
    ) -> NSView? {
        if matches(view) { return view }

        for subview in view.subviews {
            if let found = firstView(
                in   : subview,
                where: matches
            ) {
                return found
            }
        }
        return nil
    }

    private static func describe(_ object: Any?) -> String {
        object.map { String(describing: type(of: $0)) } ?? "none"
    }

    private static func copy(_ item: NSPasteboardItem) -> NSPasteboardItem {
        let copy = NSPasteboardItem()
        for type in item.types {
            if let data = item.data(forType: type) {
                copy.setData(
                    data,
                    forType: type
                )
            }
        }
        return copy
    }
}
