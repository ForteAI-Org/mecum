//
//  WindowSnapshots+SlashCommands.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/09/2026.
//

import ChatCore
import Foundation
import ModelTransports
import SeatBroker
import SwiftUI

extension WindowSnapshots {

    /// The composer's command popup, in both themes: every command after `/`,
    /// those `/co` matches, the models after `/model ` with Atlas's own checked,
    /// a model the provider does not offer, and every command while Atlas
    /// answers, those that wait dimmed with why.
    static func writeSlashCommands(to output: URL) async throws {
        let directory = URL.temporaryDirectory.appending(
            path         : "MecumSlashCommandSnapshots-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let team = try await commandTeam(in: directory)
        guard let worker = team.selectedWorker else { return }

        func write(_ scene: String) async throws {
            for (name, dark) in [("light", false), ("dark", true)] {
                try await WindowSnapshots.write(
                    ConversationComposer(
                        team  : team,
                        worker: worker,
                        height: .constant(0)
                    )
                    .frame(
                        maxHeight: .infinity,
                        alignment: .bottom
                    )
                    .background(Color(nsColor: .windowBackgroundColor)),
                    width : 560,
                    height: 400,
                    dark  : dark,
                    to    : output.appending(path: "composer-commands-\(scene)-\(name).png")
                )
            }
        }

        let scenes = [
            ("all", "/"),
            ("filtered", "/co"),
            ("models", "/model "),
            ("refused", "/model gpt-9"),
        ]
        for (scene, draft) in scenes {
            team.draft = draft
            try await write(scene)
        }

        // Atlas's stand-in answers nothing and never ends, so the turn keeps running.
        team.draft = "Rerun the capture suite."
        await team.send()
        for _ in 0..<100 where !team.isAnswering(worker.id) {
            try await Task.sleep(for: .milliseconds(20))
        }
        struct AtlasNeverAnswered: Error {}
        guard team.isAnswering(worker.id) else { throw AtlasNeverAnswered() }

        team.draft = "/"
        try await write("answering")
        team.draft = ""
        await team.closeAgentHosts()
    }

    /// Atlas on Codex's GPT-5.4-Mini, with Codex's catalogue listed and one
    /// turn's usage, so the context ring and the token counter are shown, and a
    /// stand-in command line that answers nothing until it is stopped.
    private static func commandTeam(in directory: URL) async throws -> TeamModel {
        let store = try WorkspaceStore.opening(in: directory)
        let atlas = try await store.createWorker(
            name      : "Atlas",
            role      : "Release engineer",
            appearance: WorkerAppearance(
                seed   : 7,
                palette: "tide"
            )
        )
        try await store.configure(
            worker   : atlas.id,
            selection: ModelSelection(
                provider: .codex,
                model   : "gpt-5.4-mini",
                effort  : .low
            )
        )
        let conversation = try await store.createConversation(
            kind        : .direct,
            participants: [atlas.id]
        ).id
        try await store.append(NewEvent(
            workspaceID   : UUID(),
            subjectID     : UUID(),
            conversationID: conversation,
            workerID      : atlas.id,
            timestamp     : Date(timeIntervalSinceReferenceDate: 780_000_000),
            type          : .turnUsage,
            payload       : try atlasUsage(contextTokens: 142_318).encoded()
        ))

        let agent = directory.appending(path: "agent")
        try Data("#!/bin/sh\nexec sleep 600\n".utf8).write(to: agent)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: agent.path(percentEncoded: false)
        )
        let team = TeamModel(
            store           : store,
            connections     : ModelSettingsStore(),
            broker          : SeatBroker(),
            agents          : { _ in (.claude, agent) },
            bridgeExecutable: agent
        )
        team.connections.recordCatalogue(
            ["GPT-6-Sol", "GPT-5.6-Luna", "GPT-5.4-Mini", "GPT-5.5"].map { title in
                ModelInfo(
                    id     : title.lowercased(),
                    title  : title,
                    efforts: [.low, .medium, .high]
                )
            },
            for: .codex
        )
        await team.load()
        team.selection = atlas.id
        await team.openSelectedConversation()
        return team
    }
}
