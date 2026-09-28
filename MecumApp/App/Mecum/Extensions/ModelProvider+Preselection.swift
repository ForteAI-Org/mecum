//
//  ModelProvider+Preselection.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import ModelTransports

extension ModelProvider {

    /// The provider a new worker starts on: the first, in `allCases` order,
    /// whose last check found it ready, and nil when none did.
    static func preselected(in states: [ModelProvider: ConnectionState]) -> ModelProvider? {
        allCases.first { states[$0]?.isReady == true }
    }

    /// The model a worker moved to this provider comes with: the provider's
    /// default when the catalogue lists it, else the first listed, and nil for
    /// an empty catalogue.
    func startingModel(in catalogue: [ModelInfo]) -> ModelInfo? {
        let ids       = catalogue.map(\.id)
        let preferred = defaultModels.first(where: ids.contains)
        return catalogue.first { $0.id == preferred } ?? catalogue.first
    }
}
