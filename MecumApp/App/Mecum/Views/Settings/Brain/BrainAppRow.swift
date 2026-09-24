//
//  BrainAppRow.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import Memory
import SwiftUI

/// BrainAppRow is one application in the Brain's list: its icon and name,
/// how much is known of it, and when it was last seen. The navigation link
/// around it opens it and draws the chevron.
struct BrainAppRow: View {

    let app: BrainApp

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                } else {
                    Image(systemName: "app.dashed")
                        .resizable()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(
                width : 28,
                height: 28
            )

            VStack(
                alignment: .leading,
                spacing  : 2
            ) {
                Text(app.name)

                Text(counts)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let date = app.lastLearned {
                Text(date, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(
            .vertical,
            4
        )
    }

    /// What the Brain holds, leaving out what it has none of.
    private var counts: String {
        let brain = app.brain
        let parts = [
            (brain.objects.count, "control"),
            (brain.groups.count, "group"),
            (brain.transitions.count, "effect"),
        ]
        return parts
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
            .joined(separator: " · ")
    }
}
