//
//  TestInputWindow.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/09/2026.
//

import AppKit

/// TestInputWindow is a key window that takes only the input its test sends:
/// the keys given to `send(_:)` or `sendThroughApplication(_:)`, and the clicks
/// posted with `clickNumber`. Once the test app activates itself, the keys and
/// the pointer of the person using the Mac reach the window through the event
/// loop, and they would type into the field or move the popup's selection;
/// every other key or pointer event is dropped, key equivalents included.
/// Events of other kinds pass.
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

    /// Hands `event`, a key the test pressed, to the application, which offers it
    /// to the key window's key equivalents, the buttons' shortcuts among them, first.
    func sendThroughApplication(_ event: NSEvent) {
        isSending = true
        defer { isSending = false }
        NSApplication.shared.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isSending else { return false }

        return super.performKeyEquivalent(with: event)
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
