//
//  NewWorkerModelTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import ModelTransports
import SeatBroker
import Testing
@testable import Mecum

/// The provider and the model the New Worker sheet starts on, by the rule the
/// inspector's change of provider uses too.
@MainActor
@Suite("The new worker's preselected model")
struct NewWorkerPreselectionTests {

    @Test func theFirstReadyProviderInOrderIsPreselected() {
        let states: [ModelProvider: ConnectionState] = [
            .codex     : .credentialMissing,
            .anthropic : .ready,
            .claudeCode: .ready,
        ]
        #expect(ModelProvider.preselected(in: states) == .claudeCode)
    }

    @Test func noProviderIsPreselectedWhenNoneIsReady() {
        let states: [ModelProvider: ConnectionState] = [
            .codex : .credentialMissing,
            .ollama: .usageLimited(detail: "limit"),
        ]
        #expect(ModelProvider.preselected(in: states) == nil)
        #expect(ModelProvider.preselected(in: [:]) == nil)
    }

    @Test func theProvidersDefaultModelIsPreselectedWhenListed() {
        let catalogue = [
            ModelInfo(
                id     : "gpt-5.4-mini",
                efforts: [.low]
            ),
            ModelInfo(
                id     : "gpt-5.6-luna",
                efforts: [.low]
            ),
        ]
        #expect(ModelProvider.codex.startingModel(in: catalogue)?.id == "gpt-5.6-luna")
    }

    @Test func theFirstModelIsPreselectedOtherwise() {
        let catalogue = [
            ModelInfo(
                id     : "qwen3:8b",
                efforts: []
            ),
            ModelInfo(
                id     : "llama4",
                efforts: []
            ),
        ]
        #expect(ModelProvider.ollama.startingModel(in: catalogue)?.id == "qwen3:8b")
        #expect(ModelProvider.codex.startingModel(in: catalogue)?.id == "qwen3:8b")
    }

    @Test func anEmptyCatalogueHasNoModel() {
        #expect(ModelProvider.codex.startingModel(in: []) == nil)
    }
}

/// A worker created with a model has it as its first configuration version,
/// and one created without stays to configure.
@MainActor
@Suite("Creating a worker with a model")
struct NewWorkerCreationTests {

    @Test func aWorkerCreatedWithASelectionIsConfiguredWithIt() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store = try WorkspaceStore.opening(in: directory)
        let team  = TeamModel(
            store      : store,
            connections: ModelSettingsStore(),
            broker     : SeatBroker()
        )
        await team.createWorker(
            name        : "Iris",
            role        : nil,
            instructions: nil,
            appearance  : TemporaryStore.appearance(),
            selection   : TemporaryStore.firstSelection
        )

        let worker = try #require(team.active.first)
        #expect(team.active.count == 1)
        #expect(worker.configuration == TemporaryStore.firstSelection)
        #expect(team.problem == nil)
        // The next version is the second, so the selection was the first.
        #expect(try await store.configure(
            worker   : worker.id,
            selection: TemporaryStore.secondSelection
        ) == 2)
    }

    @Test func aWorkerCreatedWithoutASelectionHasNoConfiguration() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let team = TeamModel(
            store      : try WorkspaceStore.opening(in: directory),
            connections: ModelSettingsStore(),
            broker     : SeatBroker()
        )
        await team.createWorker(
            name        : "Nova",
            role        : nil,
            instructions: nil,
            appearance  : TemporaryStore.appearance()
        )

        let worker = try #require(team.active.first)
        #expect(worker.configuration == nil)
        #expect(team.needsConfiguring(worker))
        #expect(team.problem == nil)
    }
}
