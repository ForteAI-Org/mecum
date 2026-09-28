//
//  InspectorIdentitySection.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI

/// The worker's mascot, name and role, small at the top of the inspector.
struct InspectorIdentitySection: View {

    let worker: WorkerSnapshot

    var body: some View {
        Section {
            HStack(spacing: 10) {
                MascotView(
                    appearance: worker.appearance,
                    size      : 28
                )

                VStack(
                    alignment: .leading,
                    spacing  : 1
                ) {
                    Text(worker.name)
                        .font(.headline)
                        .lineLimit(1)

                    Text(role ?? "No role set")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var role: String? {
        let text = worker.role?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }
}
