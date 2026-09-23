//
//  ConnectionsSheet.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import ModelTransports
import SwiftUI

/// ConnectionsSheet is the team's model connections, from the team window: a
/// title, a grouped form with one block per connection (`ConnectionSection`)
/// in the inspector's language, and a bar with Check All at the leading edge
/// and Done, the default button, at the trailing one.
///
/// It is where "Connect a model" leads on the first launch (§19.1). Opening it
/// is what checks every connection; nothing is checked before. The offscreen
/// snapshot turns that off with `checksOnAppear`, since a check runs the
/// command lines and reaches the network.
///
/// No connection here has a source that reports a balance or a price, and a
/// subscription exposes no per-token cost, so neither is estimated; the
/// sheet says so once, under the last block.
struct ConnectionsSheet: View {

    let connections: ModelSettingsStore

    var checksOnAppear = true

    @Environment(\.dismiss)
    private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // The title, the blocks and the buttons share one inset, the grouped form's own.
            VStack(
                alignment: .leading,
                spacing  : 2
            ) {
                Text("Connections")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("How the team's workers reach their models.")
                    .foregroundStyle(.secondary)
            }
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
                ForEach(ModelProvider.allCases) { provider in
                    ConnectionSection(
                        connections: connections,
                        provider   : provider
                    )
                }

                Section {
                } footer: {
                    Text("None of these connections reports credits or cost, so neither is shown.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()

            HStack {
                Button("Check All") { connections.refresh() }
                    .disabled(ModelProvider.allCases.allSatisfy(connections.isChecking))

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
            width : 560,
            height: 680
        )
        .task {
            if checksOnAppear { connections.refresh() }
        }
    }
}
