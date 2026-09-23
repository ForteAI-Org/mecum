//
//  OutcomeBadge.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import ModelTransports
import SeatBroker
import AppKit
import SwiftUI

struct OutcomeBadge: View {

    let outcome: RunRecord.Outcome

    var body: some View {
        Label(
            outcome.title,
            systemImage: outcome.icon
        )
        .font(.caption.weight(.semibold))
        .padding(
            .horizontal,
            8
        )
        .padding(
            .vertical,
            3
        )
        .background(
            outcome.color.opacity(0.18),
            in: Capsule()
        )
        .foregroundStyle(outcome.color)
    }
}
