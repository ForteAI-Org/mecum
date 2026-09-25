//
//  ConnectionsSheet.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import ModelTransports
import SwiftUI

/// ConnectionsSheet is the team's model connections, from the team window: a
/// title, one grouped list of the connections in the inspector's language, a
/// row each (`ConnectionItem`) that opens in place into what acts on it, and a
/// bar with Check All at the leading edge and Done, the default button, at
/// the trailing one.
///
/// It is where "Connect a model" leads on the first launch (§19.1). Opening it
/// checks every connection again; the app has checked them once at launch.
/// The offscreen snapshot turns that off with `checksOnAppear`, since a check
/// runs the command lines and reaches the network.
///
/// No connection here has a source that reports a balance or a price, and a
/// subscription exposes no per-token cost, so neither is estimated; the list
/// says so once, under its rows.
struct ConnectionsSheet: View {

    let connections: ModelSettingsStore

    var checksOnAppear = true

    /// The connections whose rows are open.
    @State private var open: Set<ModelProvider>

    @Environment(\.dismiss)
    private var dismiss

    @Environment(\.accessibilityReduceMotion)
    private var reducesMotion

    /// - Parameter opens: the rows open from the start, as a snapshot draws them.
    init(
        connections   : ModelSettingsStore,
        checksOnAppear: Bool = true,
        opens         : Set<ModelProvider> = []
    ) {
        self.connections    = connections
        self.checksOnAppear = checksOnAppear
        _open               = State(initialValue: opens)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Providers")
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
                    ForEach(ModelProvider.inApp) { provider in
                        ConnectionItem(
                            connections: connections,
                            provider   : provider,
                            isOpen     : open.contains(provider)
                        ) {
                            toggle(provider)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()

            HStack {
                Button {
                    connections.refresh()
                } label: {
                    Label(
                        "Check All Connections",
                        systemImage: "arrow.clockwise"
                    )
                }
                .labelStyle(.iconOnly)
                .help("Check all connections.")
                .disabled(ModelProvider.inApp.allSatisfy(connections.isChecking))

                Spacer()

                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
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
            width : 520,
            height: 600
        )
        .task {
            if checksOnAppear { connections.refresh() }
        }
    }

    /// Opens or closes one connection's row in one animation, its rows coming in and out.
    private func toggle(_ provider: ModelProvider) {
        withAnimation(reducesMotion ? nil : .snappy(duration: 0.25)) {
            if open.contains(provider) { open.remove(provider) } else { open.insert(provider) }
        }
    }
}
