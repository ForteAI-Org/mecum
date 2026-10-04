//
//  NativeDeadKeySequence.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/10/2026.
//

import Carbon
import CoreGraphics
import Foundation

/// Resolves an actual Option dead key and commit key on the current source.
/// Carbon supplies the sequence only; each target row must observe native
/// preedit and commit after routed physical keys, without Unicode injection.
@MainActor
func nativeDeadKeySequence() -> (sourceID: String, dead: CGKeyCode, commit: CGKeyCode)? {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let rawID = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
          let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return nil }
    let sourceID = Unmanaged<CFString>.fromOpaque(rawID).takeUnretainedValue() as String
    let nativeData = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue()
    let count = CFDataGetLength(nativeData)
    guard count > 0, let bytes = CFDataGetBytePtr(nativeData) else { return nil }
    let data = Data(bytes: bytes, count: count)
    return data.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return nil }
        let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
        func translate(_ key: CGKeyCode, modifiers: UInt32, deadState: inout UInt32) -> String? {
            var length = 0
            var unicode = [UniChar](repeating: 0, count: 8)
            let status = UCKeyTranslate(
                layout,
                key,
                UInt16(kUCKeyActionDown),
                modifiers,
                UInt32(LMGetKbdType()),
                0,
                &deadState,
                unicode.count,
                &length,
                &unicode
            )
            guard status == noErr else { return nil }
            return String(
                utf16CodeUnits: unicode,
                count         : length
            )
        }
        for dead: CGKeyCode in 0..<128 {
            var initial: UInt32 = 0
            guard translate(dead, modifiers: UInt32(optionKey >> 8), deadState: &initial) == "",
                  initial != 0
            else { continue }
            for commit: CGKeyCode in 0..<128 {
                var state = initial
                if translate(commit, modifiers: 0, deadState: &state) == "é" {
                    return (sourceID, dead, commit)
                }
            }
        }
        return nil
    }
}

