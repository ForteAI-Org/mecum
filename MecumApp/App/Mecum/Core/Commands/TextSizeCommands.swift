//
//  TextSizeCommands.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI
import Transcript

/// TextSizeCommands is View > Bigger, Smaller and Actual Size for the
/// conversation body (§3.3), with the shortcuts every Mac text app uses.
///
/// The size is remembered for the app, not per window, like a reading
/// preference: every transcript reads the same stored value. The steps and
/// their ends are `TranscriptStyle`'s, so a command that has nowhere to go is
/// disabled rather than silently doing nothing.
struct TextSizeCommands: Commands {

    static let storageKey = "transcript.bodyPointSize"

    @AppStorage(storageKey)
    private var bodyPointSize = Double(TranscriptStyle.actualSize.bodyPointSize)

    private var style: TranscriptStyle { TranscriptStyle(bodyPointSize: CGFloat(bodyPointSize)) }

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button("Bigger") { set(style.bigger) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(style.bigger == nil)
            Button("Smaller") { set(style.smaller) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(style.smaller == nil)
            Button("Actual Size") { set(.actualSize) }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(style == .actualSize)
            Divider()
        }
    }

    private func set(_ next: TranscriptStyle?) {
        guard let next else { return }
        bodyPointSize = Double(next.bodyPointSize)
    }
}
