//
//  NewWorkerSheet.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import SwiftUI

/// NewWorkerSheet creates one worker, by hand, in the Connections sheet's
/// language: a title, a grouped list, and a bar with Cancel and Create, the
/// default button.
///
/// The first group is the mascot that will be drawn, not an approximation of
/// it, with its colour as swatches and a new shape a click away. The second
/// is the worker's name, the only field required, its role and its
/// description; the name has the keyboard when the sheet opens.
///
/// The worker is saved with no model attached and is marked to configure. The
/// footer says so, and the provider is chosen afterwards in the inspector:
/// a worker that cannot answer must not look like one that can.
struct NewWorkerSheet: View {

    let team: TeamModel

    @Environment(\.dismiss)
    private var dismiss

    @State private var name         = ""
    @State private var role         = ""
    @State private var instructions = ""
    @State private var appearance   = NewWorkerSheet.startingAppearance()

    @FocusState private var namesFirst: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text("New Worker")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .frame(
                    maxWidth : .infinity,
                    alignment: .leading
                )
                .padding(
                    .horizontal,
                    20
                )
                .padding(
                    .top,
                    20
                )

            Form {
                Section {
                    mascot
                }

                Section {
                    TextField(
                        "Name",
                        text  : $name,
                        prompt: Text("Required")
                    )
                    .focused($namesFirst)

                    TextField(
                        "Role",
                        text  : $role,
                        prompt: Text("Optional")
                    )

                    TextField(
                        "Description",
                        text  : $instructions,
                        prompt: Text("Optional"),
                        axis  : .vertical
                    )
                    .lineLimit(2...5)
                } footer: {
                    Text("""
                        It starts without a model and is listed as “\(TeamRow.toConfigure)” until you choose its \
                        provider in the inspector. It asks for no permission until it first uses the computer.
                        """)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)

            Divider()

            HStack {
                Spacer()

                Button(
                    "Cancel",
                    role: .cancel
                ) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
            .padding(
                .horizontal,
                20
            )
            .padding(
                .vertical,
                14
            )
        }
        .frame(
            width : 460,
            height: 460
        )
        .onAppear { namesFirst = true }
    }

    // MARK: Parts

    /// The mascot as it will be drawn, its colour and a new shape.
    private var mascot: some View {
        VStack(spacing: 14) {
            MascotView(
                appearance: appearance,
                size      : 72
            )

            HStack(spacing: 12) {
                MascotPalettePicker(selection: $appearance.palette)

                Divider()
                    .frame(height: 18)

                Button {
                    appearance.seed = Int64.random(in: Int64.min...Int64.max)
                } label: {
                    Label(
                        "New Shape",
                        systemImage: "dice"
                    )
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("New Shape, in the same colour")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(
            .vertical,
            8
        )
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
