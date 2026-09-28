//
//  InspectorProviderRow.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import ModelTransports
import SwiftUI

/// InspectorProviderRow is one provider in the inspector's list of providers:
/// its name and how a worker on it answers, then at the trailing edge a symbol
/// when its connection does not work, and a check, in the accent on the
/// worker's own and grey on the others.
/// Choosing it is the whole row.
struct InspectorProviderRow: View {

    let provider : ModelProvider
    let isCurrent: Bool

    /// The connection's last check, nil before one.
    let state: ConnectionState?

    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 8) {
                VStack(
                    alignment: .leading,
                    spacing  : 2
                ) {
                    Text(provider.title)

                    Text(answers)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Only trouble is shown here: a list that picks a provider does not need to say one works.
                if let state, state.troubleSymbol != nil {
                    ConnectionStateBadge(
                        state     : state,
                        isChecking: false
                    )
                }

                Image(systemName: "checkmark")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .accessibilityHidden(true)
            }
            .padding(
                .vertical,
                4
            )
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private var answers: String {
        switch WorkerAnswer(provider: provider) {
        case .agent, .modelLoop: "Can respond"
        }
    }
}
