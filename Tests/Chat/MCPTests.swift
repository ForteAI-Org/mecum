import Foundation
@testable import LocalMCP
import Network
import Testing

@Suite("Local MCP lifecycle")
struct MCPTests {
    private let definition: JSONValue = .object(["name": .string("observe")])

    private func request(_ method: String, id: Int = 1) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method),
                 "params": .object(["name": .string("observe"), "arguments": .object([:])])])
    }

    @Test
    func initializeNegotiatesAndNotificationsHaveNoResponse() async throws {
        let router = MCPRouter(tools: [definition]) { _, _ in .object([:]) }
        let initialized = try #require(await router.handle(request("initialize")))
        #expect(initialized["result"]["protocolVersion"].string == "2025-11-25")
        #expect(await router.handle(.object(["jsonrpc": .string("2.0"),
                                            "method": .string("notifications/initialized")])) == nil)
        let missing = try #require(await router.handle(request("unsupported")))
        #expect(missing["error"]["code"] == .number(-32601))
    }

    @Test
    func concurrentActionsAreRejectedAndPauseCancelsThenDrains() async throws {
        var calls = 0
        let router = MCPRouter(tools: [definition]) { _, _ in
            calls += 1
            try await Task.sleep(for: .seconds(30))
            return .object([:])
        }
        let first = Task { await router.handle(request("tools/call")) }
        while calls == 0 { await Task.yield() }
        let second = try #require(await router.handle(request("tools/call", id: 2)))
        #expect(second["error"]["message"].string?.contains("still running") == true)
        #expect(calls == 1)
        router.pause()
        await router.drain()
        let interrupted = try #require(await first.value)
        #expect(interrupted["result"]["isError"].bool == true)
        #expect((await router.handle(request("tools/call")))?["error"]["message"].string?.contains("stopping") == true)
    }

    @Test
    func loopbackAuthenticationAndReconnect() async throws {
        var calls = 0
        let router = MCPRouter(tools: [definition]) { _, _ in
            calls += 1
            return MCPRouter.toolResult(.object(["status": .string("ok")]))
        }
        let host = LocalMCPHost(router: router)
        let endpoint = try await host.start()
        defer { host.stop() }
        let port = try #require(NWEndpoint.Port(rawValue: endpoint.port))
        let bad = MCPChannel(NWConnection(host: "127.0.0.1", port: port, using: .tcp))
        try await bad.start()
        try await bad.write(.object(["token": .string("wrong"), "message": request("tools/call")]))
        #expect(try await bad.read() == nil)
        bad.close()
        #expect(calls == 0)
        for _ in 0..<2 {
            let channel = MCPChannel(NWConnection(host: "127.0.0.1", port: port, using: .tcp))
            try await channel.start()
            try await channel.write(.object(["token": .string(endpoint.token), "message": request("tools/call")]))
            let answer = try #require(try await channel.read())
            #expect(answer["result"]["structuredContent"] == .null)
            #expect(answer["result"].payload["status"].string == "ok")
            channel.close()
        }
        #expect(calls == 2)
    }
}

extension JSONValue {

    /// A tool result's value as the model reads it: the JSON text of its one content item, or null
    /// when that text is missing or is not JSON.
    var payload: JSONValue {
        guard let text = self["content"].array?.first?["text"].string,
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        else { return .null }
        return value
    }
}
