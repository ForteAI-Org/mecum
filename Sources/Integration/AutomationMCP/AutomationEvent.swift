//
//  AutomationEvent.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import EngineCore
import LocalMCP
import PerceptionCore

/// AutomationEvent is one finished tool call, or one step inside a batch, in typed form: what was
/// asked in semantic terms and what came back, including a dropdown's, a toggle's or a click's
/// evidence. It is what a turn is reconstructed from, so nothing downstream parses transcript lines.
///
/// It never carries the session id, process or window numbers, coordinates or permission flags:
/// `select` keeps only its control and item, `act` its target, verb, section and requested state,
/// also when the call failed and those arguments could still be read, and an input tool only its
/// name, never the text, keys, targets or offsets it was given.
public struct AutomationEvent: Sendable, Equatable {

    /// Operation is the call in semantic terms.
    public enum Operation: Sendable, Equatable {
        case status
        case windows
        case apps
        case openSession
        case openRecent
        case observe
        case menus
        case resolveAction
        case menu(path: [String], expectingWindow: String)
        case closeSession
        case act(ActionArguments)
        case select(control: String, item: String)
        /// A type_text, press_key, scroll, drag or context_menu call, by its tool alone.
        case input(tool: AutomationTool)
        case batch(steps: Int)
        /// A name the tools do not define, or arguments too malformed to name the operation.
        case unknown(String)
    }

    /// Result is how the call ended.
    public enum Result: Sendable, Equatable {
        /// A read or setup call returned.
        case returned
        /// An act or select returned an outcome, with a select's evidence when it chose an item, a
        /// `set_toggle`'s when it resolved its control, and a click's when its gesture was attempted.
        case outcome(ActOutcomeKind, ActEvidence?)
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
        guard let tool = AutomationTool(rawValue: name) else {
            self = .unknown(name)
            return
        }
        switch tool {
            case .status      : self = .status
            case .windows     : self = .windows
            case .apps        : self = .apps
            case .openSession : self = .openSession
            case .openRecent  : self = .openRecent
            case .menus       : self = .menus
            case .resolveAction: self = .resolveAction
            case .menu:
                guard let path = arguments["path"].array, path.allSatisfy({ $0.string != nil }),
                      let expected = arguments["expect_window"].string else {
                    self = .input(tool: .menu); return
                }
                self = .menu(path: path.compactMap(\.string), expectingWindow: expected)
            case .observe     : self = .observe
            case .closeSession: self = .closeSession
            case .batch       : self = .batch(steps: arguments["steps"].array?.count ?? 0)
            case .select:
                guard let control = arguments["control"].string, let item = arguments["item"].string else {
                    self = .unknown(name)
                    return
                }
                self = .select(control: control, item: item)
            case .act:
                // An absent verb is a click, as the tool reads it; a verb it does not define names nothing.
                let verb = arguments["verb"].string.map { ActionVerb(rawValue: $0) } ?? ActionVerb.click
                guard let target = arguments["target"].string, let verb else {
                    self = .unknown(name)
                    return
                }
                self = .act(ActionArguments(
                    target      : target,
                    verb        : verb,
                    section     : arguments["section"].string,
                    desiredState: arguments["value"].string.flatMap(ControlState.init(rawValue:))
                ))
            case .press, .typeText, .pressKey, .scroll, .drag, .contextMenu:
                self = .input(tool: tool)
        }
    }
}
