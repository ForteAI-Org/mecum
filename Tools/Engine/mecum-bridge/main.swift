//
//  main.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import Foundation
import LocalMCP

// The tool bridge the app bundles for a worker's agent: `mcp-bridge --connection <file>`, the words
// `mecum mcp-bridge` takes, forwarding the agent's MCP messages to the app's own host and nothing
// else. It is an executable of its own so the app carries the bridge alone rather than the whole
// command line, whose every module the app would otherwise build as a framework it shares.

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3, arguments[0] == "mcp-bridge", arguments[1] == "--connection" else {
    FileHandle.standardError.write(Data("usage: mecum-bridge mcp-bridge --connection <private connection file>\n".utf8))
    exit(2)
}

do {
    try await MCPStdioBridge.run(connectionFile: URL(fileURLWithPath: arguments[2]))
} catch {
    FileHandle.standardError.write(Data("mecum-bridge: \(error)\n".utf8))
    exit(1)
}
