//
//  ComposerStripCancelButton.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/09/2026.
//

import SwiftUI

/// ComposerStripCancelButton is the × at the trailing end of a
/// `ComposerStrip`, which takes away what the strip says: a plain small cross
/// in the secondary colour, as quiet at rest as the text beside it, with a
/// round highlight under it only while the pointer is over it.
///
/// It is as wide as the composer's circle, so the cross sits right above the
/// circle's centre, and as tall as the strip's line.
struct ComposerStripCancelButton: View {

    private let help  : String
    private let label : String
    private let action: () -> Void

    @State private var isHovering = false

    /// - Parameters:
    ///   - help: the tooltip, a sentence saying what the click takes away.
    ///   - label: what VoiceOver reads, a title-case command.
    init(
        help  : String,
        label : String,
        action: @escaping () -> Void
    ) {
        self.help   = help
        self.label  = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(
                    size  : 10,
                    weight: .semibold
                ))
                .foregroundStyle(.secondary)
                .frame(
                    width : ComposerStrip<EmptyView>.controlHeight,
                    height: ComposerStrip<EmptyView>.controlHeight
                )
                .background {
                    Circle()
                        .fill(.quaternary)
                        .opacity(isHovering ? 1 : 0)
                }
                .frame(
                    width : ComposerBar.circleSide,
                    height: ComposerStrip<EmptyView>.controlHeight
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(label)
    }
}
