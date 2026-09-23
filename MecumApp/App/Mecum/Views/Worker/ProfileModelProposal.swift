//
//  ProfileModelProposal.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import ModelTransports
import SwiftUI

/// A saved model the catalogue dropped, with a proposed replacement the
/// person puts in the draft; nothing replaces it for them (§7.4).
struct ProfileModelProposal: View {

    let removed   : String
    let provider  : ModelProvider
    let workerName: String
    let catalogue : [String]

    @Binding var model: String

    var body: some View {
        let replacement = ProviderCatalog.replacement(
            for      : removed,
            provider : provider,
            catalogue: catalogue
        )

        VStack(
            alignment: .leading,
            spacing  : 8
        ) {
            Label(
                """
                \(removed) is no longer in \(provider.title)'s catalogue, so \(workerName) needs \
                configuring. Nothing was changed.
                """,
                systemImage: "questionmark.square.dashed"
            )
            .fixedSize(
                horizontal: false,
                vertical  : true
            )

            if let replacement {
                Button("Use \(replacement) instead") { model = replacement }
                    .help("Puts it in the draft. Nothing is saved until you press Save.")
            }
        }
        .padding(10)
        .background(
            .purple.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }
}
