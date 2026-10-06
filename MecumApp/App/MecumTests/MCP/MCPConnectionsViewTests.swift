import Foundation
import LocalMCP
import SwiftUI
import Testing
@testable import Mecum

@MainActor
struct MCPConnectionsViewTests {
    @Test func rendersEmptyAndConfiguredConnectionsAtMinimumWidth() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("mcp-view-" + UUID().uuidString)
        let model = MCPConnectionsModel(directory: root, executable: URL(filePath: "/usr/bin/true")) { _, _ in
            MCPHostSession(router: MCPRouter(tools: []) { _, _ in .null })
        }
        await model.prepare()
        let empty = root.appendingPathComponent("empty.png")
        try await WindowSnapshots.write(MCPConnectionsView(model: model), width: 610, height: 750, dark: true, to: empty)
        model.add(MCPClientProfile(name: "Synthetic Claude Code"))
        await model.waitForIdle()
        let configured = root.appendingPathComponent("configured.png")
        try await WindowSnapshots.write(MCPConnectionsView(model: model), width: 610, height: 950, dark: false, to: configured)
        #expect(try Data(contentsOf: empty).count > 1000)
        #expect(try Data(contentsOf: configured).count > 1000)
        print("MCP_VIEW_SNAPSHOTS \(root.path)")
        await model.shutdown()
    }
}
