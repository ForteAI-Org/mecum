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

        // A bridge that never answers would hold the reads below: ended after a bound, it fails the test.
        let watchdog = Task { try await Task.sleep(for: .seconds(10)); process.terminate() }
        defer { watchdog.cancel() }

        // A client keeps its input open while it waits for its answers: the end of the input means the
        // client has left, and the bridge closes its connection then, so the host cancels what is pending.
        // So the answer is read first, and only then the input closed.
        input.fileHandleForWriting.write(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8) + [10])
        let reading = output.fileHandleForReading
        let answer  = await Task.detached {
            var line = Data()
            while !line.contains(10) {
                let chunk = reading.availableData
                if chunk.isEmpty { break }
                line.append(chunk)
            }
            return line
        }.value
        try input.fileHandleForWriting.close()

        // The bridge ends once its input is closed, with nothing more to write.
        let rest = await Task.detached { reading.readDataToEndOfFile() }.value
        process.waitUntilExit()

        let reply = try JSONDecoder().decode(JSONValue.self, from: answer)
        #expect(reply["result"]["tools"].array?.first?["name"].string == "status")
        #expect(rest.isEmpty)
        #expect(process.terminationStatus == 0)
    }

    @Test func aClientThatLeavesBeforeItsAnswerEndsTheBridgeCleanly() async throws {
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
        let watchdog = Task { try await Task.sleep(for: .seconds(10)); process.terminate() }
        defer { watchdog.cancel() }

        // The input ends right after the request: the client has left, and the bridge does not wait for
        // the answer. It ends, without an error, writing at most whole answers.
        input.fileHandleForWriting.write(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8) + [10])
        try input.fileHandleForWriting.close()
        let reading = output.fileHandleForReading
        let written = await Task.detached { reading.readDataToEndOfFile() }.value
        process.waitUntilExit()

        #expect(process.terminationReason == .exit && process.terminationStatus == 0, "ended by itself, not by the watchdog")
        for line in written.split(separator: 10) {
            #expect((try? JSONDecoder().decode(JSONValue.self, from: Data(line))) != nil, "only whole answers")
        }
    }
}
