//
//  InspectorDeadEnd.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import ModelTransports
import SwiftUI

/// Why the worker's provider, as chosen in the inspector, does not answer in
/// this build, said as long as it is the worker's, with the providers that do.
struct InspectorDeadEnd: View {

    let provider: ModelProvider
    let refusal : String

    var body: some View {
        Label(
            """
            \(provider.title) does not answer here yet: \(refusal). A worker saved with it stays \
            on the team and will not answer. Choose Claude Code or Codex for a worker that answers.
            """,
            systemImage: "exclamationmark.bubble"
        )
        .foregroundStyle(.orange)
        .fixedSize(
            horizontal: false,
            vertical  : true
        )
    }
}
