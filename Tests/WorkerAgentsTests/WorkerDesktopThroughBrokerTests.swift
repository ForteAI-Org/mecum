//
//  WorkerDesktopThroughBrokerTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import ChatCore
import Foundation
import ModelTransports
import SeatBroker
import Testing
import WorkerAgents

/// A worker's turn through the real `claude` CLI, with the broker's session behind its tools:
/// the agent opens Calculator on the broker's seat, clicks through Ron's engine, and the Brain
/// writes what it saw.
///
/// Gated by `AGENTSEAT_LIVE_TESTS=1`, and named apart from the Driver's Live tier so that
/// `make live-tests`, which filters on `LiveTests` and asserts a count, does not pick it up. It
/// needs a signed-in `claude`, the built `mecum` bridge (`.build/debug/mecum`, or
/// `MECUM_TEST_BRIDGE`), Screen Recording, Accessibility and Post Event for the process running
/// the tests, an awake display, nobody driving the machine, and Calculator not running: the broker
/// quits only what it opened. Vision's text models do not load on some Macs, so an act that comes
/// back unverified is expected and is not a failure here.
@MainActor
@Suite(
    "A worker's desktop through the broker, live",
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["AGENTSEAT_LIVE_TESTS"] == "1",
        "AGENTSEAT_LIVE_TESTS=1 is required: this opens Calculator and clicks in it on a seat."
    )
)
struct WorkerDesktopThroughBrokerTests {

    @Test("the agent opens Calculator through the queue, presses 8, answers, and the seat goes back")
    func theAgentUsesTheBrokersSeat() async throws {
        let environment = ProcessInfo.processInfo.environment
        let bridge = URL(fileURLWithPath: environment["MECUM_TEST_BRIDGE"]
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent(".build/debug/mecum").path)
        let scratch   = URL.temporaryDirectory.appending(path: "mecum-worker-desktop-\(UUID().uuidString)")
        let knowledge = scratch.appending(path: "Knowledge", directoryHint: .isDirectory)
        // A test process has no event loop of its own, and a virtual display appears only while one turns.
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()

        let broker = SeatBroker(configuration: SeatBrokerConfiguration(
            allowUnvalidatedBuild: true,
            recordingDirectory   : scratch.appending(path: "Runs", directoryHint: .isDirectory)
        ))
        let isRunning = broker.runningTargets().contains {
            $0.pid != nil && $0.name.caseInsensitiveCompare("Calculator") == .orderedSame
        }
        try #require(!isRunning, "Calculator is already running: quit it, so the row acts only on what it opened")

        let desktop = BrokeredAutomationSession(broker: broker, workerID: UUID(), knowledgeDirectory: knowledge)
        let host = WorkerAgentHost(workingDirectory: scratch.appending(path: "work"), bridgeExecutable: bridge,
                                   session: { desktop })
        var tools  : [String] = []
        var replies: [String] = []
        var failure: (any Error)?
        let receive: @MainActor (WorkerAgentEvent) -> Void = { event in
            switch event {
            case .tool(let text):                 tools.append(text)
            case .provider(.assistant(let text)): replies.append(text)
            case .provider, .processStarted:      break
            }
        }
        do {
            try await host.run(
                prompt   : "open Calculator and press 8",
                selection: ModelSelection(provider: .claudeCode, model: "claude-sonnet-5", effort: .low),
                sessionID: nil,
                role     : "Answer in one short sentence.",
                onEvent  : receive
            )
        } catch {
            failure = error
        }
        print("WORKER tools:", tools.map { String($0.prefix(200)) })
        print("WORKER replies:", replies)
        print("WORKER row at the end of the turn:", desktop.activity ?? "nil")
        try await host.close()
        print("WORKER queue after close:", broker.queue.entries.map(\.label))
        // An absent directory is the Brain having written nothing, which the expectation below reports.
        let learned = FileManager.default.fileExists(atPath: knowledge.path)
            ? try FileManager.default.contentsOfDirectory(atPath: knowledge.path) : []
        print("WORKER knowledge files:", learned)
        await broker.queue.shutdown()
        let cleanup = Result { try FileManager.default.removeItem(at: scratch) }
        if let failure { throw failure }
        try cleanup.get()

        let opened = try #require(tools.firstIndex { $0.hasPrefix("→ open_session") }, "no open_session call")
        let clicks = tools.indices.filter { index in
            let line = tools[index]
            let isAct = line.hasPrefix("→ act") && (!line.contains("\"verb\"") || line.contains("\"verb\":\"click\""))
            return isAct || (line.hasPrefix("→ batch") && line.contains("\"operation\":\"act\""))
        }
        #expect(clicks.contains { $0 > opened }, "no click after open_session")
        #expect(!replies.isEmpty, "no answer arrived")
        #expect(broker.queue.entries.isEmpty, "the lease is still held after the host closed")
        #expect(learned.contains { $0.lowercased().contains("calculator") && $0.hasSuffix(".json") },
                "the Brain wrote no knowledge file for Calculator")
    }
}
