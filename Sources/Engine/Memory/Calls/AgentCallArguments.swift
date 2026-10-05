//
//  AgentCallArguments.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import EngineCore
import PerceptionCore

/// AgentCallArguments is version 1 of a call's stored arguments, the rows of
/// `memory_operation_arguments` its event owns: for each tool the names it admits, in the tool's
/// own words, with the type and the rows of each. A scalar is one row at position 0; a list is one
/// row per item at positions 0, 1, … in its order; an absent optional is no row, never an empty
/// text. Codes are the tools' tokens, compared as bytes. Version 1:
///
/// | Tool | Arguments |
/// |---|---|
/// | `status`, `observe`, `batch`, `close_session` | none (the session is the event's; a batch's steps are its child calls) |
/// | `windows` | `app` (text, optional) |
/// | `apps` | `query` (text, optional) |
/// | `open_session` | `app` (text), `window` (text, optional) |
/// | `act` | `target` (text), `verb` (`ActionVerb`, written even when the decoder defaulted it to `click`), `value` (`on`/`off`, only and always with `set_toggle`), `section` (text, optional) |
/// | `select` | `control`, `item` (text) |
/// | `type_text` | `target`, `text` (text), `section` (text, optional), `replace` (boolean, written even when it defaulted to true) |
/// | `insert_text` | `text` (text), `expected_value` (text, optional) |
/// | `press_key` | `key` (a `KeyChord.Name` word), `modifiers` (a list of `cmd`, `shift`, `opt`, `ctrl`, each at most once), `count` (integer ≥ 1, written even when it defaulted to 1) |
/// | `scroll` | `direction` (`up`/`down`), `lines` (integer ≥ 1, written even when it defaulted to 3), `target`, `section` (text, optional) |
/// | `drag` | `from` (text), then either `to` (text) or both `dx` and `dy` (finite reals, a missing axis written as 0), `section` (text, optional) |
/// | `context_menu` | `target`, `item` (text), `section` (text, optional) |
public enum AgentCallArguments {

    public enum Rows: Sendable, Equatable { case one, optional, list }

    public struct Spec: Sendable, Equatable {
        public let name: String
        public let kind: BrainArgument.Kind
        public let rows: Rows
    }

    public static func specs(of tool: AgentTool) -> [Spec] {
        func text(_ name: String, _ rows: Rows = .one) -> Spec { Spec(name: name, kind: .text, rows: rows) }
        switch tool {
            case .status, .observe, .batch, .closeSession:
                return []
            case .windows:
                return [text("app", .optional)]
            case .apps:
                return [text("query", .optional)]
            case .openSession:
                return [text("app"), text("window", .optional)]
            case .act:
                return [text("target"), text("verb"), text("value", .optional), text("section", .optional)]
            case .select:
                return [text("control"), text("item")]
            case .typeText:
                return [text("target"), text("text"), text("section", .optional), Spec(name: "replace", kind: .boolean, rows: .one)]
            case .insertText:
                return [text("text"), text("expected_value", .optional)]
            case .pressKey:
                return [text("key"), text("modifiers", .list), Spec(name: "count", kind: .integer, rows: .one)]
            case .scroll:
                return [text("direction"), Spec(name: "lines", kind: .integer, rows: .one), text("target", .optional),
                        text("section", .optional)]
            case .drag:
                return [text("from"), text("to", .optional), Spec(name: "dx", kind: .real, rows: .optional),
                        Spec(name: "dy", kind: .real, rows: .optional), text("section", .optional)]
            case .contextMenu:
                return [text("target"), text("item"), text("section", .optional)]
        }
    }
}

extension AgentCallRequest {

