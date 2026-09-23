//
//  ProfileModelPicker.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import ModelTransports
import SwiftUI

/// The profile's model picker over the provider's catalogue, or while there
/// is nothing to pick, the reason in a sentence.
struct ProfileModelPicker: View {

    let provider: ModelProvider

    @Binding var model: String

    let catalogue         : [String]
    let isLoadingCatalogue: Bool
    let catalogueFailed   : Bool

    var body: some View {
        if isLoadingCatalogue {
            Text("Reading the catalogue…").shimmering()
        } else if modelOptions.isEmpty {
            Text(
                catalogueFailed
                    ? "The catalogue could not be read, so there is no model to choose. The connection above says why."
                    : "\(provider.title) lists no model. For Ollama, pull one with “ollama pull <name>”."
            )
            .foregroundStyle(.secondary)
            .fixedSize(
                horizontal: false,
                vertical  : true
            )
        } else {
            Picker(
                "Model",
                selection: $model
            ) {
                if model.isEmpty { Text("Choose a model").tag("") }

                ForEach(
                    modelOptions,
                    id: \.self
                ) { option in
                    Text(catalogue.contains(option) ? option : "\(option) (not listed)").tag(option)
                }
            }
        }
    }

    /// The catalogue, and the draft's model when the catalogue does not list it.
    private var modelOptions: [String] {
        catalogue.contains(model) || model.isEmpty ? catalogue : [model] + catalogue
    }
}
