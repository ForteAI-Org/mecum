//
//  ReplyQuoteTeamTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/09/2026.
//

import ChatCore
import Foundation
import ModelTransports
import SeatBroker
import Testing
@testable import Mecum

/// What a turn's prompt begins with for a worker that never opened an application
/// (`BrokeredAutomationSession.turnStatus`); the team suites read their stand-ins' prompts after it.
let freshSeatLine = "Mecum seat: no session is open.\n\n"

/// A reply's quote through `TeamModel`, as the composer drives it: kept with
/// the draft across a switch and a relaunch, carried by the next send, and
/// given to the worker's agent above the message, from a command line and
/// through Mecum's own loop alike.
@MainActor
@Suite("Replying with a quote from the team", .serialized)
struct ReplyQuoteTeamTests {

    /// The team over `store`, with `worker` selected and its conversation open.
    private func openTeam(
        _ store         : WorkspaceStore,
        selecting worker: UUID,
        agent           : URL? = nil
    ) async -> TeamModel {
        let team: TeamModel
        if let agent {
            team = TeamModel(
                store           : store,
                connections     : ModelSettingsStore(),
                broker          : SeatBroker(),
                agents          : { _ in (.claude, agent) },
                bridgeExecutable: agent
            )
        } else {
            team = TeamModel(
                store      : store,
                connections: ModelSettingsStore(),
                broker     : SeatBroker()
            )
        }
        await team.load()
        team.selection = worker
        await team.openSelectedConversation()
        return team
    }

    @Test("A reply in progress survives a switch to another worker and a relaunch, with its draft")
    func theDraftQuoteIsKept() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        let store = try WorkspaceStore.opening(in: directory)
        let atlas = try await store.createWorker(
            name      : "Atlas",
            appearance: TemporaryStore.appearance()
        ).id
        let nova  = try await store.createWorker(
            name      : "Nova",
            appearance: TemporaryStore.appearance(palette: "dawn")
        ).id
        let quote = MessageQuote(
            messageID     : UUID(),
            authorWorkerID: atlas,
            text          : "Two bundles failed."
        )

        let team = await openTeam(
            store,
            selecting: atlas
        )
        team.draft      = "Which one"
        team.draftQuote = quote
        #expect(team.hasUnsavedDraft)

        team.selection = nova
        await team.openSelectedConversation()
        #expect(team.draftQuote == nil, "another worker's draft quotes nothing")
        #expect(team.draft.isEmpty)

        team.selection = atlas
        await team.openSelectedConversation()
        #expect(team.draftQuote == quote)
        #expect(team.draft == "Which one")
        #expect(!team.hasUnsavedDraft)

