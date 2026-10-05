//
//  main.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import AppKit
import Darwin
import Foundation
import LocalMCP

// The foreground command line over the Perception and Engine layers: what a model host will do
// through the tool registry, done by hand from a terminal. One subcommand per verb; every one exits
// non zero when it could not do what was asked, and prints one sentence saying why.
//
//   mecum windows <app>
//   mecum scene   <app> [--json]
//   mecum act     <app> <target> [--verb click|double_click|triple_click|right_click|set_toggle]
//                                [--value on|off] [--section <name>] [--dry-run] [--allow-destructive]
//   mecum select | type_text | press_key | scroll | drag | context_menu <app> <words> --seat
//   mecum batch   <app> --window <title> --seat -- <step> --then <step> ...
//   mecum memory  status | traces | trace <id> | event <id> | <app>
//
// Usage.text is the full grammar.
// <app> is a bundle id or an application name; --knowledge <dir> overrides where memory lives;
// --seat drives on the Seat's virtual display instead of the real screen.

let rawArguments = Array(CommandLine.arguments.dropFirst())
let normalizedArguments = rawArguments.first == "--chat" ? ["chat"] + rawArguments.dropFirst() : rawArguments
let invocation = Invocation(arguments: normalizedArguments)

guard let command = invocation.command else {
    print(Usage.text)
    exit(invocation.arguments.isEmpty ? 0 : 2)
}

// Driver ADR 0007 requires a caller-owned AppKit loop across asynchronous Seat work.
// A prohibited application keeps that loop alive without a Dock icon or activation.
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
Task { @MainActor in
    do {
        switch command {
            case "chat": try await ChatCommand.run(arguments: Array(normalizedArguments.dropFirst()))
            case "peek": try await PeekCommand.run(arguments: Array(normalizedArguments.dropFirst()))
            case "mcp-bridge":
                guard normalizedArguments.count == 3, normalizedArguments[1] == "--connection" else {
                    throw UsageError.missing("mcp-bridge --connection <private connection file>")
                }
                try await MCPStdioBridge.run(connectionFile: URL(fileURLWithPath: normalizedArguments[2]))
            case "windows":
                try await WindowsCommand.run(try Invocation(arguments: normalizedArguments, spec: CommandSpecs.windows))
            // A direct command that acts or perceives is one invocation, the owner of its stop and of its
            // memory's finalizations: Ctrl+C stops it, lets the Seat and the memory go, then exits.
            case "scene":
                await VerticalInvocation.main {
                    try await SceneCommand.run(try Invocation(arguments: normalizedArguments, spec: CommandSpecs.scene))
                }
            case "batch":
                await VerticalInvocation.main { try await BatchCommand.run(invocation) }
            case "memory":
                try await MemoryCommand.run(try Invocation(arguments: normalizedArguments, spec: CommandSpecs.memory))
            case let word where ActionGrammar.operation(word) != nil:
                await VerticalInvocation.main { try await ActionCommand.run(word, arguments: normalizedArguments) }
            case "help", "--help", "-h":
                print(Usage.text)
            default:
                FileHandle.standardError.write(Data("unknown command '\(command)'\n\n\(Usage.text)\n".utf8))
                exit(2)
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("mecum: \(error)\n".utf8))
        exit(1)
    }
}
application.run()
