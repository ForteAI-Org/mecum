//
//  ToolRequestDecoder.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore

/// ToolRequestDecoder is the one decoder of the fourteen tools' arguments, for a call and for a
/// batch's step alike: it checks the shape against the tool's definition (`AutomationTools.definitions`:
/// known properties, required ones present), then reads each argument once into `AgentCallRequest`,
/// the form the living memory stores and the session is driven from, with every default written
/// explicitly (`act`'s verb, `type_text`'s replace, `press_key`'s count, `scroll`'s lines, a drag
/// offset's missing axis) and a chord's modifiers in the definition's order. What it refuses it refuses
/// before any effect, in the sentence the agent reads (`AutomationFailure`). Nothing decodes a tool's
/// arguments anywhere else.
public enum ToolRequestDecoder {

    /// The tools a batch may hold as steps, in the order the definitions list them.
    public static let stepTools: [AgentTool] = [.act, .select, .typeText, .pressKey, .scroll, .drag, .contextMenu]

    /// The largest drag offset, in points, on either axis: more than any display is wide.
    public static let maximumOffset = 5000.0

    /// Decodes one call of `name` with `arguments`. A batch decodes to `.batch` once its `steps` are a
    /// list of one to twenty rows; each row is decoded with `step(_:batchSession:)`.
    public static func decode(_ name: String, _ arguments: JSONValue) throws -> AgentCallRequest {
        guard let tool = AgentTool(rawValue: name) else { throw AutomationFailure("Unknown tool: \(name)") }
        _ = try shape(tool, arguments, extra: [], message: "Unknown tool argument.")
        switch tool {
            case .status:
                return .status
            case .windows:
                return .windows(app: try optionalString(arguments, "app"))
            case .apps:
                return .apps(query: try optionalString(arguments, "query"))
            case .openSession:
                return .openSession(app: try requiredString(arguments, "app"), window: try optionalString(arguments, "window"))
            case .observe:
                return .observe
            case .closeSession:
                return .closeSession
            case .batch:
                guard let rows = arguments["steps"].array, (1...20).contains(rows.count) else {
                    throw AutomationFailure("batch requires 1...20 steps.")
                }
                return .batch
            case .act, .select, .typeText, .pressKey, .scroll, .drag, .contextMenu:
                return try step(tool, arguments)
        }
    }

    /// Decodes one step of a batch: `operation` names the tool, which must be one a batch may hold; the
    /// step's own arguments are its tool's, and a `session` it carries must be the batch's, since a
    /// step is a call of its own under the batch's session and has none apart.
    public static func step(_ row: JSONValue, batchSession: String) throws -> AgentCallRequest {
        guard let name = row["operation"].string, let tool = AgentTool(rawValue: name), stepTools.contains(tool) else {
            throw AutomationFailure("batch supports act, select, type_text, press_key, scroll, drag and "
                                    + "context_menu only.")
        }
        let values = try shape(tool, row, extra: ["operation"], message: "Unknown step argument.")
        if values["session"] != nil, row["session"].string != batchSession {
            throw AutomationFailure("A batch step names a session other than its batch's.")
        }
        return try step(tool, row)
    }

    /// Checks `arguments` against the tool's definition: an object, known properties only (plus
    /// `extra`), every required property present except `session`, which the caller checks against
    /// the live session, or the batch.
    private static func shape(_ tool: AgentTool, _ arguments: JSONValue, extra: Set<String>, message: String) throws
        -> [String: JSONValue] {
        guard let definition = AutomationTools.definitions.first(where: { $0["name"].string == tool.rawValue }),
              let values = arguments.object else { throw AutomationFailure("Invalid tool arguments.") }
        let schema  = definition["inputSchema"]
        let allowed = Set(schema["properties"].object?.keys.map { $0 } ?? []).union(extra)
        guard Set(values.keys).isSubset(of: allowed) else { throw AutomationFailure(message) }
        for field in schema["required"].array ?? [] {
            guard let key = field.string else { continue }
            if key == "session", !extra.isEmpty { continue }
            guard values[key] != nil else { throw AutomationFailure("A required argument is missing.") }
        }
        return values
    }

