//
//  NewWorkerSheet.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import SwiftUI
import Workspace

/// NewWorkerSheet creates one worker, by hand.
///
/// Name is the only required field. Colour and seed start from a value and the
/// person can change both, and the preview is the mascot that will be drawn,
/// not an approximation of it.
///
/// The worker is saved with no model attached and is marked to configure. The
/// sheet says so, and the model is chosen afterwards in the worker's profile:
/// a worker that cannot answer must not look like one that can.
struct NewWorkerSheet: View {

    let team: TeamModel

    @Environment(\.dismiss)
    private var dismiss

    @State private var name         = ""
    @State private var role         = ""
    @State private var instructions = ""
    @State private var appearance   = NewWorkerSheet.startingAppearance()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            Text("New worker")
                .font(.title3.bold())

            HStack(alignment: .top, spacing: 16) {
                MascotView(appearance: appearance, size: 64)
                    .accessibilityHidden(false)
                    .accessibilityLabel("Mascot preview, \(appearance.palette)")

                VStack(alignment: .leading, spacing: 8) {
                    Picker("Colour", selection: $appearance.palette) {
                        ForEach(MascotPalette.all) { palette in
                            Text(palette.name.capitalized).tag(palette.name)
                        }
                    }
                    Button("New shape") {
                        appearance.seed = Int64.random(in: Int64.min...Int64.max)
                    }
                    .help("Draws a different mascot in the same colour")
                }
            }

            Form {
                TextField("Name", text: $name)
                TextField("Role (optional)", text: $role)
                TextField("Description (optional)", text: $instructions, axis: .vertical)
                    .lineLimit(3...6)
            }
            .formStyle(.columns)

            Label(
                """
                Saved without a model attached. The worker is listed as \(TeamRow.toConfigure) \
                until you choose its model in Model and connection. No desktop permission is needed.
                """,
                systemImage: "info.circle"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func create() {
        let name         = trimmedName
        let role         = role.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let appearance   = appearance
        guard !name.isEmpty else { return }

        dismiss()
        Task {
            await team.createWorker(
                name        : name,
                role        : role.isEmpty ? nil : role,
                instructions: instructions.isEmpty ? nil : instructions,
                appearance  : appearance
            )
        }
    }

    /// A random seed and the first palette, both of which the person changes
    /// before saving if they want to.
    private static func startingAppearance() -> WorkerAppearance {
        WorkerAppearance(
            seed            : Int64.random(in: Int64.min...Int64.max),
            generatorVersion: MascotDrawing.generatorVersion,
            palette         : MascotPalette.fallback.name
        )
    }
}