    /// The request as the contract's rows, in the contract's order: by spec, then by position.
    public var arguments: [BrainArgument] {
        var rows: [BrainArgument] = []
        func put(_ name: String, _ value: BrainArgument.Value?, at position: Int = 0) {
            if let value { rows.append(BrainArgument(name: name, position: position, value: value)) }
        }
        func text(_ value: String?) -> BrainArgument.Value? { value.map(BrainArgument.Value.text) }
        switch self {
            case .status, .observe, .batch, .closeSession:
                break
            case .windows(let app):
                put("app", text(app))
            case .apps(let query):
                put("query", text(query))
            case .openSession(let app, let window):
                put("app", text(app))
                put("window", text(window))
            case .act(let target, let verb, let value, let section):
                put("target", text(target))
                put("verb", text(verb.rawValue))
                put("value", text(value?.rawValue))
                put("section", text(section))
            case .select(let control, let item):
                put("control", text(control))
                put("item", text(item))
            case .typeText(let target, let value, let section, let replace):
                put("target", text(target))
                put("text", text(value))
                put("section", text(section))
                put("replace", .boolean(replace))
            case .insertText(let value, let expectedValue):
                put("text", text(value))
                put("expected_value", text(expectedValue))
            case .pressKey(let key, let modifiers, let count):
                put("key", text(key.word))
                for (position, modifier) in modifiers.enumerated() { put("modifiers", text(modifier.rawValue), at: position) }
                put("count", .integer(Int64(count)))
            case .scroll(let direction, let lines, let target, let section):
                put("direction", text(direction.rawValue))
                put("lines", .integer(Int64(lines)))
                put("target", text(target))
                put("section", text(section))
            case .drag(let from, let end, let section):
                put("from", text(from))
                switch end {
                    case .target(let to):
                        put("to", text(to))
                    case .offset(let dx, let dy):
                        put("dx", .real(dx))
                        put("dy", .real(dy))
                }
                put("section", text(section))
            case .contextMenu(let target, let item, let section):
                put("target", text(target))
                put("item", text(item))
                put("section", text(section))
        }
        let order = AgentCallArguments.specs(of: tool).map(\.name)
        return rows.enumerated().sorted { lhs, rhs in
            let left = order.firstIndex(of: lhs.element.name) ?? 0, right = order.firstIndex(of: rhs.element.name) ?? 0
            return (left, lhs.element.position, lhs.offset) < (right, rhs.element.position, rhs.offset)
        }.map(\.element)
    }

    /// A digest of the tool and the arguments for conflict reports, never the decision:
    /// `isExactly(_:)` is.
    public var digest: String {
        StructuralDigest.fnv1a(([tool.rawValue] + arguments.map(\.canonical)).joined(separator: "\u{1E}"))
    }