    /// The arguments of a step tool, as a call or as a batch step.
    private static func step(_ tool: AgentTool, _ args: JSONValue) throws -> AgentCallRequest {
        let object  = args.object ?? [:]
        let section = try optionalString(args, "section")
        let request: AgentCallRequest
        switch tool {
            case .typeText:
                guard let text = args["text"].string, !text.isEmpty else {
                    throw AutomationFailure("text must be a nonempty string.")
                }
                if object["replace"] != nil, args["replace"].bool == nil {
                    throw AutomationFailure("replace must be true or false.")
                }
                request = .typeText(target: try requiredString(args, "target"), text: text, section: section,
                                    replace: args["replace"].bool ?? true)
            case .pressKey:
                guard let key = KeyChord.Name(try requiredString(args, "key")) else {
                    throw AutomationFailure("key must be return, tab, escape, space, delete, an arrow, a letter or a digit.")
                }
                var modifiers: KeyModifiers = []
                if object["modifiers"] != nil {
                    guard let tokens = args["modifiers"].array else {
                        throw AutomationFailure("modifiers must be a list of cmd, shift, opt and ctrl.")
                    }
                    for token in tokens {
                        guard let modifier = token.string.flatMap(AgentKeyModifier.init(rawValue:)) else {
                            throw AutomationFailure("modifiers must be a list of cmd, shift, opt and ctrl.")
                        }
                        let flag: KeyModifiers = switch modifier {
                            case .cmd  : .command
                            case .shift: .shift
                            case .opt  : .option
                            case .ctrl : .control
                        }
                        guard !modifiers.contains(flag) else {
                            throw AutomationFailure("modifiers must name each of cmd, shift, opt and ctrl at most once.")
                        }
                        modifiers.insert(flag)
                    }
                }
                let count = try whole(args, "count", 1...InputRequest.maximumKeyPresses, default: 1)
                request = .pressKey(key: key, modifiers: AgentKeyModifier.ordered(modifiers), count: count)
            case .scroll:
                guard let direction = AgentScrollDirection(rawValue: try requiredString(args, "direction")) else {
                    throw AutomationFailure("direction must be up or down.")
                }
                let lines = try whole(args, "lines", 1...InputRequest.maximumScrollLines, default: 3)
                request = .scroll(direction: direction, lines: lines, target: try optionalString(args, "target"),
                                  section: section)
            case .drag:
                let hasOffset = object["dx"] != nil || object["dy"] != nil
                let end: AgentDragEnd
                if let target = try optionalString(args, "to") {
                    guard !hasOffset else { throw AutomationFailure("drag takes to or dx/dy, not both.") }
                    end = .target(target)
                } else {
                    guard hasOffset else { throw AutomationFailure("drag needs to, or dx and dy.") }
                    end = .offset(dx: try offset(args, "dx"), dy: try offset(args, "dy"))
                }
                request = .drag(from: try requiredString(args, "from"), to: end, section: section)
            case .contextMenu:
                request = .contextMenu(target: try requiredString(args, "target"), item: try requiredString(args, "item"),
                                       section: section)
            case .select:
                request = .select(control: try requiredString(args, "control"), item: try requiredString(args, "item"))
            case .act:
                let rawVerb = object["verb"] == nil ? "click" : try requiredString(args, "verb")
                guard let verb = ActionVerb(rawValue: rawVerb) else { throw AutomationFailure("Unsupported action verb.") }
                let state: ControlState?
                if object["value"] != nil {
                    guard let value = ControlState(rawValue: try requiredString(args, "value")),
                          value == .on || value == .off else { throw AutomationFailure("value must be on or off.") }
                    state = value
                } else { state = nil }
                if verb == .setToggle, state == nil { throw AutomationFailure("set_toggle requires value on or off.") }
                if verb != .setToggle, state != nil { throw AutomationFailure("value is only valid for set_toggle.") }
                request = .act(target: try requiredString(args, "target"), verb: verb, value: state, section: section)
            default:
                throw AutomationFailure("batch supports act, select, type_text, press_key, scroll, drag and "
                                        + "context_menu only.")
        }
        do {
            try request.validate()
        } catch {
            throw AutomationFailure("Invalid arguments for \(tool.rawValue): \(error)")
        }
        return request
    }

