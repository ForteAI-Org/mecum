//
//  ConversationModelPopup.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import ModelTransports
import SwiftUI

/// ConversationModelPopup is what the composer's model button opens, just
/// above the bar. At the top, on one line, the worker's model and its effort,
/// the effort in the rail's colour; under them the effort as a large
/// `EffortSlider`. The line is a button: it turns the popup into the list of
/// the provider's models, and choosing one turns it back. The provider is
/// changed in the inspector, never here, because the agent's session belongs
/// to the provider.
struct ConversationModelPopup: View {

    @Binding var selection: ModelSelection

    /// The provider's catalogue, nil while it has not been listed yet.
    let catalogue: [ModelInfo]?

    @State private var isChoosingModel: Bool

    @Environment(\.accessibilityReduceMotion)
    private var reducesMotion

    /// Fixed, so a longer level's name changes only the text, never the popup.
    static let width: CGFloat = 320

    /// - Parameter showsModels: opens on the list of models, as a snapshot draws it.
    init(
        selection  : Binding<ModelSelection>,
        catalogue  : [ModelInfo]?,
        showsModels: Bool = false
    ) {
        _selection       = selection
        self.catalogue   = catalogue
        _isChoosingModel = State(initialValue: showsModels)
    }

    var body: some View {
        VStack(spacing: 14) {
            if isChoosingModel, let catalogue {
                modelList(catalogue)
                    .transition(.opacity)
            } else {
                VStack(spacing: 14) {
                    summary

                    if let entry, !entry.efforts.isEmpty {
                        EffortSlider(
                            positions: entry.efforts,
                            provider : selection.provider,
                            effort   : $selection.effort
                        )
                    } else if entry != nil {
                        Text("This model doesn’t offer Effort levels.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(16)
        .frame(
            width    : Self.width,
            alignment: .top
        )
        .modifier(ConversationPopupSurface())
    }

    /// The popup changing between the rail and the list: one transaction, so its size and its
    /// place above the composer move together rather than jumping.
    private func morph(toModels: Bool) {
        withAnimation(reducesMotion ? nil : .snappy(duration: 0.25)) { isChoosingModel = toModels }
    }

    // MARK: Summary

    /// The model and its effort on one line, a plain button into the list of models.
    @ViewBuilder
    private var summary: some View {
        if let catalogue {
            Button { morph(toModels: true) } label: {
                HStack(spacing: 6) {
                    Text(title(in: catalogue))
                        .foregroundStyle(.primary)

                    if let entry, !entry.efforts.isEmpty {
                        Text(selection.effort.title(for: selection.provider))
                            .foregroundStyle(
                                EffortSlider.colour(
                                    of: selection.effort,
                                    in: entry.efforts
                                )
                            )
                            .contentTransition(.numericText())
                    }

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .font(.headline)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(catalogue.isEmpty)
            .help("Choose Model")
        } else {
            Text("Loading models…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .shimmering()
        }
    }

    private func title(in catalogue: [ModelInfo]) -> String {
        catalogue.first { $0.id == selection.model }?.title ?? selection.model
    }

    // MARK: Models

    /// The provider's models; choosing one keeps the effort when the model takes it, or its default.
    private func modelList(_ catalogue: [ModelInfo]) -> some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(catalogue) { model in
                    ConversationModelRow(
                        title     : model.title,
                        isSelected: model.id == selection.model
                    ) {
                        choose(model)
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 280)
        .fixedSize(
            horizontal: false,
            vertical  : true
        )
    }

    private func choose(_ model: ModelInfo) {
        selection.model = model.id
        if !model.efforts.isEmpty, !model.efforts.contains(selection.effort) {
            selection.effort = model.startingEffort
        }
        morph(toModels: false)
    }

    /// The listed model, or one standing in for a model the catalogue does not list.
    private var entry: ModelInfo? {
        guard let catalogue else { return nil }

        return catalogue.first { $0.id == selection.model }
            ?? ModelInfo(
                id     : selection.model,
                efforts: ModelSelection.supportedEfforts(
                    provider: selection.provider,
                    model   : selection.model
                )
            )
    }
}
