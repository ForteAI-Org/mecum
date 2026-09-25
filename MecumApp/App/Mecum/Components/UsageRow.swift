//
//  UsageRow.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import SwiftUI

/// UsageRow is one line of a usage popover: a quiet label, and its value at
/// the trailing edge in even digits. VoiceOver reads it as one sentence,
/// `spoken`, rather than as two fragments.
struct UsageRow: View {

    let label : String
    let value : String
    let spoken: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Text(value)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }
}
