//
//  HIDActuator.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import Carbon.HIToolbox
import CoreGraphics
import EngineCore
import Foundation

/// HIDActuator fills `Actuating` for the foreground: it posts synthetic events at the HID system tap,
/// so they land wherever the pointer and focus are, in whatever application is in front. The
/// process id is accepted for the role's contract and not used; a background seat fills the same
/// role by delivering to an adopted window instead.
///
/// A double click is click-count semantics, not two clicks: the second pair carries click state 2 or
/// the application reads two selections. Typed text goes one character per down and up pair with
/// empty modifier flags, because a synthetic event inherits the system's modifier state and a
/// chord left held turns "routing" into shortcuts. Every chord releases its modifiers on the way out.
/// An insertion is the whole string on one pair; a letter's chord asks the installed layout for its
/// key; a drag follows the path the Driver measured.
public struct HIDActuator: Actuating {

    public init() {}

    /// Events posted at the HID tap carry no receipt, so there is nothing to answer.
    public func confirm(_ effect: DeliveryEffect, in processID: pid_t) async {}

    public func perform(_ gesture: Gesture, in processID: pid_t) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else { throw HIDActuationFailure.noEventSource }
        switch gesture {
            case .click(let point, let button, let count):
                let (down, up, cgButton): (CGEventType, CGEventType, CGMouseButton) = button == .right
                    ? (.rightMouseDown, .rightMouseUp, .right)
                    : (.leftMouseDown, .leftMouseUp, .left)
                for clickState in 1...max(1, count) {
                    for type in [down, up] {
                        guard let event = CGEvent(
                            mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: cgButton
                        ) else {
                            throw HIDActuationFailure.eventCreationFailed
                        }
                        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
                        event.post(tap: .cghidEventTap)
                    }
                }
            case .scroll(let point, let deltaY, let deltaX):
                guard let event = CGEvent(
                    scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                    wheel1: Int32(deltaY), wheel2: Int32(deltaX), wheel3: 0
                ) else { throw HIDActuationFailure.eventCreationFailed }
                event.location = point
                event.post(tap: .cghidEventTap)
            case .key(let code, let modifiers):
                try pressKey(code, modifiers: modifiers, source: source)
            case .character(let character, let modifiers):
                guard let code = Self.virtualKey(producing: character, holdingCommand: modifiers.contains(.command))
                else { throw HIDActuationFailure.noKeyProduces(character) }
                try pressKey(code, modifiers: modifiers, source: source)
            case .type(let text):
                for character in text {
                    try postText(String(character), source: source)
                    try await Task.sleep(for: .milliseconds(9))
                }
            case .insert(let text):
                try postText(text, source: source)
            case .drag(let start, let end):
                try drag(from: start, to: end, source: source)
        }
    }

    /// One key down and up whose Unicode payload is `text`, with empty flags.
    private func postText(_ text: String, source: CGEventSource) throws {
        let units = Array(text.utf16)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else {
                throw HIDActuationFailure.eventCreationFailed
            }
            event.flags = []
            units.withUnsafeBufferPointer { buffer in
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            event.post(tap: .cghidEventTap)
        }
    }

    /// The path the Driver measured a drag to need: a move to the start, the press, eight dragged steps, the
    /// end held for one more step, the release, paced 24 ms, 16 ms and 12 ms a step. Paced by blocking, like a
    /// chord, so no cancellation can land between the press and the release.
    private func drag(from start: CGPoint, to end: CGPoint, source: CGEventSource) throws {
        func post(_ type: CGEventType, at point: CGPoint) throws {
            guard let event = CGEvent(
                mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left
            ) else { throw HIDActuationFailure.eventCreationFailed }
            event.post(tap: .cghidEventTap)
        }
        try post(.mouseMoved, at: start)
        usleep(24_000)
        try post(.leftMouseDown, at: start)
        // Once the press is out, the release follows whatever fails after it, so no button is left held.
        defer { try? post(.leftMouseUp, at: end) }
        usleep(16_000)
        for step in 1...8 {
            let progress = CGFloat(step) / 8
            try post(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * progress,
                                                    y: start.y + (end.y - start.y) * progress))
            usleep(12_000)
        }
        try post(.leftMouseDragged, at: end)
        usleep(12_000)
    }

    /// The virtual key the installed layout produces `character` from, asked of the layout the way a menu
    /// matches a key equivalent and never assumed from US positions: Command can select another
    /// arrangement, so it is asked with Command held when the chord holds it.
    private static func virtualKey(producing character: Character, holdingCommand: Bool) -> UInt16? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let wanted = Array(String(character).lowercased().utf16)
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        for code in UInt16(0)..<128 {
            var deadKeyState: UInt32 = 0
            var length = 0
            var produced = [UniChar](repeating: 0, count: 8)
            let status = UCKeyTranslate(
                layout, code, UInt16(kUCKeyActionDown), holdingCommand ? UInt32(cmdKey >> 8) : 0,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState,
                produced.count, &length, &produced
            )
            if status == noErr, Array(produced.prefix(length)) == wanted { return code }
        }
        return nil
    }

    private func pressKey(_ code: UInt16, modifiers: KeyModifiers, source: CGEventSource) throws {
        var flags: CGEventFlags = []
        var modifierKeys: [UInt16] = []
        if modifiers.contains(.command) { flags.insert(.maskCommand);   modifierKeys.append(55) }
        if modifiers.contains(.shift)   { flags.insert(.maskShift);     modifierKeys.append(56) }
        if modifiers.contains(.option)  { flags.insert(.maskAlternate); modifierKeys.append(58) }
        if modifiers.contains(.control) { flags.insert(.maskControl);   modifierKeys.append(59) }
        // Every event is posted even when one fails to build, so no modifier is ever left held.
        defer { releaseModifiers(source: source) }
        for key in modifierKeys {
            CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)?.post(tap: .cghidEventTap)
            usleep(20_000)
        }
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: isDown) else {
                throw HIDActuationFailure.eventCreationFailed
            }
            event.flags = flags
            event.post(tap: .cghidEventTap)
            if !modifierKeys.isEmpty { usleep(30_000) }
        }
        for key in modifierKeys.reversed() {
            CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)?.post(tap: .cghidEventTap)
            usleep(15_000)
        }
    }

    /// Posts an up event for every modifier, so a synthetic chord can never leave a phantom key held.
    private func releaseModifiers(source: CGEventSource) {
        for key: UInt16 in [55, 56, 58, 59] {
            CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)?.post(tap: .cghidEventTap)
        }
    }
}

/// HIDActuationFailure is the ways a synthetic event can fail to be made: the HID system refuses a
/// source or an event, or the installed layout has no key for a character.
public enum HIDActuationFailure: Error, Sendable, Equatable {
    case noEventSource
    case eventCreationFailed
    case noKeyProduces(Character)
}
