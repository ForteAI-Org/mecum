//
//  StatusRow.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import ModelTransports
import SeatBroker
import AppKit
import SwiftUI

/// Ready / reason line with a coloured dot.
struct StatusRow: View {

    let store   : ModelSettingsStore
    let provider: ModelProvider

    var body: some View {
        let available = store.isAvailable(provider)
        let checking  = store.states[provider] == nil

        HStack(spacing: 8) {
            if checking {
                ProgressView()
                    .controlSize(.small)
            } else {
                Circle()
                    .fill(available ? .green : .orange)
                    .frame(
                        width : 9,
                        height: 9
                    )
            }
            Text(store.statusText(provider))
                .font(.callout.weight(.medium))
            Spacer()
        }
    }
}
