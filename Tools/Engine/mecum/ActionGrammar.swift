//
//  ActionGrammar.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import AutomationMCP
import AutomationRuntime
import Foundation
import LocalMCP
import Memory

/// ActionGrammar is how the terminal names the seven actions the app's tools offer (`act`, `select`,
/// `type_text`, `press_key`, `scroll`, `drag`, `context_menu`), as a direct command or as a batch
/// step: the same operation names as the tools, the required arguments as positionals in a fixed
/// order, the optional ones as options. It reads words into the tool's arguments by shape alone and
/// hands them to `ToolRequestDecoder.step`, the one decoder of the app's tools, so a verb, a value, a
/// key, a modifier, a number, a drag's end and every default mean on the command line exactly what
/// they mean to the model; it never decides one of them itself.
///
///     act <target> [--verb click|double_click|triple_click|right_click|set_toggle] [--value on|off] [--section <name>]
///     select <dropdown> <item>
///     type_text <field> <text> [--append] [--section <name>]
///     press_key <key> [--modifier cmd|shift|opt|ctrl]... [--count <1...20>]
///     scroll <up|down> [--target <name>] [--lines <1...50>] [--section <name>]
///     drag <from> (--to <target> | --dx <points> [--dy <points>] | --dy <points>) [--section <name>]
///     context_menu <target> <item> [--section <name>]
///
/// `--append` is the tool's `replace: false`; `--modifier` is given once per modifier, in any order.
/// A number is written in decimal digits, with an optional sign and fraction: anything else is refused
/// here, and its range and wholeness are the decoder's to judge.
enum ActionGrammar {

    /// The operations, in the tools' order.
    static let operations: [AgentTool] = ToolRequestDecoder.stepTools

    /// The positionals each operation takes, in order, by the tool's argument names.
    static func positionals(_ tool: AgentTool) -> [String] {
        switch tool {
            case .act         : ["target"]
            case .select      : ["control", "item"]
            case .typeText    : ["target", "text"]
            case .pressKey    : ["key"]
            case .scroll      : ["direction"]
            case .drag        : ["from"]
            case .contextMenu : ["target", "item"]
            default           : []
        }
    }

    /// The options each operation takes.
    static func spec(_ tool: AgentTool) -> OptionSpec {
        switch tool {
            case .act         : OptionSpec(valued: ["verb", "value", "section"])
            case .select      : OptionSpec()
            case .typeText    : OptionSpec(valued: ["section"], flags: ["append"])
            case .pressKey    : OptionSpec(valued: ["modifier", "count"], repeatable: ["modifier"])
            case .scroll      : OptionSpec(valued: ["target", "lines", "section"])
            case .drag        : OptionSpec(valued: ["to", "dx", "dy", "section"])
            case .contextMenu : OptionSpec(valued: ["section"])
            default           : OptionSpec()
        }
    }

    /// One line of usage for the operation.
    static func usage(_ tool: AgentTool) -> String {
        switch tool {
            case .act         : "act <target> [--verb <verb>] [--value on|off] [--section <name>]"
            case .select      : "select <dropdown> <item>"
            case .typeText    : "type_text <field> <text> [--append] [--section <name>]"
            case .pressKey    : "press_key <key> [--modifier cmd|shift|opt|ctrl]... [--count <n>]"
            case .scroll      : "scroll <up|down> [--target <name>] [--lines <n>] [--section <name>]"
            case .drag        : "drag <from> (--to <target> | --dx <points> [--dy <points>] | --dy <points>) [--section <name>]"
            case .contextMenu : "context_menu <target> <item> [--section <name>]"
            default           : tool.rawValue
        }
    }

    /// The operation a word names, or nil.
    static func operation(_ word: String) -> AgentTool? {
        AgentTool(rawValue: word).flatMap { operations.contains($0) ? $0 : nil }
    }

    /// A batch step: its operation, then its words.
    static func step(_ words: [String]) throws -> AgentCallRequest {
        guard let first = words.first, let tool = operation(first) else {
            throw UsageError.missing("an operation (" + operations.map(\.rawValue).joined(separator: ", ")
                                     + ") after -- / --then")
        }
        return try request(tool, try Words.parse(words.dropFirst(), spec: spec(tool)))
    }

    /// The request `parsed` names for `tool`, decoded by the tools' decoder; positionals beyond the
    /// operation's are refused (an application is named once, before them).
    static func request(_ tool: AgentTool, _ parsed: Words.Parsed) throws -> AgentCallRequest {
        let names = positionals(tool)
        guard parsed.positionals.count == names.count else {
            throw UsageError.missing(usage(tool) + " (the application is named once, before the operation's words)")
        }
        var row: [String: JSONValue] = ["operation": .string(tool.rawValue)]
        for (name, word) in zip(names, parsed.positionals) { row[name] = .string(word) }
        for (name, values) in parsed.values {
            switch name {
                case "modifier":
                    row["modifiers"] = .array(values.map { .string($0) })
                case "count", "lines", "dx", "dy":
                    row[name] = .number(try number(values.last ?? "", option: name))
                default:
                    row[name] = .string(values.last ?? "")
            }
        }
        if parsed.flags.contains("append") { row["replace"] = .bool(false) }
        do {
            return try ToolRequestDecoder.step(.object(row), batchSession: "")
        } catch let failure as AutomationFailure {
            throw ActionGrammarError(tool: tool, reason: failure.description)
        }
    }

    /// A number written in decimal digits, with an optional sign and fraction.
    static func number(_ word: String, option: String) throws -> Double {
        guard word.wholeMatch(of: /[+-]?[0-9]+(\.[0-9]+)?/) != nil, let value = Double(word), value.isFinite else {
            throw UsageError.invalid(option: option, value: word, expected: "a number in decimal digits")
        }
        return value
    }
}

/// ActionGrammarError is a request the tools' decoder refused, in the decoder's own words.
struct ActionGrammarError: Error, CustomStringConvertible, Equatable {
    let tool: AgentTool
    let reason: String

    var description: String { "\(tool.rawValue): \(reason)" }
}
