import AutomationMCP
import BrowserCore
import ChatCore
import Foundation
import LocalMCP
import ModelTransports
import Testing
@testable import Mecum

@MainActor
@Suite("Worker browser integration", .serialized)
struct WorkerBrowserTests {
    private let usage = ModelUsage(inputTokens: nil, outputTokens: nil, duration: .zero)

    private func call(_ name: String, _ args: [String: JSONValue] = [:]) throws -> TurnEvent {
        .toolCall(ToolCall(id: UUID().uuidString, name: name, arguments: try JSONEncoder().encode(JSONValue.object(args))))
    }

    @Test func theAppModelLoopCanUseBrowserToolsWithoutADesktopSession() async throws {
        let browser = SyntheticBrowser()
        let session = DesktopUnavailableSession()
        let transport = BrowserProbeTransport(page: try #require(URL(string: "about:blank")), disconnectOnCompletion: false)
        let worker = WorkerAgentHost(workingDirectory: .temporaryDirectory.appending(path: "browser-worker-\(UUID())"),
            bridgeExecutable: URL(filePath: "/unused"), session: { session }, browser: browser, transports: { _ in transport })
        var events: [WorkerAgentEvent] = []
        try await worker.run(prompt: "Use the synthetic browser", selection: .init(provider: .ollama, model: "synthetic", effort: .medium),
                             sessionID: nil, role: nil) { events.append($0) }
        let clicked = events.contains { event in
            guard case .tool(let text) = event else { return false }
            return text.hasPrefix("← browser_click")
        }
        let answered = events.contains { event in
            guard case .provider(.assistant(let text)) = event else { return false }
            return text == "Synthetic Chrome interaction verified."
        }
        #expect(clicked)
        #expect(answered)
        #expect(session.id == nil)
        #expect(await browser.actions == 1)
        #expect(await browser.disconnections == 0)
        try await worker.close()
        #expect(await browser.disconnections == 1)
    }

    @Test func MCPRegistryDispatchesBrowserAndDoesNotRecordFieldContents() async throws {
        let browser = SyntheticBrowser()
        let tools = AutomationTools(session: DesktopUnavailableSession(), browser: browser)
        var records: [String] = []
        var events: [AutomationEvent] = []
        tools.record = { records.append($0) }
        tools.onEvent = { events.append($0) }
        let router = MCPRouter(tools: AutomationTools.definitions, instructions: ChatInstructions.standard) {
            try await tools.call($0, $1)
        }
        let initialized = await router.handle(.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("initialize")]))
        #expect(initialized?["result"]["instructions"].string?.contains("browser_connect") == true)
        func request(_ name: String, _ args: [String: JSONValue]) -> JSONValue {
            .object(["jsonrpc": .string("2.0"), "id": .number(2), "method": .string("tools/call"),
                "params": .object(["name": .string(name), "arguments": .object(args)])])
        }
        let connected = try #require(await router.handle(request("browser_connect", ["profile": .string("current")])))
        let connection = connected["result"]["structuredContent"]["id"]
        let opened = try #require(await router.handle(request("browser_open", ["connection": connection, "url": .string("about:blank")])))
        let tab = opened["result"]["structuredContent"]
        let response = await router.handle(request("browser_fill", ["connection": connection,
            "tab": tab["id"], "snapshot": tab["observation"]["id"], "ref": .string("e1"), "text": .string("synthetic-private-value")]))
        #expect(response?["result"]["structuredContent"]["status"].string == "verified")
        #expect(!records.joined().contains("synthetic-private-value"))
        #expect(events.count == 3)
        for event in events {
            guard case .unknown = event.operation else { Issue.record("Browser input became a native memory step"); continue }
        }
        try await tools.closeBrowser()
    }

    @Test func screenshotsAreNotSilentlyDiscardedByTextOnlyModelTransport() async throws {
        let transport = MemoryTestTransport(supportsTools: true, rounds: [
            [try call("browser_screenshot", ["connection": .string("old"), "tab": .string("tab")]), .completed(usage)],
            [.delta("Use semantic snapshot"), .completed(usage)]
        ])
        var called = false
        let loop = ModelToolLoop { _, _ in called = true; return .null }
        try await loop.run(transport: transport, role: nil, history: [], prompt: "Read a page") { _ in }
        #expect(!called)
        #expect(transport.sent.last?.messages.last?.isError == true)
        #expect(transport.sent.last?.messages.last?.text.contains("text tool results") == true)
    }


    @Test func stoppingAConnectedWorkerReleasesItsBrowserLease() async throws {
        let backend = SyntheticBrowser()
        let pool = BrowserSessionPool { backend }
        let transport = MemoryTestTransport(supportsTools: true, rounds: [
            [try call("browser_connect", ["profile": .string("current")]), .completed(usage)]
        ])
        let worker = WorkerAgentHost(workingDirectory: .temporaryDirectory.appending(path: "browser-stop-\(UUID())"),
            bridgeExecutable: URL(filePath: "/unused"), session: { DesktopUnavailableSession() },
            browser: pool.client(), transports: { _ in transport })
        let run = Task {
            try await worker.run(prompt: "Synthetic wait", selection: .init(provider: .ollama, model: "synthetic", effort: .medium),
                sessionID: nil, role: nil) { _ in }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while transport.sent.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(transport.sent.count == 2)
        worker.stop()
        do { try await run.value; Issue.record("A stopped worker completed") } catch is CancellationError {}
        #expect(await backend.disconnections == 1)
        let next = pool.client()
        _ = try await next.connect(profile: .current)
        try await next.disconnect()
        try await worker.close()
    }

    @Test func browserTranscriptNamesActionsAndShowsUnverifiedEffects() {
        let steps = ToolStep.steps(from: ["→ browser_snapshot {}", "← browser_snapshot {\"status\":\"returned\"}",
            "→ browser_click {}", "← browser_click {\"status\":\"delivered\"}",
            "→ browser_fill {}", "← browser_fill {\"status\":\"unverified\",\"message\":\"Value changed\"}"])
        #expect(!steps[0].isEffectful)
        #expect(TranscriptWording.toolStep(steps[0], ending: .completed) == "Read the browser page")
        #expect(TranscriptWording.toolStep(steps[1], ending: .completed) == "Sent a browser click")
        #expect(steps[2].state == .failed(reason: "Value changed"))
    }
}
