//
//  AutomationEvent.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import EngineCore
import LocalMCP

/// AutomationEvent is one finished tool call, or one step inside a batch, in typed form: what was
/// asked in semantic terms and what came back, including the dropdown evidence. It is what a turn
/// is reconstructed from, so nothing downstream parses transcript lines.
///
/// It never carries the session id, process or window numbers, coordinates or permission flags:
/// `select` keeps only its control and item, `act` only its verb, and an input tool only its name,
/// never the text, keys, targets or offsets it was given.
public struct AutomationEvent: Sendable, Equatable {

    /// Operation is the call in semantic terms.
    public enum Operation: Sendable, Equatable {
        case status
        case windows
        case apps
        case openSession
        case observe
        case closeSession
        case act(ActionVerb)
        case select(control: String, item: String)
        /// A type_text, press_key, scroll, drag or context_menu call, by tool name.
        case input(tool: String)
        case batch(steps: Int)
        /// A name the tools do not define, or arguments too malformed to name the operation.
        case unknown(String)
    }

    /// Result is how the call ended.
    public enum Result: Sendable, Equatable {
        /// A read or setup call returned.
        case returned
        /// An act or select returned an outcome, with a select's evidence when it chose an item.
        case outcome(ActOutcomeKind, DropdownEvidence?)
        /// The call threw: a refusal before effects, a failure with possible partial effects, or a
        /// cancellation. The description is for diagnosis only.
        case failed(String)
    }

    public let operation: Operation
    public let result: Result

    /// The step's position inside its batch, from 1; nil for a call the provider made directly.
    public let batchStep: Int?

    public init(operation: Operation, result: Result, batchStep: Int? = nil) {
        self.operation = operation
        self.result    = result
        self.batchStep = batchStep
    }
}

extension AutomationEvent.Operation {

    /// The operation a tool name and its raw arguments describe, read leniently so a call that was
    /// refused for malformed arguments still has a name.
    init(_ name: String, _ arguments: JSONValue) {
        switch name {
            case "status"       : self = .status
            case "windows"      : self = .windows
            case "apps"         : self = .apps
            case "open_session" : self = .openSession
            case "observe"      : self = .observe
            case "close_session": self = .closeSession
            case "batch"        : self = .batch(steps: arguments["steps"].array?.count ?? 0)
            case "select":
                guard let control = arguments["control"].string, let item = arguments["item"].string else {
                    self = .unknown(name)
                    return
                }
                self = .select(control: control, item: item)
            case "act":
                let verb = arguments["verb"].string.flatMap(ActionVerb.init(rawValue:)) ?? .click
                self = .act(verb)
            case "type_text", "press_key", "scroll", "drag", "context_menu":
                self = .input(tool: name)
            default:
                self = .unknown(name)
        }
    }
}
