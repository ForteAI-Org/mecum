//
//  HIDActuator.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

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
public struct HIDActuator: Actuating {

    public init() {}

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
            case .type(let text):
                for character in text {
                    let units = Array(String(character).utf16)
                    for isDown in [true, false] {
                        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else {
                            throw HIDActuationFailure.eventCreationFailed
                        }
                        event.flags = []
                        units.withUnsafeBufferPointer { buffer in
                            event.keyboardSetUnicodeString(
                                stringLength: buffer.count, unicodeString: buffer.baseAddress
                            )
                        }
                        event.post(tap: .cghidEventTap)
                    }
                    try await Task.sleep(for: .milliseconds(9))
                }
        }
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

/// HIDActuationFailure is the two ways the HID system can refuse a synthetic event.
public enum HIDActuationFailure: Error, Sendable, Equatable {
    case noEventSource
    case eventCreationFailed
}
