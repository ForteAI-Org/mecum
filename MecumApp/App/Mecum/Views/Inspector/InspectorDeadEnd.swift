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

    var body: some View {
        Label(
            """
            \(provider.title) can’t respond to worker messages yet. Choose \(Self.answering).
            """,
            systemImage: "exclamationmark.bubble"
        )
        .foregroundStyle(.orange)
        .fixedSize(
            horizontal: false,
            vertical  : true
        )
    }

    /// The providers that answer, in the app's order, as the end of a sentence.
    private static var answering: String {
        ModelProvider.inApp
            .filter { WorkerAnswer(provider: $0).refusal == nil }
            .map(\.title)
            .formatted(.list(type: .or))
    }
}