        let relaunched = await openTeam(
            try WorkspaceStore.opening(in: directory),
            selecting: atlas
        )
        #expect(relaunched.draftQuote == quote)
        #expect(relaunched.draft == "Which one")
    }

    @Test("A send carries the quote into the message and leaves the draft quoting nothing")
    func aSendCarriesTheQuote() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        let store  = try WorkspaceStore.opening(in: directory)
        let worker = try await store.createWorker(
            name      : "Atlas",
            appearance: TemporaryStore.appearance()
        ).id
        let team   = await openTeam(
            store,
            selecting: worker
        )
        let conversation = try #require(team.conversation?.id)
        let asked  = try await store.appendMessage(
            to  : conversation,
            text: "Check the build."
        )
        let quote  = MessageQuote(
            messageID     : asked.id,
            authorWorkerID: nil,
            text          : "Check the build."
        )

        team.draft      = "And yesterday’s."
        team.draftQuote = quote
        await team.flushDraft()
        await team.send()

        let sent = try #require(try await store.messages(in: conversation).last)
        #expect(sent.text == "And yesterday’s.")
        #expect(sent.quote == quote)
        #expect(team.draftQuote == nil)
        #expect(try await store.conversation(conversation)?.draftQuote == nil)
        #expect(!team.hasUnsavedDraft)
    }

    @Test("The agent's text is the quote as a blockquote, a blank line, then the message")
    func agentTextComposition() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        let store        = try WorkspaceStore.opening(in: directory)
        let worker       = try await store.createWorker(
            name      : "Atlas",
            appearance: TemporaryStore.appearance()
        ).id
        let conversation = try await store.createConversation(participants: [worker]).id
        let answer       = try await store.appendMessage(
            to    : conversation,
            author: worker,
            text  : "Two bundles failed:\ncapture\n\nand layout."
        )
        let plain        = try await store.appendMessage(
            to  : conversation,
            text: "Thanks."
        )
        let reply        = try await store.appendMessage(
            to   : conversation,
            text : "Which first?",
            quote: MessageQuote(
                messageID     : answer.id,
                authorWorkerID: worker,
                text          : answer.text
            )
        )

        let composed = "> Two bundles failed:\n> capture\n> \n> and layout.\n\nWhich first?"
        #expect(TeamModel.agentText(of: reply) == composed)
        #expect(TeamModel.agentText(of: plain) == "Thanks.")

        // Mecum's own loop is sent the earlier messages through the same composition.
        let history = TeamModel.turnHistory(
            try await store.messages(in: conversation),
            by: worker
        )
        #expect(history == [
            TurnMessage(
                role: .assistant,
                text: answer.text
            ),
            TurnMessage(
                role: .user,
                text: "Thanks."
            ),
            TurnMessage(
                role: .user,
                text: composed
            ),
        ])
    }

    @Test("A command line agent is sent the quote above the message")
    func theCommandLineReceivesTheQuote() async throws {
        let root = URL.temporaryDirectory.appending(path: "mecum-reply-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at                         : root,
            withIntermediateDirectories: true
        )
        // A stand-in Claude Code: it keeps what it was sent and answers "ok".
        let agent = root.appending(path: "claude")
        try Data("""
            #!/usr/bin/python3
            import json, sys
            received = sys.stdin.read()
            open('\(root.path)/received.txt', 'w').write(received)
            def say(event):
                event['session_id'] = 's1'
                print(json.dumps(event), flush=True)
            spent = {'input_tokens': 90, 'output_tokens': 10}
            say({'type': 'system', 'subtype': 'init', 'model': 'claude-sonnet-5'})
            say({'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 'ok'}]}})
            say({'type': 'result', 'is_error': False, 'result': 'ok', 'usage': dict(spent, iterations=[spent]),
                 'modelUsage': {'claude-sonnet-5': {'contextWindow': 1000}}})

            """.utf8).write(to: agent)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: agent.path
        )

        let store  = try WorkspaceStore.opening(in: root.appending(path: "store"))
        let worker = try await store.createWorker(
            name      : "Atlas",
            appearance: TemporaryStore.appearance()
        ).id
        try await store.configure(
            worker   : worker,
            selection: ModelSelection(
                provider: .claudeCode,
                model   : "claude-sonnet-5",
                effort  : .low
            )
        )
        let team = await openTeam(
            store,
            selecting: worker,
            agent    : agent
        )
        let quote = MessageQuote(
            messageID     : UUID(),
            authorWorkerID: worker,
            text          : "Capture\nand layout."
        )

        team.draft      = "Which first?"
        team.draftQuote = quote
        await team.send()
        // Ten seconds at most for the stand-in's turn to end.
        var waited = 0
        while team.isAnswering(worker), waited < 1_000 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }

        #expect(!team.isAnswering(worker))
        let received = try String(
            contentsOf: root.appending(path: "received.txt"),
            encoding  : .utf8
        )
        #expect(received == freshSeatLine + "> Capture\n> and layout.\n\nWhich first?")
        #expect(try await store.messages(in: try #require(team.conversation?.id)).map(\.text) == ["Which first?", "ok"])
        #expect(team.problem == nil)
        await team.closeAgentHosts()
    }
}
