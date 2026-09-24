//
//  ConnectionStateBadge.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import ModelTransports
import SwiftUI

/// ConnectionStateBadge is a connection's state without words: a green dot
/// when it works, the trouble's symbol when it does not, grey for a missing
/// credential, orange for a usage limit and red for the rest, and a quiet
/// dot while it is checked or before its first check. The words are its help
/// and what VoiceOver reads.
struct ConnectionStateBadge: View {

    /// The last check, nil before the first.
    let state: ConnectionState?

    let isChecking: Bool

    var body: some View {
        Group {
            if isChecking {
                dot(.tertiary)
                    .shimmering()
            } else if let state, let symbol = state.troubleSymbol {
                Image(systemName: symbol)
                    .foregroundStyle(tone(of: state))
            } else if state != nil {
                dot(.green)
            } else {
                dot(.tertiary)
            }
        }
        .help(words)
        .accessibilityElement()
        .accessibilityLabel(words)
    }

    private func dot(_ fill: some ShapeStyle) -> some View {
        Circle()
            .fill(fill)
            .frame(
                width : 8,
                height: 8
            )
    }

    private func tone(of state: ConnectionState) -> AnyShapeStyle {
        switch state {
        case .credentialMissing: AnyShapeStyle(.secondary)
        case .usageLimited     : AnyShapeStyle(.orange)
        default                : AnyShapeStyle(.red)
        }
    }

    private var words: String {
        if isChecking { return "Checking" }
        return state?.title ?? "Not checked yet"
    }
}
