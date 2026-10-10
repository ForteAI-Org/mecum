//
//  MemoryTaskTool.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 09/10/2026.
//

import Foundation
import LocalMCP
import Memory

/// MemoryTaskTool is the `memory_task` tool: its definition, the instructions that tell an agent when to
/// use it, and the decoding of its arguments into the task contract. It is not an operation on an
/// application and is never recorded as one: its declarations are the task's facts.
nonisolated enum MemoryTaskTool {

    static let name = "memory_task"

    /// Operation is what one call of the tool asks.
    enum Operation: String, CaseIterable {
        case begin, update, checkpoint, end, resume, status
    }

    /// Request is one decoded call, with the secret values it carried, which the producer keeps in
    /// memory to withhold them from every later record and which are never stored.
    enum Request {
        case begin(TaskRevisionContent, secrets: [String])
        case update(Update, secrets: [String])
        case checkpoint(TaskCheckpointDraft, secrets: [String])
        case end(TaskCheckpointDraft, secrets: [String])
        case resume(taskID: String)
        case status
    }

    /// Update is a revision's change: the fields given replace the revision's, inputs replace those of
    /// the same name or are added, `removedInputs` are dropped. `minimization` holds every secret known
    /// when it was decoded, the update's own included.
    struct Update {
        let expecting: Int?
        let goal: String?
        let result: String?
        let constraints: [String]?
        let inputs: [TaskValue]
        let removedInputs: [String]
        let reason: String?
        let minimization: ValueMinimization

        /// The content of the next revision, built on `base`, the revision the agent read. What it keeps
        /// of the base is minimized again, so a secret declared since is not carried forward.
        func applied(to base: TaskRevisionContent, messageRef: String?) throws -> TaskRevisionContent {
            var merged = try base.inputs.filter { input in
                !removedInputs.contains(input.name) && !inputs.contains { $0.name.utf8.elementsEqual(input.name.utf8) }
            }.map { try MemoryTaskTool.minimized($0, by: minimization) }
            merged += inputs
            var references = base.messageRefs
            if let messageRef, !references.contains(messageRef) { references.append(messageRef) }
            func kept(_ text: String) -> String { minimization.minimize(text: text).0 }
            return try TaskRevisionContent(
                goal           : goal ?? kept(base.goal),
                requestedResult: result ?? base.requestedResult.map(kept),
                constraints    : constraints ?? base.constraints.map(kept),
                inputs         : merged,
                messageRefs    : references
            )
        }
    }

    /// Failure is a call the tool answers with an error the agent can act on: a code, a sentence, and
    /// the facts it needs (the current revision, the open task).
    struct Failure: Error {
        let code: String
        let message: String
        var details: [String: JSONValue] = [:]
    }

    // MARK: Definition

    static var definition: JSONValue {
        let text: JSONValue = .object(["type": .string("string"), "minLength": .number(1)])
        let texts: JSONValue = .object(["type": .string("array"), "items": text])
        let value: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "name": text,
                "value": .object(["type": .string("string")]),
                "kind": .object(["type": .string("string"),
                                 "enum": .array(["text", "number", "boolean", "file", "folder",
                                                 "reference"].map(JSONValue.string))]),
                "role": text,
                "source": .object(["type": .string("string"),
                                   "enum": .array(TaskValueSource.allCases.map { .string($0.rawValue) })]),
                "source_ref": text,
                "source_version": text,
                "secret": .object(["type": .string("boolean")]),
            ]),
            "required": .array([.string("name")]),
            "additionalProperties": .bool(false),
        ])
        let values: JSONValue = .object(["type": .string("array"), "items": value])
        return .object([
            "name": .string(name),
            "description": .string(
                "Tell Mecum's memory what task you are working on, so the app actions that serve it are recorded under it "
                + "and can later be learned and reused. begin: before acting on apps for a new request, with goal (what the "
                + "person wants, resolved from the conversation), result, constraints, and inputs (each with name, value or "
                + "none when still missing, kind, role, source and source_ref; secret true for passwords, tokens and codes, "
                + "whose value is never kept). update: when the request or your understanding of it changes; revision is the "
                + "revision you last read. checkpoint: when a meaningful part is done, with its note and outputs. end: with "
                + "outcome completed, failed or abandoned, a note and the outputs. resume: an unfinished task of yours, by its "
                + "task id, after a restart; never begin it again. status: the open task. This tool performs no app action."
            ),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "operation": .object(["type": .string("string"),
                                          "enum": .array(Operation.allCases.map { .string($0.rawValue) })]),
                    "task": text,
                    "revision": .object(["type": .string("integer"), "minimum": .number(1)]),
                    "goal": text,
                    "result": text,
                    "constraints": texts,
                    "inputs": values,
                    "remove_inputs": texts,
                    "reason": text,
                    "note": text,
                    "outcome": .object(["type": .string("string"),
                                        "enum": .array(["completed", "failed", "abandoned"].map(JSONValue.string))]),
                    "outputs": values,
                ]),
                "required": .array([.string("operation")]),
                "additionalProperties": .bool(false),
            ]),
            "annotations": .object(["readOnlyHint": .bool(false)]),
        ])
    }

    static let instructions = """
    Before acting on apps for a new request, call memory_task begin with the goal resolved from the conversation,
    the result asked for, constraints and the known inputs, with each input's source; list a needed input you do not
    have yet without a value. Mark passwords, tokens and codes secret: Mecum keeps their role, never their value.
    Call memory_task update when the request changes, checkpoint when a meaningful part is done, with its outputs, and
    end with completed, failed or abandoned once the task is over. A new request after an end is a new task; after a
    restart, resume your unfinished task by its id. Actions taken without an open task are recorded but cannot be
    learned as a procedure. memory_task performs no app action and needs no session.
    """

    // MARK: Decoding

    /// The request a call's arguments state, with values that may not be kept withheld by `minimization`.
    static func decode(_ arguments: JSONValue, minimization: ValueMinimization, messageRef: String?) throws -> Request {
        let messageRef = messageRef.flatMap { $0.isEmpty ? nil : $0 }
        guard let object = arguments.object else { throw invalid("arguments must be an object") }
        let allowed: Set<String> = ["operation", "task", "revision", "goal", "result", "constraints", "inputs",
                                    "remove_inputs", "reason", "note", "outcome", "outputs"]
        guard Set(object.keys).isSubset(of: allowed) else { throw invalid("unknown argument") }
        guard let word = arguments["operation"].string, let operation = Operation(rawValue: word) else {
            throw invalid("operation must be one of \(Operation.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        // Every value the request declares secret is known before any of its texts is read, so a copy
        // of one in the goal, a constraint or a note is withheld as the value itself is.
        let minimization = minimization.adding(secrets: declaredSecrets(in: arguments))
        func text(_ key: String) -> String? { optionalText(arguments, key).map { minimization.minimize(text: $0).0 } }
        func list(_ key: String) throws -> [String]? {
            try texts(arguments, key)?.map { minimization.minimize(text: $0).0 }
        }
        var secrets: [String] = []
        do {
            switch operation {
                case .begin:
                    guard let goal = text("goal") else { throw invalid("begin needs a goal") }
                    let inputs = try values(
                        arguments["inputs"],
                        minimization: minimization,
                        secrets     : &secrets,
                        outputs     : false
                    )
                    let content = try TaskRevisionContent(
                        goal           : goal,
                        requestedResult: text("result"),
                        constraints    : try list("constraints") ?? [],
                        inputs         : inputs,
                        messageRefs    : messageRef.map { [$0] } ?? []
                    )
                    return .begin(content, secrets: secrets)
                case .update:
                    let revision: Int?
                    if object["revision"] != nil {
                        // Int(exactly:) refuses a fraction, an infinity and a number past the integers.
                        guard case .number(let number) = arguments["revision"], let whole = Int(exactly: number),
                              whole >= 1 else {
                            throw invalid("revision must be a whole number from 1, within 64-bit integers")
                        }
                        revision = whole
                    } else {
                        revision = nil
                    }
                    let update = Update(
                        expecting    : revision,
                        goal         : text("goal"),
                        result       : text("result"),
                        constraints  : try list("constraints"),
                        inputs       : try values(
                            arguments["inputs"],
                            minimization: minimization,
                            secrets     : &secrets,
                            outputs     : false
                        ),
                        removedInputs: try list("remove_inputs") ?? [],
                        reason       : text("reason"),
                        minimization : minimization
                    )
                    return .update(update, secrets: secrets)
                case .checkpoint:
                    let outputs = try values(
                        arguments["outputs"],
                        minimization: minimization,
                        secrets     : &secrets,
                        outputs     : true
                    )
                    return .checkpoint(try TaskCheckpointDraft(kind: .checkpoint, note: text("note"), outputs: outputs),
                                       secrets: secrets)
                case .end:
                    guard let word = arguments["outcome"].string,
                          let outcome = DeclaredTaskStatus(rawValue: word), outcome.isClosed else {
                        throw invalid("end needs outcome completed, failed or abandoned")
                    }
                    let outputs = try values(
                        arguments["outputs"],
                        minimization: minimization,
                        secrets     : &secrets,
                        outputs     : true
                    )
                    return .end(
                        try TaskCheckpointDraft(
                            kind    : .end,
                            declared: outcome,
                            note    : text("note"),
                            outputs : outputs
                        ),
                        secrets: secrets
                    )
                case .resume:
                    guard let task = optionalText(arguments, "task") else { throw invalid("resume needs the task id") }
                    return .resume(taskID: task)
                case .status:
                    return .status
            }
        } catch let error as TaskContextError {
            throw Failure(code: "invalid_task", message: "The task cannot be recorded as given: \(error).")
        }
    }

    /// The named values of `inputs` or `outputs`: a secret's text is withheld and kept aside, a text with
    /// a credential's shape or holding a known secret is withheld whole too, a value with no text is a
    /// missing input, and the texts that describe a value (name, role, source) are minimized.
    private static func values(_ list: JSONValue, minimization: ValueMinimization, secrets: inout [String],
                               outputs: Bool) throws -> [TaskValue] {
        guard list != .null else { return [] }
        guard let items = list.array else { throw invalid("\(outputs ? "outputs" : "inputs") must be a list") }
        return try items.map { item in
            guard let fields = item.object, let name = item["name"].string, !name.isEmpty else {
                throw invalid("every value needs a name")
            }
            let allowed: Set<String> = ["name", "value", "kind", "role", "source", "source_ref", "source_version",
                                        "secret"]
            guard Set(fields.keys).isSubset(of: allowed) else { throw invalid("unknown field of value \(name)") }
            let secret = item["secret"].bool ?? false
            let source = try item["source"].string.map { word -> TaskValueSource in
                guard let known = TaskValueSource(rawValue: word) else {
                    throw invalid("unknown source of value \(name)")
                }
                return known
            } ?? (outputs ? .derived : .request)
            let declared = try item["kind"].string.map { word -> TaskValueKind in
                guard let known = TaskValueKind(rawValue: word), known != .missing else {
                    throw invalid("unknown kind of value \(name)")
                }
                return known
            } ?? .text
            let kind: TaskValueKind
            let content: TaskValue.Content
            let sensitivity: TaskValueSensitivity = secret ? .secret : .ordinary
            switch item["value"] {
                case .string(let text) where !text.isEmpty:
                    kind = declared
                    if secret {
                        secrets.append(text)
                        content = .withheld
                    } else if minimization.minimize(text: text).1 != nil {
                        secrets.append(text)
                        content = .withheld
                    } else {
                        content = .text(text)
                    }
                case .null, .string:
                    guard !outputs else { throw invalid("output \(name) needs a value") }
                    kind    = .missing
                    content = .missing
                default:
                    throw invalid("the value of \(name) must be text")
            }
            func kept(_ text: String?) -> String? { text.map { minimization.minimize(text: $0).0 } }
            return try TaskValue(
                name         : kept(name) ?? name,
                role         : kept(item["role"].string),
                kind         : kind,
                content      : content,
                sensitivity  : sensitivity,
                source       : source,
                sourceRef    : kept(item["source_ref"].string),
                sourceVersion: kept(item["source_version"].string)
            )
        }
    }

    /// The values the arguments declare secret, and those with a credential's shape: what every record
    /// of the request, its transcript first, withholds before any of it is written.
    static func declaredSecrets(in arguments: JSONValue) -> [String] {
        var found: [String] = []
        for key in ["inputs", "outputs"] {
            for item in arguments[key].array ?? [] {
                guard let text = item["value"].string, !text.isEmpty, !found.contains(text) else { continue }
                if item["secret"].bool == true || ValueMinimization.hasCredentialShape(text) { found.append(text) }
            }
        }
        return found
    }

    /// A stored value minimized by what is known now: its describing texts minimized, its text withheld
    /// whole when it holds a secret, since part of a value is no value anyone gave.
    static func minimized(_ value: TaskValue, by minimization: ValueMinimization) throws -> TaskValue {
        func kept(_ text: String?) -> String? { text.map { minimization.minimize(text: $0).0 } }
        var content = value.content
        if case .text(let text) = value.content, minimization.minimize(text: text).1 != nil { content = .withheld }
        return try TaskValue(
            name         : kept(value.name) ?? value.name,
            role         : kept(value.role),
            kind         : value.kind,
            content      : content,
            sensitivity  : value.sensitivity,
            source       : value.source,
            sourceRef    : kept(value.sourceRef),
            sourceVersion: kept(value.sourceVersion)
        )
    }

    private static func optionalText(_ arguments: JSONValue, _ key: String) -> String? {
        guard let text = arguments[key].string, !text.isEmpty else { return nil }
        return text
    }

    private static func texts(_ arguments: JSONValue, _ key: String) throws -> [String]? {
        guard arguments.object?[key] != nil else { return nil }
        guard let items = arguments[key].array else { throw invalid("\(key) must be a list of texts") }
        return try items.map { item in
            guard let text = item.string, !text.isEmpty else { throw invalid("\(key) must be a list of texts") }
            return text
        }
    }

    private static func invalid(_ message: String) -> Failure {
        Failure(code: "invalid_task", message: "The task cannot be recorded as given: \(message).")
    }
}
