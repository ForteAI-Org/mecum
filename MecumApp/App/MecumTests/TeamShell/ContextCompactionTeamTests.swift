//
//  ContextCompactionTeamTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import ChatCore
import Foundation
import ModelTransports
import SeatBroker
import Testing
@testable import Mecum

/// A worker on a stand-in Claude Code, driven through `TeamModel` as the
/// composer and the context popover drive it. The stand-in keeps each call's
/// arguments and what it was sent, answers a turn with the context in its
/// `context` file against a 1,000 token window, and `/compact` as its
/// `compaction` file says: compacted to 120, refused, signed out, or hanging.
/// A `turn` file makes a turn fail or hang after it answered.
@MainActor
private final class Harness {

    let root  : URL
    let store : WorkspaceStore
    let team  : TeamModel
    let worker: UUID

    init() async throws {
        root = URL.temporaryDirectory.appending(path: "mecum-team-compaction-\(UUID().uuidString)")
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

        store  = try WorkspaceStore.opening(in: root.appending(path: "store"))
        worker = try await store.createWorker(
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
        team = TeamModel(
            store           : store,
            connections     : ModelSettingsStore(),
            broker          : SeatBroker(),
            agents          : { _ in (.claude, agent) },
            bridgeExecutable: agent
        )
        await team.load()
        team.selection = worker
        await team.openSelectedConversation()
    }

    private static func standIn(_ root: URL) -> String {
        """
        #!/usr/bin/python3
        import json, os, sys, time
        root = '\(root.path)'
        received = sys.stdin.read()
        log = os.path.join(root, 'log')
        with open(os.path.join(log, '%03d.json' % len(os.listdir(log))), 'w') as file:
            json.dump({'arguments': sys.argv[1:], 'received': received}, file)
        def setting(name, default):
            try:
                return open(os.path.join(root, name)).read().strip()
            except OSError:
                return default
        def say(event):
            event['session_id'] = 's1'
            print(json.dumps(event), flush=True)
        window = {'claude-sonnet-5': {'contextWindow': 1000}}
        say({'type': 'system', 'subtype': 'init', 'model': 'claude-sonnet-5'})
        if received == '/compact':
            kind = setting('compaction', 'compacts')
            if kind == 'hangs':
                time.sleep(600)
            if kind == 'refused':
                words = "/compact isn't available in this environment."
                say({'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': words}]}})
                say({'type': 'result', 'is_error': False, 'result': words, 'usage': {}, 'modelUsage': {}})
            elif kind == 'signed-out':
                say({'type': 'result', 'is_error': True, 'errors': ['Failed to authenticate. API Error: 401']})
            else:
                say({'type': 'system', 'subtype': 'compact_boundary',
                     'compact_metadata': {'trigger': 'manual', 'pre_tokens': 950, 'post_tokens': 120}})
                say({'type': 'result', 'is_error': False, 'result': '', 'num_turns': 0,
                     'usage': {'input_tokens': 0, 'output_tokens': 0, 'iterations': []}, 'modelUsage': window})
            sys.exit(0)
        context = int(setting('context', '100'))
        kind = setting('turn', 'completes')
        spent = {'input_tokens': context - 10, 'output_tokens': 10}
        say({'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 'ok'}]}})
        say({'type': 'result', 'is_error': kind == 'fails', 'errors': ['boom'], 'result': 'ok',
             'usage': dict(spent, iterations=[spent]), 'modelUsage': window})
        if kind == 'hangs':
            time.sleep(600)

        """
    }

    func set(
        _ name  : String,
        to value: String
    ) throws {
        try Data(value.utf8).write(to: root.appending(path: name))
    }

    func send(_ text: String) async {
        team.draft = text
        await team.send()
    }

    /// What each call to the stand-in was given, in order.
    func calls() throws -> [(arguments: [String], received: String)] {
        let log   = root.appending(path: "log")
        let names = try FileManager.default.contentsOfDirectory(atPath: log.path).sorted()
        return try names.map { name in
            let call = try JSONSerialization.jsonObject(with: Data(contentsOf: log.appending(path: name)))
                as? [String: Any]
            return (call?["arguments"] as? [String] ?? [], call?["received"] as? String ?? "")
        }
    }

    func conversation() throws -> UUID {
        try #require(team.conversation?.id)
    }

    func events(_ type: EventType) async throws -> [RecordedEvent] {
        try await store.events(matching: EventQuery(scope: .conversation(conversation()))).filter { $0.type == type }
    }

    func messages() async throws -> [MessageSnapshot] {
        try await store.messages(in: conversation())
    }

    /// Waits until `condition` holds, ten seconds at most.
    func wait(for condition: () async throws -> Bool) async throws {
        for _ in 0..<1_000 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(try await condition())
    }

    /// Waits until the worker neither answers nor compacts.
    func idle() async throws {
        try await wait { !team.isAnswering(worker) }
    }

    func discard() async {
        await team.closeAgentHosts()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
@Suite("Compacting a worker's context from the team", .serialized)
struct ContextCompactionTeamTests {

    @Test func aCompletedTurnAtNinetyPercentIsCompactedRightAfter() async throws {
        let harness = try await Harness()
        try harness.set(
            "context",
            to: "900"
        )

        await harness.send("Hello")
        try await harness.idle()

        let calls = try harness.calls()
        #expect(calls.map(\.received) == ["Hello", "/compact"])
        #expect(calls.first?.arguments.contains("--disable-slash-commands") == true)
        #expect(calls.last?.arguments.contains("--disable-slash-commands") == false)
        #expect(calls.last.map { Array($0.arguments.drop { $0 != "--resume" }.prefix(2)) } == ["--resume", "s1"])

        let compacted = try await harness.events(.contextCompacted)
        #expect(compacted.count == 1)
        let recorded = try #require(compacted.first?.payload.flatMap(ContextCompaction.decoded))
        #expect(recorded.trigger == .automatic)
        #expect(recorded.postTokens == 120)
        #expect(harness.team.usage[harness.worker]?.context == WorkerUsage.Context(
            tokens: 120,
            window: 1_000
        ))
        #expect(try await harness.messages().map(\.text) == ["Hello", "ok"], "a compaction writes no message")
        #expect(harness.team.problem == nil)
        #expect(!harness.team.isCompacting(harness.worker))
        await harness.discard()
    }

    @Test func aCompletedTurnJustBelowNinetyPercentIsNot() async throws {
        let harness = try await Harness()
        try harness.set(
            "context",
            to: "890"
        )

        await harness.send("Hello")
        try await harness.idle()

        #expect(try harness.calls().map(\.received) == ["Hello"])
        #expect(try await harness.events(.contextCompacted).isEmpty)
        #expect(harness.team.usage[harness.worker]?.context?.fraction == 0.89)
        await harness.discard()
    }

    @Test func aFailedOrStoppedTurnAtNinetyFivePercentIsNot() async throws {
        let harness = try await Harness()
        try harness.set(
            "context",
            to: "950"
        )
        try harness.set(
            "turn",
            to: "fails"
        )
        await harness.send("Hello")
        try await harness.idle()
        #expect(harness.team.usage[harness.worker]?.context?.fraction == 0.95)
        #expect(try harness.calls().count == 1)

        // Stopped once its answer is in, so the context it left is known.
        try harness.set(
            "turn",
            to: "hangs"
        )
        await harness.send("Again")
        try await harness.wait { try await harness.messages().filter { $0.text == "ok" }.count == 2 }
        harness.team.stopAnswering(harness.worker)
        try await harness.idle()

        #expect(harness.team.usage[harness.worker]?.context?.fraction == 0.95)
        #expect(try harness.calls().map(\.received) == ["Hello", "Again"])
        #expect(try await harness.events(.contextCompacted).isEmpty)
        await harness.discard()
    }

    @Test func aMessageSentDuringACompactionWaitsForIt() async throws {
        let harness = try await Harness()
        await harness.send("Hello")
        try await harness.idle()
        try harness.set(
            "compaction",
            to: "hangs"
        )

        harness.team.compactContext(of: harness.worker)
        try await harness.wait { try harness.calls().count == 2 }
        #expect(harness.team.isCompacting(harness.worker))
        #expect(harness.team.isAnswering(harness.worker), "the composer waits as it does behind a turn")

        await harness.send("Next")
        #expect(harness.team.draft == "Next")
        #expect(try await harness.messages().map(\.text) == ["Hello", "ok"])

        harness.team.stopAnswering(harness.worker)
        try await harness.idle()
        #expect(try await harness.events(.contextCompacted).isEmpty)
        #expect(harness.team.problem == nil, "a stopped compaction says nothing")

        await harness.team.send()
        try await harness.idle()
        #expect(try harness.calls().map(\.received) == ["Hello", "/compact", "Next"])
        await harness.discard()
    }

    @Test func aFreshContextForgetsTheSessionSoTheNextTurnStartsANewOne() async throws {
        let harness = try await Harness()
        await harness.send("Hello")
        try await harness.idle()
        await harness.send("Again")
        try await harness.idle()

        await harness.team.startFreshContext(of: harness.worker)
        #expect(try await harness.store.conversation(harness.conversation())?.providerSessionID == nil)
        #expect(try await harness.events(.contextReset).count == 1)
        #expect(harness.team.usage[harness.worker]?.context == nil)

        await harness.send("Start over")
        try await harness.idle()

        let resumed = try harness.calls().map { $0.arguments.contains("--resume") }
        #expect(resumed == [false, true, false])
        #expect(try await harness.messages().count == 6, "the chat stays")
        await harness.discard()
    }

    @Test func aFailedCompactionTellsOnlyThePersonWhoAskedForIt() async throws {
        let harness = try await Harness()
        try harness.set(
            "compaction",
            to: "refused"
        )
        try harness.set(
            "context",
            to: "950"
        )

        await harness.send("Hello")
        try await harness.idle()
        #expect(try harness.calls().map(\.received) == ["Hello", "/compact"])
        #expect(harness.team.problem == nil, "an automatic failure is silent")

        harness.team.compactContext(of: harness.worker)
        try await harness.idle()
        let problem = try #require(harness.team.problem)
        #expect(problem.title == "Couldn’t Compact Context")
        #expect(problem.technicalDetails == "/compact isn't available in this environment.")
        #expect(try await harness.events(.contextCompacted).isEmpty)
        await harness.discard()
    }

    @Test func aSignedOutCommandLineAsksToSignInEvenWhenMecumCompacted() async throws {
        let harness = try await Harness()
        try harness.set(
            "compaction",
            to: "signed-out"
        )
        try harness.set(
            "context",
            to: "950"
        )

        await harness.send("Hello")
        try await harness.idle()

        #expect(harness.team.problem?.title == "Sign In to Claude Code Again")
        #expect(harness.team.connections.states[.claudeCode] == .credentialRejected(
            detail: "Failed to authenticate. API Error: 401"
        ))
        await harness.discard()
    }
}
