//
//  SlashCommandTeamTests.swift
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

/// Atlas on a stand-in Claude Code, driven through `TeamModel` as the composer
/// drives it. Each call to the stand-in waits for a `go-N` file, N its place
/// among the calls, then answers "ok" with 100 tokens of a 1,000 token
/// context, or compacts when it was sent `/compact`.
///
/// A call's record is written beside the log and moved into it whole, so a
/// test polling the log while the stand-in runs never reads a half written one.
@MainActor
private final class Harness {

    let root       : URL
    let store      : WorkspaceStore
    let team       : TeamModel
    let atlas      : UUID
    let preferences: UserDefaults

    private let suite: String

    init() async throws {
        suite       = "mecum-team-commands-\(UUID().uuidString)"
        preferences = try #require(UserDefaults(suiteName: suite))
        root        = URL.temporaryDirectory.appending(path: "mecum-team-commands-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at                         : root.appending(path: "log"),
            withIntermediateDirectories: true
        )
        let agent = root.appending(path: "claude")
        try Data(Self.standIn(root).utf8).write(to: agent)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: agent.path
        )

        store = try WorkspaceStore.opening(in: root.appending(path: "store"))
        atlas = try await store.createWorker(
            name      : "Atlas",
            appearance: TemporaryStore.appearance()
        ).id
        try await store.configure(
            worker   : atlas,
            selection: ModelSelection(
                provider: .claudeCode,
                model   : "claude-sonnet-5",
                effort  : .low
            )
        )

