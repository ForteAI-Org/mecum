//
//  ConnectionsSheet.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import ModelTransports
import SwiftUI

/// ConnectionsSheet lists one card per connection, from the team window.
///
/// It is where "Connect a model" leads on the first launch (§19.1). Opening it
/// is what checks every connection; nothing is checked before.
struct ConnectionsSheet: View {

    let connections: ModelSettingsStore

    @Environment(\.dismiss)
    private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Connections")
                    .font(.title3.bold())
                Spacer()
                Button("Verify all") { connections.refresh() }
            }
            .padding(20)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(ModelProvider.allCases) { provider in
                        ConnectionCardView(connections: connections, provider: provider)
                    }
                }
                .padding(.horizontal, 20)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 580, height: 660)
        .task { connections.refresh() }
    }
}