    // MARK: Scalars

    static func requiredString(_ object: JSONValue, _ key: String) throws -> String {
        guard let value = object[key].string, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutomationFailure("\(key) must be a nonempty string.")
        }
        return value
    }

    static func optionalString(_ object: JSONValue, _ key: String) throws -> String? {
        object.object?[key] == nil ? nil : try requiredString(object, key)
    }

    /// A whole number within `range`, or `fallback` when the argument is absent.
    private static func whole(_ object: JSONValue, _ key: String, _ range: ClosedRange<Int>,
                              default fallback: Int) throws -> Int {
        guard object.object?[key] != nil else { return fallback }
        guard case .number(let value) = object[key], value.rounded() == value,
              value >= Double(range.lowerBound), value <= Double(range.upperBound) else {
            throw AutomationFailure("\(key) must be a whole number from \(range.lowerBound) to \(range.upperBound).")
        }
        return Int(value)
    }

    /// A drag offset in points, zero when the argument is absent.
    private static func offset(_ object: JSONValue, _ key: String) throws -> Double {
        guard object.object?[key] != nil else { return 0 }
        guard case .number(let value) = object[key], abs(value) <= maximumOffset else {
            throw AutomationFailure("\(key) must be a number of points within ±\(Int(maximumOffset)).")
        }
        return value
    }
}

extension AgentCallRequest {

    /// The engine's input a stored input request drives, with its section: the inverse of
    /// `AgentCallRequest.input(_:section:)`. Nil for a request that is not an input.
    public var engineInput: (input: InputRequest.Input, section: String?)? {
        switch self {
            case .typeText(let target, let text, let section, let replace):
                return (.typeText(text, into: target, replacing: replace), section)
            case .pressKey(let key, let modifiers, let count):
                var flags: KeyModifiers = []
                for modifier in modifiers {
                    switch modifier {
                        case .cmd  : flags.insert(.command)
                        case .shift: flags.insert(.shift)
                        case .opt  : flags.insert(.option)
                        case .ctrl : flags.insert(.control)
                    }
                }
                return (.pressKey(KeyChord(key, modifiers: flags), times: count), nil)
            case .scroll(let direction, let lines, let target, let section):
                return (.scroll(lines: direction == .up ? lines : -lines, over: target), section)
            case .drag(let from, .target(let to), let section):
                return (.drag(from: from, to: .target(to)), section)
            case .drag(let from, .offset(let dx, let dy), let section):
                return (.drag(from: from, to: .offset(dx: dx, dy: dy)), section)
            case .contextMenu(let target, let item, let section):
                return (.contextMenu(on: target, item: item), section)
            default:
                return nil
        }
    }

    /// Whether this is `act` with `set_toggle`, whose `acted_noop` a batch accepts.
    public var isToggle: Bool {
        if case .act(_, .setToggle, _, _) = self { true } else { false }
    }

    /// Whether a batch goes on after this step ended with `kind`: `found_acted` always, `acted_noop`
    /// only for `set_toggle` (the control was already in the requested state), anything else stops
    /// it. The one rule of the tools' batch and of the command line's.
    public func accepts(_ kind: ActOutcomeKind) -> Bool {
        kind == .foundActed || (kind == .actedNoop && isToggle)
    }
}
