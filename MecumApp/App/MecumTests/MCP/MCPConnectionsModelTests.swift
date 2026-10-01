import Foundation
import LocalMCP
import Testing
@testable import Mecum

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MCPConnectionsModelTests {
    private func model(_ root: URL) -> MCPConnectionsModel {
        MCPConnectionsModel(directory: root, executable: URL(filePath: "/usr/bin/true")) { _, _, _ in
            MCPHostSession(router: MCPRouter(tools: []) { _, _ in .null })
        }
    }

    @Test func grantsStartDisabledPersistRestoreRotateAndRevoke() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("mcp-model-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = model(root)
        await first.prepare()
        #expect(first.isReady)
        let profile = MCPClientProfile(name: "Synthetic Client")
        first.add(profile)
        await first.waitForIdle()
        let entry = try #require(first.clients.first)
        #expect(!entry.isListening)
        let path = first.configuration(for: profile.id).connection
        #expect(!FileManager.default.fileExists(atPath: path.path))
        first.setEnabled(true, for: profile.id)
        await first.waitForIdle()
        #expect(entry.isListening)
        let initial = try JSONDecoder().decode(LocalConnection.self, from: Data(contentsOf: path))
        await first.shutdown()
        #expect(!FileManager.default.fileExists(atPath: path.path))
        let second = model(root)
        await second.prepare()
        #expect(second.clients.first?.isListening == true)
        let renewed = try JSONDecoder().decode(LocalConnection.self, from: Data(contentsOf: path))
        #expect(initial.token != renewed.token)
        second.revoke(profile.id)
        await second.waitForIdle()
        #expect(second.clients.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(try MCPClientStore(directory: root).load().isEmpty)
        await second.shutdown()
    }

    @Test func corruptRegistryAndSecondInstanceDoNotOverwriteGrants() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("mcp-model-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = model(root)
        await first.prepare()
        let second = model(root)
        await second.prepare()
        #expect(!second.isReady)
        #expect(second.issue != nil)
        await second.shutdown()
        await first.shutdown()
        let file = root.appendingPathComponent("clients.json")
        let bytes = Data("corrupt fixture".utf8)
        try bytes.write(to: file)
        let third = model(root)
        await third.prepare()
        #expect(!third.isReady)
        #expect(third.issue != nil)
        third.add(MCPClientProfile(name: "Must not overwrite"))
        await third.waitForIdle()
        #expect(try Data(contentsOf: file) == bytes)
        await third.shutdown()
    }

    @Test(arguments: [false, true])
    func stopAndRevokeCloseAdmissionEvenWhenPersistenceFails(revoke: Bool) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("mcp-model-failure-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(root)
        await model.prepare()
        let profile = MCPClientProfile(name: "Synthetic")
        model.add(profile)
        await model.waitForIdle()
        model.setEnabled(true, for: profile.id)
        await model.waitForIdle()
        #expect(model.clients.first?.isListening == true)
        let registry = root.appendingPathComponent("clients.json")
        try FileManager.default.removeItem(at: registry)
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: false)
        if revoke { model.revoke(profile.id) } else { model.setEnabled(false, for: profile.id) }
        await model.waitForIdle()
        #expect(model.clients.first?.isListening == false)
        #expect(!FileManager.default.fileExists(atPath: model.configuration(for: profile.id).connection.path))
        #expect(model.issue?.contains("may restore on restart") == true)
        #expect(model.clients.count == 1)
        await model.shutdown()
    }

    @Test func configurationKeepsSpacesAndQuotesAndContainsNoCredential() throws {
        let configuration = MCPClientConfiguration(executable: URL(filePath: "/tmp/Mecum Test's.app/bridge"),
                                                   connection: URL(filePath: "/tmp/Application Support/client.json"))
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(configuration.json.utf8))
        #expect(value["mcpServers"]["mecum"]["args"].array?.last?.string == configuration.connection.path)
        #expect(value["mcpServers"]["mecum"]["command"].string == configuration.executable.path)
        #expect(configuration.invocation.contains("'\"'\"'"))
        #expect(!configuration.json.contains("token"))
    }
}
