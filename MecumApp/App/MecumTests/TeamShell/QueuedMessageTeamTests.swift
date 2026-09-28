//
//  QueuedMessageTeamTests.swift
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

/// Two workers on a stand-in Claude Code, driven through `TeamModel` as the
/// composer and its queue strip drive it. Each call to the stand-in waits for
/// a `go-N` file, N its place among the calls, then answers "ok", or compacts
/// when it was sent `/compact`. A turn answers with the context in the
/// `context` file against a 1,000 token window, and fails when the `turn`
/// file says `fails`. So a test decides when each turn ends, and how.
@MainActor
private final class Harness {

    let root       : URL
    let store      : WorkspaceStore
    let team       : TeamModel
    let atlas      : UUID
    let nova       : UUID
    let agent      : URL
    let preferences: UserDefaults

    private let suite: String

    init() async throws {
        suite       = "mecum-team-queue-\(UUID().uuidString)"
        preferences = try #require(UserDefaults(suiteName: suite))
        root        = URL.temporaryDirectory.appending(path: "mecum-team-queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at                         : root.appending(path: "log"),
            withIntermediateDirectories: true
        )
        agent = root.appending(path: "claude")
        try Data(Self.standIn(root).utf8).write(to: agent)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: agent.path
        )

        store = try WorkspaceStore.opening(in: root.appending(path: "store"))
        atlas = try await Self.worker(
            "Atlas",
            in: store
        )
        nova  = try await Self.worker(
            "Nova",
            in: store
        )
        team  = await Self.team(
            over       : store,
            agent      : agent,
            preferences: preferences,
            selecting  : atlas
        )
    }

    private static func worker(
        _ name  : String,
        in store: WorkspaceStore
    ) async throws -> UUID {
        let id = try await store.createWorker(
            name      : name,
            appearance: TemporaryStore.appearance()
        ).id
        try await store.configure(
            worker   : id,
            selection: ModelSelection(
                provider: .claudeCode,
                model   : "claude-sonnet-5",
                effort  : .low
            )
        )
        return id
    }

    /// A team over `store` with the stand-in agent, and `worker`'s conversation open.
    static func team(
        over store      : WorkspaceStore,
        agent           : URL,
        preferences     : UserDefaults,
        selecting worker: UUID
    ) async -> TeamModel {
        let team = TeamModel(
            store           : store,
            connections     : ModelSettingsStore(),
            broker          : SeatBroker(),
            agents          : { _ in (.claude, agent) },
            bridgeExecutable: agent,
            preferences     : preferences
        )
        await team.load()
        team.selection = worker
        await team.openSelectedConversation()
        return team
    }

    private static func standIn(_ root: URL) -> String {
        """
        #!/usr/bin/python3
        import json, os, sys, time
        root = '\(root.path)'
        received = sys.stdin.read()
        log = os.path.join(root, 'log')
        call = len(os.listdir(log))
        with open(os.path.join(log, '%03d.json' % call), 'w') as file:
            json.dump({'received': received}, file)
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
        while not os.path.exists(os.path.join(root, 'go-%d' % call)):
            time.sleep(0.01)
        if received == '/compact':
            say({'type': 'system', 'subtype': 'compact_boundary',
                 'compact_metadata': {'trigger': 'manual', 'pre_tokens': 950, 'post_tokens': 120}})
            say({'type': 'result', 'is_error': False, 'result': '', 'num_turns': 0,
                 'usage': {'input_tokens': 0, 'output_tokens': 0, 'iterations': []}, 'modelUsage': window})
            sys.exit(0)
        context = int(setting('context', '100'))
        spent = {'input_tokens': context - 10, 'output_tokens': 10}
        say({'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 'ok'}]}})
        say({'type': 'result', 'is_error': setting('turn', 'completes') == 'fails', 'errors': ['boom'],
             'result': 'ok', 'usage': dict(spent, iterations=[spent]), 'modelUsage': window})

        """
    }

    func set(
        _ name  : String,
        to value: String
    ) throws {
        try Data(value.utf8).write(to: root.appending(path: name))
    }

    /// Lets the stand-in's call number `call` answer.
    func go(_ call: Int) throws {
        try set(
            "go-\(call)",
            to: ""
        )
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

    /// What each call to the stand-in was sent, in order.
    func calls() throws -> [String] {
        let log   = root.appending(path: "log")
        let names = try FileManager.default.contentsOfDirectory(atPath: log.path).sorted()
        return try names.map { name in
            let call = try JSONSerialization.jsonObject(with: Data(contentsOf: log.appending(path: name)))
                as? [String: Any]
            return call?["received"] as? String ?? ""
        }
    }

    /// Atlas's direct conversation.
    func atlasConversation() async throws -> ConversationSnapshot {
        try #require(try await store.conversations().first { $0.participantIDs == [atlas] })
    }

    /// What the person wrote in Atlas's conversation, in order.
    func personMessages() async throws -> [String] {
        try await store.messages(in: atlasConversation().id)
            .filter { $0.authorWorkerID == nil }
            .map(\.text)
    }

    /// The texts of the open conversation's queue, in order.
    var queued: [String] { team.queue.map(\.text) }

    /// The texts of Atlas's queue as the store holds it.
    func storedQueue() async throws -> [String] {
        try await atlasConversation().queue.map(\.text)
    }

    /// Waits until `condition` holds, ten seconds at most.
    func wait(for condition: () async throws -> Bool) async throws {
        for _ in 0..<1_000 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(try await condition())
    }

    /// Waits until the stand-in has been called `count` times.
    func waitForCalls(_ count: Int) async throws {
        try await wait { try calls().count == count }
    }

    /// Waits until Atlas neither answers nor compacts.
    func idle() async throws {
        try await wait { !team.isAnswering(atlas) }
    }

    /// Long enough for a send that should not happen to show up.
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
@Suite("Queueing messages while a worker answers", .serialized)
struct QueuedMessageTeamTests {

    private static func quote(_ text: String) -> MessageQuote {
        MessageQuote(
            messageID     : UUID(),
            authorWorkerID: nil,
            text          : text
        )
    }

    @Test("A send while the worker answers queues the draft with its quote, empties it, and starts nothing")
    func aSendWhileAnsweringQueues() async throws {
        let harness = try await Harness()
        await harness.send("one")
        try await harness.waitForCalls(1)
        #expect(harness.team.isAnswering(harness.atlas))

        let quote = Self.quote("Two bundles failed.")
        await harness.send(
            "two",
            quoting: quote
        )

        #expect(harness.team.draft.isEmpty)
        #expect(harness.team.draftQuote == nil)
        #expect(harness.team.queue == [QueuedMessage(
            text : "two",
            quote: quote
        )])
        let stored = try await harness.atlasConversation()
        #expect(stored.queue == harness.team.queue)
        #expect(stored.draft.isEmpty)
        #expect(stored.draftQuote == nil)
        #expect(try await harness.personMessages() == ["one"])
        #expect(try harness.calls() == ["one"])
        #expect(harness.team.problem == nil)
        await harness.discard()
    }

    @Test("The pager moves through the queue and wraps from the last to the first")
    func thePagerWraps() async throws {
        let harness = try await Harness()
        await harness.send("one")
        try await harness.waitForCalls(1)
        await harness.send("two")
        await harness.send("three")
        await harness.send("four")

        var shown: [Int] = [harness.team.shownQueuedIndex]
        for _ in 0..<3 {
            harness.team.showNextQueued()
            shown.append(harness.team.shownQueuedIndex)
        }
        #expect(shown == [0, 1, 2, 0])
        await harness.discard()
    }

    @Test("A completed turn sends the shown queued message, with its quote, and keeps the rest")
    func completionSendsTheShownMessageOnly() async throws {
        let harness = try await Harness()
        await harness.send("one")
        try await harness.waitForCalls(1)
        let quote = Self.quote("Capture\nand layout.")
        await harness.send("two")
        await harness.send(
            "three",
            quoting: quote
        )
        await harness.send("four")
        harness.team.showNextQueued()
        #expect(harness.team.queue[harness.team.shownQueuedIndex].text == "three")

        try harness.go(0)
        try await harness.waitForCalls(2)

        #expect(try harness.calls() == ["one", "> Capture\n> and layout.\n\nthree"])
        #expect(try await harness.personMessages() == ["one", "three"])
        let sent = try await harness.store.messages(in: harness.atlasConversation().id).last
        #expect(sent?.quote == quote)
        #expect(harness.queued == ["two", "four"])
        #expect(harness.team.shownQueuedIndex == 0, "the strip shows the first that remains")
        try await harness.wait { try await harness.storedQueue() == ["two", "four"] }
        #expect(harness.team.isAnswering(harness.atlas))
        await harness.discard()
    }

    @Test("A stopped turn and a failed turn send nothing, and the queue stays")
    func stopAndFailureSendNothing() async throws {
        let harness = try await Harness()
        await harness.send("one")
        try await harness.waitForCalls(1)
        await harness.send("two")

        harness.team.stopAnswering(harness.atlas)
        try await harness.idle()
        try await harness.settle()
        #expect(try harness.calls() == ["one"])
        #expect(harness.queued == ["two"])

        // A message sent while nothing runs goes out at once; its turn fails.
        try harness.set(
            "turn",
            to: "fails"
        )
        await harness.send("again")
        try await harness.waitForCalls(2)
        try harness.go(1)
        try await harness.idle()
        try await harness.settle()

        #expect(try harness.calls() == ["one", "again"])
        #expect(try await harness.personMessages() == ["one", "again"])
        #expect(harness.queued == ["two"])
        #expect(try await harness.storedQueue() == ["two"])
        await harness.discard()
    }

    @Test("Send Now stops the running turn, then sends the shown message at once")
    func sendNowStopsThenSends() async throws {
        let harness = try await Harness()
        await harness.send("one")
        try await harness.waitForCalls(1)
        await harness.send("two")
        await harness.send("three")

        await harness.team.sendQueuedNow()
        try await harness.waitForCalls(2)

        #expect(try harness.calls() == ["one", "two"])
        #expect(try await harness.personMessages() == ["one", "two"])
        #expect(harness.queued == ["three"])
        #expect(harness.team.isAnswering(harness.atlas))
        let cancelled = try await harness.store.events(matching: EventQuery(
            scope: .conversation(harness.atlasConversation().id)
        )).filter { $0.type == .executionCancelled }
        #expect(cancelled.count == 1, "the first turn was stopped, not completed")
        await harness.discard()
    }

    @Test("A turn that ends while another worker is on screen still sends its conversation's queued message")
    func theQueueRunsOffScreen() async throws {
        let harness = try await Harness()
        await harness.send("one")
        try await harness.waitForCalls(1)
        await harness.send("two")

        harness.team.selection = harness.nova
        await harness.team.openSelectedConversation()
        #expect(harness.team.queue.isEmpty, "Nova's conversation has its own queue")

        try harness.go(0)
        try await harness.waitForCalls(2)

        #expect(try harness.calls() == ["one", "two"])
        #expect(try await harness.personMessages() == ["one", "two"])
        #expect(harness.team.conversation?.participantIDs == [harness.nova])
        try await harness.wait { try await harness.storedQueue().isEmpty }
        await harness.discard()
    }

    @Test("Editing a queued message moves its text before the draft and its quote into it, unless the draft has one")
    func editingMovesTheMessageBack() async throws {
        let harness = try await Harness()
        await harness.send("one")
        try await harness.waitForCalls(1)
        let first  = Self.quote("capture")
        let second = Self.quote("layout")
        await harness.send(
            "two",
            quoting: first
        )
        await harness.send(
            "three",
            quoting: second
        )

        await harness.team.editShownQueued()
        #expect(harness.team.draft == "two")
        #expect(harness.team.draftQuote == first)
        #expect(harness.queued == ["three"])

        await harness.team.editShownQueued()
        #expect(harness.team.draft == "three\ntwo")
        #expect(harness.team.draftQuote == first, "the draft kept the quote it had")
        #expect(harness.queued.isEmpty)

        let stored = try await harness.atlasConversation()
        #expect(stored.draft == "three\ntwo")
        #expect(stored.draftQuote == first)
        #expect(stored.queue.isEmpty)
        #expect(try harness.calls() == ["one"])
        await harness.discard()
    }

    @Test("After an automatic compaction the queued message waits for it to end, then goes")
    func theSendWaitsForTheAutomaticCompaction() async throws {
        let harness = try await Harness()
        try harness.set(
            "context",
            to: "900"
        )
        await harness.send("one")
        try await harness.waitForCalls(1)
        await harness.send("two")

        try harness.go(0)
        try await harness.waitForCalls(2)
        try await harness.settle()
        #expect(try harness.calls() == ["one", "/compact"])
        #expect(harness.team.isCompacting(harness.atlas))
        #expect(harness.queued == ["two"])
        #expect(try await harness.personMessages() == ["one"])

        try harness.set(
            "context",
            to: "100"
        )
        try harness.go(1)
        try await harness.waitForCalls(3)

        #expect(try harness.calls() == ["one", "/compact", "two"])
        #expect(!harness.team.isCompacting(harness.atlas))
        #expect(harness.queued.isEmpty)
        await harness.discard()
    }

    @Test("After a relaunch the queue shows and nothing goes out until Send Now")
    func aRelaunchSendsNothing() async throws {
        let harness = try await Harness()
        await harness.send("one")
        try await harness.waitForCalls(1)
        await harness.send("two")
        await harness.send("three")
        await harness.team.closeAgentHosts()
        try await harness.idle()

        let relaunched = await Harness.team(
            over       : try WorkspaceStore.opening(in: harness.root.appending(path: "store")),
            agent      : harness.agent,
            preferences: harness.preferences,
            selecting  : harness.atlas
        )
        #expect(relaunched.queue.map(\.text) == ["two", "three"])
        #expect(relaunched.shownQueuedIndex == 0)
        try await harness.settle()
        #expect(try harness.calls() == ["one"])

        await relaunched.sendQueuedNow()
        try await harness.waitForCalls(2)
        #expect(try harness.calls() == ["one", "two"])
        #expect(relaunched.queue.map(\.text) == ["three"])

        await relaunched.closeAgentHosts()
        await harness.discard()
    }
}
