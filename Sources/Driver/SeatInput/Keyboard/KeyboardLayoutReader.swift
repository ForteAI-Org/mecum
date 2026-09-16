//
//  KeyboardLayoutReader.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

import Carbon.HIToolbox
import CoreGraphics
import Foundation
import SeatCore
import Synchronization

/// KeyboardLayoutReader asks the system which keyboard layout is installed and
/// turns it into a `KeyboardLayout` value.
///
/// It uses documented public Carbon calls, `TISCopyCurrentKeyboardLayoutInputSource`
/// and `UCKeyTranslate`, so there is no private primitive here and nothing to
/// promote into the Ledger. It can answer nil when the current input source has
/// no Unicode layout data. `TISCopyCurrentKeyboardLayoutInputSource` can also
/// return the underlying layout for an input method, so nil is a property of
/// the source data, not a classification of every input method. A character
/// Shortcut without a layout is refused rather than guessed.
///
/// The generation is derived rather than observed. Watching
/// `kTISNotifySelectedKeyboardInputSourceChanged` would need a run loop, an
/// observer and its teardown, and it would answer the same question this
/// answers by comparing one reading with the last. Exact source bytes are
/// compared with SIMD before translation, so an unchanged source reuses its
/// translated rows and a same-id edit still advances the generation.
nonisolated public enum KeyboardLayoutReader {

    /// The process-wide lock serializes source capture, translation and cache
    /// publication. This makes generation order match completed system reads
    /// and prevents an older concurrent read from replacing a newer entry.
    private static let cache = Mutex(KeyboardLayoutCache())

    /// The layout installed right now, or nil when the current input source
    /// publishes no Unicode layout data.
    public static func current() -> KeyboardLayout? {
        cache.withLock { cache in
            guard
                let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
                let identity = property(of: inputSource, kTISPropertyInputSourceID) as String?,
                let layoutData = layoutData(of: inputSource)
            else {
                return cache.layout(for: nil, translating: Self.translate)
            }
            let source = KeyboardLayoutSource(
                inputSourceID: identity,
                layoutData   : layoutData,
                keyboardType : UInt32(LMGetKbdType())
            )
            return cache.layout(for: source, translating: Self.translate)
        }
    }

    private static func property(
        of source: TISInputSource,
        _ key    : CFString
    ) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    private static func layoutData(of source: TISInputSource) -> Data? {
        guard
            let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return nil
        }
        let data  = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        let count = CFDataGetLength(data)
        guard count > 0, let bytes = CFDataGetBytePtr(data) else { return nil }
        return Data(bytes: bytes, count: count)
    }

    /// The four source rows a character Shortcut can use. Command may select a
    /// different arrangement, and Shift supplies symbols only after a base
    /// character lookup misses. Option and Control change produced text, not
    /// the physical key a Shortcut names, so they stay on event flags and are
    /// deliberately not translated as identity rows.
    private static let sourceRows: [Modifiers] = [
        [], .shift, .command, [.command, .shift],
    ]

    /// Every position this table names, asked on each source row. Only the
    /// positions in `KeyNames` are asked, so the answer is bounded by the kit's
    /// own table rather than by a sweep of 0 to 127.
    private static func translate(
        _ layoutData : Data,
        _ keyboardType: UInt32
    ) -> [Modifiers: [CGKeyCode: Character]] {
        layoutData.withUnsafeBytes { buffer -> [Modifiers: [CGKeyCode: Character]] in
            guard let base = buffer.baseAddress else { return [:] }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)

            var rows: [Modifiers: [CGKeyCode: Character]] = [:]
            for modifiers in sourceRows {
                var characters: [CGKeyCode: Character] = [:]
                characters.reserveCapacity(KeyNames.all.count)

                for key in KeyNames.all {
                    var deadKeyState: UInt32 = 0
                    var length                = 0
                    var unicode               = [UniChar](repeating: 0, count: 8)

                    let status = UCKeyTranslate(
                        layout,
                        UInt16(key.virtualKey),
                        UInt16(kUCKeyActionDown),
                        modifierState(for: modifiers),
                        keyboardType,
                        OptionBits(kUCKeyTranslateNoDeadKeysMask),
                        &deadKeyState,
                        unicode.count,
                        &length,
                        &unicode
                    )
                    guard status == noErr, length > 0 else { continue }
                    let produced = String(utf16CodeUnits: unicode, count: length)
                    // A position that produces a control character, Return and
                    // Tab and Escape among them, is reached as a position.
                    guard produced.count == 1,
                          let character = produced.first,
                          !character.isControlOrSpace
                    else {
                        continue
                    }
                    characters[key.virtualKey] = character
                }
                rows[modifiers] = characters
            }
            return rows
        }
    }

    /// Converts the only two modifier bits that select one of `sourceRows` to
    /// Carbon's legacy eight-bit `UCKeyTranslate` modifier state.
    private static func modifierState(for modifiers: Modifiers) -> UInt32 {
        var state: UInt32 = 0
        if modifiers.contains(.command) { state |= UInt32(cmdKey >> 8) }
        if modifiers.contains(.shift) { state |= UInt32(shiftKey >> 8) }
        return state
    }
}

nonisolated private extension Character {

    /// Whether this character is one a Shortcut is never written with. Space is
    /// in the list beside the control characters because the key that produces
    /// it is named as a position, `Space`, and a shortcut written with a literal
    /// blank would be unreadable at the call site.
    var isControlOrSpace: Bool {
        unicodeScalars.allSatisfy { CharacterSet.controlCharacters.contains($0) }
            || self == " "
    }
}
