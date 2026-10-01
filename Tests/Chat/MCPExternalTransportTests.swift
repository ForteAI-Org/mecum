import Foundation
@testable import LocalMCP
import Network
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MCPExternalTransportTests {
    private func request(_ method: String, id: Int = 1) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method),
                 "params": .object(["name": .string("slow"), "arguments": .object([:])])])
    }

    @Test func disconnectCancelsAnActiveToolAndJoinsCleanupBeforeReconnect() async throws {
        var created = 0
        var started = false
        var cancelled = false
        var closed = 0
        var connected = 0
        let host = LocalMCPHost(maximumConnections: 1) {
            created += 1
            let router = MCPRouter(tools: [.object(["name": .string("slow")])]) { _, _ in
                started = true
                do { try await Task.sleep(for: .seconds(30)) }
                catch { cancelled = true; throw error }
                return .null
            }
            return MCPHostSession(router: router) { closed += 1 }
        }
        host.onConnectionCount = { connected = $0 }
        let endpoint = try await host.start()
        let channel = try await connect(endpoint)
        try await channel.write(.object(["token": .string(endpoint.token), "message": request("tools/call")]))
        while !started { await Task.yield() }
        #expect(connected == 1)
        channel.close()
        while closed == 0 || connected != 0 { await Task.yield() }
        #expect(cancelled)
        let next = try await connect(endpoint)
        try await next.write(.object(["token": .string(endpoint.token), "message": request("ping")]))
        #expect(try await next.read()?["result"] == .object([:]))
        #expect(created == 2)
        await host.stopAndDrain()
        #expect(closed == 2)
        next.close()
    }

    @Test func invalidCredentialsNeverCreateAnEngineAndOneClientCannotTakeOver() async throws {
        var created = 0
        let host = LocalMCPHost(maximumConnections: 1) {
            created += 1
            return MCPHostSession(router: MCPRouter(tools: []) { _, _ in .null })
        }
        let endpoint = try await host.start()
        let bad = try await connect(endpoint)
        try await bad.write(.object(["token": .string("wrong"), "message": request("initialize")]))
        #expect(try await bad.read() == nil)
        bad.close()
        #expect(created == 0)
        let first = try await connect(endpoint)
        try await first.write(.object(["token": .string(endpoint.token), "message": request("initialize")]))
        #expect(try await first.read()?["result"]["serverInfo"]["name"] == .string("mecum"))
        let second = try await connect(endpoint)
        do {
            try await second.write(.object(["token": .string(endpoint.token), "message": request("initialize")]))
            #expect(try await second.read() == nil)
        } catch { /* A refused socket can fail its write or its read. */ }
        #expect(created == 1)
        second.close()
        await host.stopAndDrain()
        first.close()
    }

    @Test func cancellationMatchesOnlyTheActiveRequest() async throws {
        var started = false
        let router = MCPRouter(tools: [.object(["name": .string("slow")])]) { _, _ in
            started = true
            try await Task.sleep(for: .seconds(30))
            return .null
        }
        let running = Task { await router.handle(request("tools/call", id: 42)) }
        while !started { await Task.yield() }
        func cancel(_ id: Int) -> JSONValue {
            .object(["jsonrpc": .string("2.0"), "method": .string("notifications/cancelled"),
                     "params": .object(["requestId": .number(Double(id))])])
        }
        #expect(await router.handle(cancel(41)) == nil)
        #expect((await router.handle(request("tools/call", id: 43)))?["error"] != .null)
        #expect(await router.handle(cancel(42)) == nil)
        #expect((await running.value)?["result"]["isError"] == .bool(true))
        #expect(router.isAcceptingTools)
    }

    @Test func directoryLeaseProtectsCredentialsAndFilesArePrivate() throws {
        let root = URL.temporaryDirectory.appendingPathComponent("mcp-directory-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = MCPConnectionDirectory(url: root)
        let second = MCPConnectionDirectory(url: root)
        try first.acquire()
        defer { first.release(); second.release() }
        #expect(throws: (any Error).self) { try second.acquire() }
        let id = UUID()
        try first.publish(LocalConnection(port: 1234, token: "synthetic-1"), for: id)
        let permissions = try FileManager.default.attributesOfItem(atPath: first.endpoint(for: id).path)
        #expect(permissions[.posixPermissions] as? Int == 0o600)
        #expect(throws: (any Error).self) { try second.remove(id) }
        first.release()
        try second.acquire()
        try second.publish(LocalConnection(port: 1235, token: "synthetic-2"), for: id)
        let restored = try JSONDecoder().decode(LocalConnection.self, from: Data(contentsOf: second.endpoint(for: id)))
        #expect(restored.token == "synthetic-2")
        try second.remove(id)
        #expect(!FileManager.default.fileExists(atPath: second.endpoint(for: id).path))
    }

    @Test func stdinHandlesPartialFramesAndStoppingAnIdleReader() async throws {
        let pipe = Pipe()
        let input = MCPInputLines(descriptor: pipe.fileHandleForReading.fileDescriptor)
        var iterator = input.values.makeAsyncIterator()
        try pipe.fileHandleForWriting.write(contentsOf: Data("{\"id\":".utf8))
        try pipe.fileHandleForWriting.write(contentsOf: Data("1}\n{\"id\":2}\n".utf8))
        #expect(try await iterator.next()?["id"] == .number(1))
        #expect(try await iterator.next()?["id"] == .number(2))
        input.stop()
        #expect(try await iterator.next() == nil)
        try pipe.fileHandleForWriting.close()
        try pipe.fileHandleForReading.close()
    }

    @Test func stdinRejectsAnIncompleteFrameAtEOF() async throws {
        let pipe = Pipe()
        let input = MCPInputLines(descriptor: pipe.fileHandleForReading.fileDescriptor)
        try pipe.fileHandleForWriting.write(contentsOf: Data("{\"id\":1".utf8))
        try pipe.fileHandleForWriting.close()
        do {
            for try await _ in input.values {}
            Issue.record("An unterminated frame was accepted.")
        } catch { #expect((error as? CocoaError)?.code == .fileReadCorruptFile) }
        try pipe.fileHandleForReading.close()
    }

    @Test func closingBeforeStartupDoesNotStrandAContinuation() async throws {
        let channel = MCPChannel(NWConnection(host: "127.0.0.1", port: 1, using: .tcp))
        channel.close()
        await #expect(throws: CancellationError.self) { try await channel.start() }
    }

    private func connect(_ endpoint: LocalConnection) async throws -> MCPChannel {
        let port = try #require(NWEndpoint.Port(rawValue: endpoint.port))
        let channel = MCPChannel(NWConnection(host: "127.0.0.1", port: port, using: .tcp))
        try await channel.start()
        return channel
    }
}