        team = TeamModel(
            store           : store,
            connections     : ModelSettingsStore(),
            broker          : SeatBroker(),
            agents          : { _ in (.claude, agent) },
            bridgeExecutable: agent,
            preferences     : preferences
        )
        await team.load()
        team.selection = atlas
        await team.openSelectedConversation()
    }

    private static func standIn(_ root: URL) -> String {
        """
        #!/usr/bin/python3
        import json, os, sys, time
        root = '\(root.path)'
        received = sys.stdin.read()
        log = os.path.join(root, 'log')
        call = len(os.listdir(log))
        record = os.path.join(root, 'record-%d' % os.getpid())
        with open(record, 'w') as file:
            json.dump({'received': received}, file)
        os.replace(record, os.path.join(log, '%03d.json' % call))
        def say(event):
            event['session_id'] = 's1'
            print(json.dumps(event), flush=True)
        window = {'claude-sonnet-5': {'contextWindow': 1000}}
        say({'type': 'system', 'subtype': 'init', 'model': 'claude-sonnet-5'})
        while not os.path.exists(os.path.join(root, 'go-%d' % call)):
            time.sleep(0.01)
        if received == '/compact':
            say({'type': 'system', 'subtype': 'compact_boundary',
                 'compact_metadata': {'trigger': 'manual', 'pre_tokens': 950, 'post_tokens': 120}})
            say({'type': 'result', 'is_error': False, 'result': '', 'num_turns': 0,
                 'usage': {'input_tokens': 0, 'output_tokens': 0, 'iterations': []}, 'modelUsage': window})
            sys.exit(0)
        spent = {'input_tokens': 90, 'output_tokens': 10}
        say({'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 'ok'}]}})
        say({'type': 'result', 'is_error': False, 'result': 'ok',
             'usage': dict(spent, iterations=[spent]), 'modelUsage': window})

        """
    }

    /// Lets the stand-in's call number `call` answer.
    func go(_ call: Int) throws {
        try Data().write(to: root.appending(path: "go-\(call)"))
    }

    /// Types `text`, with `quote` when there is one, and sends it, as Return does.
    func send(
        _ text       : String,
        quoting quote: MessageQuote? = nil
    ) async {
        team.draft      = text
        team.draftQuote = quote
        await team.send()
    }

    /// Sends a first message and lets it complete, so the counter and the ring show.
    func answerOnce() async throws {
        await send("one")
        try await waitForCalls(1)
        try go(0)
        try await idle()
        try #require(UsageWording.ringContext(of: team.usage[atlas]) != nil)
    }

    /// What each call to the stand-in was sent, in order, after the seat line a turn opens with.
    func calls() throws -> [String] {
        let log   = root.appending(path: "log")
        let names = try FileManager.default.contentsOfDirectory(atPath: log.path).sorted()
        return try names.map { name in
            let call = try JSONSerialization.jsonObject(with: Data(contentsOf: log.appending(path: name)))
                as? [String: Any]
            return String((call?["received"] as? String ?? "").trimmingPrefix(freshSeatLine))
        }
    }

    func conversation() async throws -> ConversationSnapshot {
        try #require(try await store.conversations().first { $0.participantIDs == [atlas] })
    }

    /// What the person wrote in Atlas's conversation, in order.
    func personMessages() async throws -> [String] {
        try await store.messages(in: conversation().id)
            .filter { $0.authorWorkerID == nil }
            .map(\.text)
    }

    /// Waits until `condition` holds, ten seconds at most.
    func wait(for condition: () async throws -> Bool) async throws {
        for _ in 0..<1_000 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(try await condition())
    }

    func waitForCalls(_ count: Int) async throws {
        try await wait { try calls().count == count }
    }

    func idle() async throws {
        try await wait { !team.isAnswering(atlas) }
    }

    /// Long enough for a call that should not happen to show up.
    func settle() async throws {
        try await Task.sleep(for: .milliseconds(400))
    }

    func discard() async {
        await team.closeAgentHosts()
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
@Suite("Running slash commands from the composer", .serialized)
struct SlashCommandTeamTests {

    @Test("/compact compacts the context, empties and saves the draft, keeps its quote, and writes no message")
    func compact() async throws {
        let harness = try await Harness()
        try await harness.answerOnce()

        let quote = MessageQuote(
            messageID     : UUID(),
            authorWorkerID: nil,
            text          : "one"
        )
        await harness.send(
            "/compact",
            quoting: quote
        )
        #expect(harness.team.draft.isEmpty)
        #expect(harness.team.draftQuote == quote, "a command does not use up the reply in progress")
        #expect(harness.team.isCompacting(harness.atlas))

        try await harness.waitForCalls(2)
        try harness.go(1)
        try await harness.idle()

        #expect(try harness.calls() == ["one", "/compact"])
        #expect(try await harness.personMessages() == ["one"])
        let stored = try await harness.conversation()
        #expect(stored.draft.isEmpty)
        #expect(stored.draftQuote == quote)
        #expect(harness.team.problem == nil)
        await harness.discard()
    }

    @Test("/new starts a fresh context and writes no message")
    func startFresh() async throws {
        let harness = try await Harness()
        try await harness.answerOnce()

        await harness.send("/new")

        let resets = try await harness.store.events(matching: EventQuery(
            scope: .conversation(harness.conversation().id)
        )).filter { $0.type == .contextReset }
        #expect(resets.count == 1)
        #expect(harness.team.draft.isEmpty)
        #expect(try await harness.personMessages() == ["one"])
        #expect(try harness.calls() == ["one"])
        await harness.discard()
    }

    @Test("/model and /effort change the worker's model; /model alone asks for the model popup")
    func modelAndEffort() async throws {
        let harness = try await Harness()
        // The catalogue the provider lists, fixed as the composer's window tests fix it: the installed
        // Claude Code's own list depends on its version and account, and is not this test's subject.
        harness.team.connections.recordCatalogue(
            [("claude-opus-5", "Claude Opus 5"), ("claude-sonnet-5", "Claude Sonnet 5"), ("claude-haiku-4-5", "Claude Haiku 4.5")]
                .map { ModelInfo(id: $0.0, title: $0.1, efforts: [.low, .medium, .high]) },
            for: .claudeCode
        )

        await harness.send("/model claude-opus-5")
        #expect(harness.team.worker(harness.atlas)?.configuration?.model == "claude-opus-5")
        #expect(harness.team.draft.isEmpty)

        await harness.send("/effort high")
        #expect(harness.team.worker(harness.atlas)?.configuration == ModelSelection(
            provider: .claudeCode,
            model   : "claude-opus-5",
            effort  : .high
        ))

        #expect(harness.team.modelPopupRequest == 0)
        await harness.send("/model")
        #expect(harness.team.modelPopupRequest == 1)

        await harness.send("/model gpt-5")
        #expect(harness.team.draft == "/model gpt-5", "a model the provider does not offer leaves the draft")
        #expect(try await harness.personMessages().isEmpty)
        #expect(try harness.calls().isEmpty)
        await harness.discard()
    }

    @Test("/usage and /context open their popovers once their controls show, and wait with the draft before")
    func popovers() async throws {
        let harness = try await Harness()
        await harness.send("/usage")
        #expect(harness.team.draft == "/usage", "the counter is not shown before the first turn")
        #expect(!harness.team.showsUsage)

        try await harness.answerOnce()
        await harness.send("/usage")
        await harness.send("/context")

        #expect(harness.team.showsUsage)
        #expect(harness.team.showsContext)
        #expect(harness.team.draft.isEmpty)
        #expect(try await harness.personMessages() == ["one"])
        await harness.discard()
    }

    @Test("A command while the worker answers never queues: /new waits with the draft, /stop stops")
    func whileAnswering() async throws {
        let harness = try await Harness()
        await harness.send("one")
        try await harness.waitForCalls(1)

        await harness.send("/new")
        #expect(harness.team.draft == "/new")
        #expect(harness.team.queue.isEmpty)

        await harness.send("/stop")
        #expect(harness.team.draft.isEmpty)
        #expect(harness.team.queue.isEmpty)
        try await harness.idle()
        try await harness.settle()

        #expect(try harness.calls() == ["one"])
        #expect(try await harness.personMessages() == ["one"])
        #expect(try await harness.conversation().queue.isEmpty)
        await harness.discard()
    }

    @Test("A draft that starts with // is sent with one slash, and a path is sent as it is")
    func messagesThatStartWithASlash() async throws {
        let harness = try await Harness()
        await harness.send("//text")
        try await harness.waitForCalls(1)
        try harness.go(0)
        try await harness.idle()

        await harness.send("/Users/x")
        try await harness.waitForCalls(2)

        #expect(try harness.calls() == ["/text", "/Users/x"])
        #expect(try await harness.personMessages() == ["/text", "/Users/x"])
        #expect(harness.team.draft.isEmpty)
        await harness.discard()
    }
}
