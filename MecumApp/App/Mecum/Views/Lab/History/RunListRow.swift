//
//  RunListRow.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import ModelTransports
import SeatBroker
import AppKit
import SwiftUI

struct RunListRow: View {

    let record: RunRecord

    var body: some View {
        HStack(
            alignment: .top,
            spacing  : 10
        ) {
            Image(systemName: record.outcome.icon)
                .foregroundStyle(record.outcome.color)
                .font(.title3)
                .frame(width: 22)
                .padding(
                    .top,
                    1
                )
            VStack(
                alignment: .leading,
                spacing  : 3
            ) {
                Text(record.goal)
                    .lineLimit(2)
                    .font(.body.weight(.medium))
                HStack(spacing: 4) {
                    Text(record.app)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(record.model)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text(record.startedAt.formatted(.relative(presentation: .named)))
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(record.steps.count) step\(record.steps.count == 1 ? "" : "s")")
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(record.duration.formatted(.units(
                        allowed: [.minutes, .seconds],
                        width  : .narrow
                    )))
                    if let output = record.outputTokens {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text("\((record.inputTokens ?? 0) + output) tok")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(
            .vertical,
            4
        )
    }
}