    /// The request of a stored call rebuilt from its rows, refusing what version 1 does not admit
    /// for its tool: a name it does not list, a type, a duplicate, a gap in a list, a scalar off
    /// position 0, a required row missing, a code it does not know (as bytes), an offset that is not
    /// finite, a drag with both or neither ends, a `value` that does not go with its verb.
    public init(tool: AgentTool, arguments: [BrainArgument], eventID: String) throws {
        func refuse(_ malformation: AgentCallError.Malformation) -> AgentCallError {
            .malformedCall(eventID: eventID, malformation: malformation)
        }
        let specs = Dictionary(uniqueKeysWithValues: AgentCallArguments.specs(of: tool).map { ($0.name, $0) })
        var byName: [String: [Int: BrainArgument.Value]] = [:]
        for argument in arguments {
            guard let spec = specs[argument.name], spec.name.utf8.elementsEqual(argument.name.utf8) else {
                throw refuse(.forbiddenArgument(argument.name))
            }
            guard argument.value.kind == spec.kind else { throw refuse(.argumentKindMismatch(spec.name)) }
            guard byName[spec.name]?[argument.position] == nil else {
                throw refuse(.duplicateArgument(spec.name, position: argument.position))
            }
            if case .real(let value) = argument.value, !value.isFinite { throw refuse(.invalidValue(spec.name)) }
            byName[spec.name, default: [:]][argument.position] = argument.value
        }
        for spec in specs.values {
            let positions = Array((byName[spec.name] ?? [:]).keys)
            switch spec.rows {
                case .one, .optional:
                    if spec.rows == .one, positions.isEmpty { throw refuse(.missingArgument(spec.name)) }
                    if !positions.allSatisfy({ $0 == 0 }) { throw refuse(.positionsNotContiguous(spec.name)) }
                case .list:
                    if !positions.allSatisfy({ (0..<positions.count).contains($0) }) {
                        throw refuse(.positionsNotContiguous(spec.name))
                    }
            }
        }
        func text(_ name: String) -> String? {
            if case .text(let value)? = byName[name]?[0] { return value }
            return nil
        }
        func required(_ name: String) throws -> String {
            guard let value = text(name) else { throw refuse(.missingArgument(name)) }
            return value
        }
        func code<T: RawRepresentable>(_ type: T.Type, _ name: String, _ raw: String) throws -> T where T.RawValue == String {
            guard let known = T(rawValue: raw), known.rawValue.utf8.elementsEqual(raw.utf8) else {
                throw refuse(.unknownCode(argument: name, code: raw))
            }
            return known
        }
        func integer(_ name: String) throws -> Int {
            guard case .integer(let value)? = byName[name]?[0] else { throw refuse(.missingArgument(name)) }
            guard let whole = Int(exactly: value) else { throw refuse(.invalidValue(name)) }
            return whole
        }
        func real(_ name: String) -> Double? {
            if case .real(let value)? = byName[name]?[0] { return value }
            return nil
        }
        let request: AgentCallRequest
        switch tool {
            case .status      : request = .status
            case .observe     : request = .observe
            case .batch       : request = .batch
            case .closeSession: request = .closeSession
            case .windows     : request = .windows(app: text("app"))
            case .apps        : request = .apps(query: text("query"))
            case .openSession : request = .openSession(app: try required("app"), window: text("window"))
            case .act:
                let verb = try code(ActionVerb.self, "verb", try required("verb"))
                let value = try text("value").map { try code(ControlState.self, "value", $0) }
                request = .act(target: try required("target"), verb: verb, value: value, section: text("section"))
            case .select:
                request = .select(control: try required("control"), item: try required("item"))
            case .typeText:
                guard case .boolean(let replace)? = byName["replace"]?[0] else { throw refuse(.missingArgument("replace")) }
                request = .typeText(target: try required("target"), text: try required("text"), section: text("section"),
                                    replace: replace)
            case .insertText:
                request = .insertText(text: try required("text"), expectedValue: text("expected_value"))
            case .pressKey:
                let word = try required("key")
                guard let key = KeyChord.Name(word), key.word.utf8.elementsEqual(word.utf8) else {
                    throw refuse(.unknownCode(argument: "key", code: word))
                }
                let tokens = byName["modifiers"] ?? [:]
                let modifiers = try (0..<tokens.count).map { position -> AgentKeyModifier in
                    guard case .text(let token)? = tokens[position] else { throw refuse(.argumentKindMismatch("modifiers")) }
                    return try code(AgentKeyModifier.self, "modifiers", token)
                }
                request = .pressKey(key: key, modifiers: modifiers, count: try integer("count"))
            case .scroll:
                request = .scroll(direction: try code(AgentScrollDirection.self, "direction", try required("direction")),
                                  lines: try integer("lines"), target: text("target"), section: text("section"))
            case .drag:
                let end: AgentDragEnd
                switch (text("to"), real("dx"), real("dy")) {
                    case (let to?, nil, nil)    : end = .target(to)
                    case (nil, let dx?, let dy?): end = .offset(dx: dx, dy: dy)
                    default                     : throw refuse(.incompatibleArguments("to, dx, dy"))
                }
                request = .drag(from: try required("from"), to: end, section: text("section"))
            case .contextMenu:
                request = .contextMenu(target: try required("target"), item: try required("item"), section: text("section"))
        }
        do {
            try request.validate()
        } catch AgentCallError.invalidRequest(let invalidity) {
            throw refuse(.incompatibleArguments("\(invalidity)"))
        }
        self = request
    }
}
