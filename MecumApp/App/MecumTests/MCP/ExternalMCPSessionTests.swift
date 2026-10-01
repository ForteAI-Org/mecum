import AutomationMCP
import Foundation
import LocalMCP
import Memory
import Testing
@testable import Mecum

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ExternalMCPSessionTests {
    private func make(_ profile: MCPClientProfile, desktop: MemoryTestSession = MemoryTestSession(),
                      browser: SyntheticBrowser = SyntheticBrowser(),
                      memory: (any LivingMemoryStoring)? = nil) -> ExternalMCPSession {
        ExternalMCPSession(profile: profile, session: desktop, browser: browser, memory: memory,
                           watcher: WatcherMCPAccess(watcher: WatcherModel()))
    }

    private func request(_ name: String, _ args: [String: JSONValue] = [:]) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
                 "params": .object(["name": .string(name), "arguments": .object(args)])])
    }

    @Test func deniedToolsAreNeitherListedNorDispatched() async throws {
        let browser = SyntheticBrowser()
        let client = make(MCPClientProfile(name: "Read memory", desktop: false, browser: false, sharedMemory: true),
                          browser: browser)
        let list = await client.router.handle(.object(["jsonrpc": .string("2.0"), "id": .number(1),
                                                       "method": .string("tools/list")]))
        let names = list?["result"]["tools"].array?.compactMap { $0["name"].string } ?? []
        #expect(Set(names) == ["task_begin", "task_end", "memory_recall"])
        #expect((await client.router.handle(request("browser_connect")))?["error"] != .null)
        #expect(await browser.connections == 0)
        await client.close()
    }

    @Test func taskBoundariesRejectMissingWrongAndRepeatedRequestsBeforeEffects() async throws {
        let desktop = MemoryTestSession()
        let client = make(MCPClientProfile(name: "Synthetic"), desktop: desktop)
        let select = request("select", ["session": .string(try #require(desktop.id).uuidString),
                                        "control": .string("Mono"), "item": .string("Stereo")])
        #expect((await client.router.handle(select))?["result"]["isError"] == .bool(true))
        #expect(desktop.selections == 0)
        let start = try await client.call("task_begin", .object(["request": .string("Select Stereo")]))
        let task = start["structuredContent"]["task"]
        #expect((await client.router.handle(request("task_begin", ["request": .string("Again")])))?["result"]["isError"] == .bool(true))
        #expect((await client.router.handle(request("task_end", ["task": .string("wrong"), "ending": .string("completed")])))?["result"]["isError"] == .bool(true))
        #expect((await client.router.handle(select))?["result"]["isError"] == .bool(false))
        #expect(desktop.selections == 1)
        _ = try await client.call("task_end", .object(["task": task, "ending": .string("completed")]))
        #expect(desktop.id == nil)
        await client.close()
    }

    @Test func incompleteTaskDoesNotLearnAndBrowserClosesOnDisconnect() async throws {
        let memory = InMemoryLivingMemoryStore()
        let desktop = MemoryTestSession()
        let browser = SyntheticBrowser()
        let client = make(MCPClientProfile(name: "Synthetic", sharedMemory: true), desktop: desktop,
                          browser: browser, memory: memory)
        _ = try await client.call("task_begin", .object(["request": .string("Select Stereo")]))
        _ = try await client.call("select", .object(["session": .string(try #require(desktop.id).uuidString),
                                                       "control": .string("Mono"), "item": .string("Stereo")]))
        _ = try await client.call("browser_connect", .object(["profile": .string("current")]))
        await client.close()
        #expect(desktop.id == nil)
        #expect(await browser.disconnections == 1)
        #expect(try await memory.candidates(for: "Select Stereo", in: nil).isEmpty)
    }

    @Test func sharedMemoryRequiresTypedEvidenceEvenWhenClientClaimsCompletion() async throws {
        for verified in [false, true] {
            let memory = InMemoryLivingMemoryStore()
            let desktop = MemoryTestSession()
            desktop.withEvidence = verified
            let client = make(MCPClientProfile(name: "Synthetic", sharedMemory: true), desktop: desktop, memory: memory)
            let started = try await client.call("task_begin", .object(["request": .string("Select Stereo")]))
            _ = try await client.call("select", .object(["session": .string(try #require(desktop.id).uuidString),
                                                           "control": .string("Mono"), "item": .string("Stereo")]))
            _ = try await client.call("task_end", .object(["task": started["structuredContent"]["task"],
                                                             "ending": .string("completed")]))
            #expect(try await memory.candidates(for: "Select Stereo", in: nil).isEmpty == !verified)
            await client.close()
        }
    }
}
