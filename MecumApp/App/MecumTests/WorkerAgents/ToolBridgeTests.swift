//
//  ToolBridgeTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import Foundation
import LocalMCP
import Testing
@testable import Mecum

/// The helper the app bundles for a worker's agent, run for real: it reads
/// an MCP request on its standard input, forwards it to a loopback host as
/// the app's own is, writes the answer back, and ends when its input does.
@MainActor
@Suite("The bundled tool bridge")
struct ToolBridgeTests {

    @Test func theBundledBridgeCarriesARequestToTheHostAndItsAnswerBack() async throws {
        let bridge = Bundle.main.bundleURL.appending(path: "Contents/Helpers/mecum-bridge")
        try #require(FileManager.default.isExecutableFile(atPath: bridge.path))

        let host = LocalMCPHost(router: MCPRouter(tools: [.object(["name": .string("status")])]) { _, _ in .null })
        let endpoint = try await host.start()
        defer { host.stop() }

        let file = URL.temporaryDirectory.appending(path: "mecum-bridge-\(UUID().uuidString).json")
        try JSONEncoder().encode(endpoint).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let process = Process()
        let input   = Pipe()
        let output  = Pipe()
        process.executableURL  = bridge
        process.arguments      = ["mcp-bridge", "--connection", file.path]
        process.standardInput  = input
        process.standardOutput = output
        try process.run()

        input.fileHandleForWriting.write(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8) + [10])
        try input.fileHandleForWriting.close()

        // The bridge ends once its input is closed and its last answer written.
        let reading = output.fileHandleForReading
        let answer  = await Task.detached { reading.readDataToEndOfFile() }.value
        process.waitUntilExit()

        let reply = try JSONDecoder().decode(JSONValue.self, from: answer)
        #expect(reply["result"]["tools"].array?.first?["name"].string == "status")
        #expect(process.terminationStatus == 0)
    }
}
