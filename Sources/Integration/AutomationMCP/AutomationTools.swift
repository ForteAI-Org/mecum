import AppKit
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import PerceptionCore
import PrivateSymbols
import SeatCore
import WindowServerListing

/// AutomationTools is the MCP adapter over AutomationSession. It validates a complete request before effects,
/// requires the current ephemeral session ID, and records authoritative outcomes for the transcript.
public final class AutomationTools {
    public let session: any AutomationSessionOperating
    public var record: ((String) throws -> Void)?
    private var revision = 0

    public init(session: any AutomationSessionOperating) {
        self.session = session
    }

    public static var definitions: [JSONValue] {
        let text: JSONValue = .object(["type": .string("string"), "minLength": .number(1)])
        let session = ["session": text]
        let action: [String: JSONValue] = [
            "target": text, "verb": .object(["type": .string("string"),
                "enum": .array(ActionVerb.allCases.map { .string($0.rawValue) })]),
            "value": .object(["type": .string("string"), "enum": .array([.string("on"), .string("off")])]),
            "section": text
        ]
        func tool(_ name: String, _ description: String, _ properties: [String: JSONValue],
                  _ required: [String], readOnly: Bool = false) -> JSONValue {
            .object(["name": .string(name), "description": .string(description),
                     "inputSchema": schema(properties, required),
                     "annotations": .object(["readOnlyHint": .bool(readOnly)])])
        }
        return [
            tool("status", "Read Mecum's permission and session status. Never prompts.", [:], [], readOnly: true),
            tool("windows", "Discover exact running application names, bundle IDs and window titles. Optional app filter.",
                 ["app": text], [], readOnly: true),
            tool("open_session", "Adopt an app into one persistent background Seat and observe it. "
                 + "Use an exact window title when needed. Close the current session before opening another.",
                 ["app": text, "window": text], ["app"]),
            tool("observe", "Read a fresh scene in this session, including its current dialog. Required after resuming chat.",
                 session, ["session"], readOnly: true),
            tool("act", "Resolve a current label or element ID, act, and verify. set_toggle requires value on/off. "
                 + "Never automatically repeat acted_unverified. No keyboard, typing or scrolling is supported yet.",
                 session.merging(action, uniquingKeysWith: { $1 }), ["session", "target"]),
            tool("select", "Choose a visible dropdown item and verify its new value. control is its current value/label.",
                 session.merging(["control": text, "item": text], uniquingKeysWith: { $1 }),
                 ["session", "control", "item"]),
            tool("batch", "Run up to 20 act/select steps in the current Seat. Stop on the first unsuccessful outcome. "
                 + "Earlier effects remain; no rollback or replay. Each step observes again.",
                 session.merging(["steps": .object(["type": .string("array"), "minItems": .number(1),
                     "maxItems": .number(20), "items": .object(["oneOf": .array([
                         schema(action.merging(["operation": .object(["const": .string("act")])],
                                               uniquingKeysWith: { $1 }), ["operation", "target"]),
                         schema(["operation": .object(["const": .string("select")]), "control": text, "item": text],
                                ["operation", "control", "item"])
                     ])])])], uniquingKeysWith: { $1 }), ["session", "steps"]),
            tool("close_session", "Return the application's windows and release its Seat.", session, ["session"])
        ]
    }

    public func call(_ name: String, _ arguments: JSONValue) async throws -> JSONValue {
        do {
            return try await dispatch(name, arguments)
        } catch {
            try record?("← \(name) error: \(error). Observe before any retry.")
            throw error
        }
    }

    private func dispatch(_ name: String, _ arguments: JSONValue) async throws -> JSONValue {
        let arguments = arguments == .null ? JSONValue.object([:]) : arguments
        guard let definition = Self.definitions.first(where: { $0["name"].string == name }),
              let values = arguments.object else { throw AutomationFailure("Invalid tool arguments.") }
        let schema = definition["inputSchema"]
        let allowed = Set(schema["properties"].object?.keys.map { $0 } ?? [])
        guard Set(values.keys).isSubset(of: allowed) else { throw AutomationFailure("Unknown tool argument.") }
        for field in schema["required"].array ?? [] {
            guard let key = field.string, values[key] != nil else { throw AutomationFailure("A required argument is missing.") }
        }
        try record?("→ \(name) \(String(decoding: try JSONEncoder().encode(arguments), as: UTF8.self))")
        let value: JSONValue
        if !["status", "windows", "open_session"].contains(name) {
            guard let id = session.id, arguments["session"].string == id.uuidString else {
                throw AutomationFailure("Session ID is missing or stale. Use status; open a session if necessary and observe again.")
            }
        }
        switch name {
        case "status":
            value = .object(["session": session.id.map { .string($0.uuidString) } ?? .null,
                "permissions": .object([
                    "screenRecording": .bool(Permissions.preflight(.screenRecording)),
                    "accessibility": .bool(Permissions.preflight(.accessibility)),
                    "postEvent": .bool(Permissions.preflight(.postEvent))
                ])])
        case "windows":
            let apps: [NSRunningApplication]
            if values["app"] != nil { apps = [try RunningApplicationLookup.running(try string(arguments, "app"))] }
            else { apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular } }
            value = .object(["applications": .array(try apps.map { app in
                let rows = try WindowServerWindowListing().windows(ownedBy: app.processIdentifier)
                return .object(["name": .string(app.localizedName ?? ""),
                    "bundleID": .string(app.bundleIdentifier ?? ""), "pid": .number(Double(app.processIdentifier)),
                    "windows": .array(rows.map { .object(["id": .number(Double($0.number)),
                                                         "title": .string($0.title ?? "")]) })])
            })])
        case "open_session":
            let scene = try await session.open(application: string(arguments, "app"),
                                                window: optionalString(arguments, "window"))
            value = observation(scene)
        case "observe": value = observation(try await session.observe())
        case "act", "select":
            let step = try Step(name, arguments)
            value = outcome(try await perform(step))
        case "batch":
            guard let rows = arguments["steps"].array, (1...20).contains(rows.count) else {
                throw AutomationFailure("batch requires 1...20 steps.")
            }
            let steps = try rows.map { try Step(string($0, "operation"), $0) }
            var results: [JSONValue] = []
            var complete = true
            var verified = 0
            for (index, step) in steps.enumerated() {
                try Task.checkCancellation()
                let result: ActOutcome
                do { result = try await perform(step) }
                catch {
                    let failed: JSONValue = .object(["status": .string("error"), "message": .string(String(describing: error)),
                        "guidance": .string("Earlier effects remain. Observe before deciding the next step.")])
                    results.append(failed)
                    try record?("← batch step \(index + 1) error: \(error)")
                    complete = false
                    break
                }
                let value = outcome(result)
                results.append(value)
                try record?("← batch step \(index + 1) \(String(decoding: try JSONEncoder().encode(value), as: UTF8.self))")
                let accepted = result.kind == .foundActed
                    || (result.kind == .actedNoop && step.isToggle)
                if !accepted { complete = false; break }
                verified += 1
            }
            value = .object(["status": .string(complete ? "completed" : "stopped"),
                             "steps": .array(results), "attemptedSteps": .number(Double(results.count)),
                             "verifiedSteps": .number(Double(verified)),
                             "requested": .number(Double(steps.count))])
        case "close_session":
            await session.close()
            value = .object(["status": .string("closed"), "message": .string("Application session closed.")])
        default: throw AutomationFailure("Unknown tool: \(name)")
        }
        try record?("← \(name) \(String(decoding: try JSONEncoder().encode(value), as: UTF8.self))")
        return MCPRouter.toolResult(value)
    }

    private func perform(_ step: Step) async throws -> ActOutcome {
        switch step {
        case .act(let target, let verb, let section, let state):
            try await session.act(target: target, verb: verb, section: section, desiredState: state)
        case .select(let control, let item):
            try await session.select(control: control, item: item)
        }
    }

    private func observation(_ scene: SceneSnapshot) -> JSONValue {
        revision += 1
        return .object(["session": session.id.map { .string($0.uuidString) } ?? .null,
                        "revision": .number(Double(revision)), "observedAt": .string(Date().ISO8601Format()),
                        "scene": .string(scene.text())])
    }

    private func outcome(_ outcome: ActOutcome) -> JSONValue {
        var values: [String: JSONValue] = [
            "status": .string(outcome.kind.rawValue), "message": .string(outcome.message),
            "session": session.id.map { .string($0.uuidString) } ?? .null
        ]
        if let scene = outcome.scene { values["observation"] = observation(scene) }
        return .object(values)
    }

    private static func schema(_ properties: [String: JSONValue], _ required: [String]) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties),
                 "required": .array(required.map { .string($0) }), "additionalProperties": .bool(false)])
    }

    private func string(_ object: JSONValue, _ key: String) throws -> String {
        try Self.requiredString(object, key)
    }

    private func optionalString(_ object: JSONValue, _ key: String) throws -> String? {
        object.object?[key] == nil ? nil : try string(object, key)
    }

    private static func requiredString(_ object: JSONValue, _ key: String) throws -> String {
        guard let value = object[key].string, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutomationFailure("\(key) must be a nonempty string.")
        }
        return value
    }

    private enum Step {
        case act(String, ActionVerb, String?, ControlState?)
        case select(String, String)

        var isToggle: Bool {
            if case .act(_, .setToggle, _, _) = self { true } else { false }
        }

        init(_ name: String, _ args: JSONValue) throws {
            let permitted: Set<String> = name == "act"
                ? ["operation", "session", "target", "verb", "section", "value"]
                : ["operation", "session", "control", "item"]
            guard let object = args.object, Set(object.keys).isSubset(of: permitted) else {
                throw AutomationFailure("Unknown step argument.")
            }
            if name == "select" {
                self = .select(try requiredString(args, "control"), try requiredString(args, "item"))
            } else if name == "act" {
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
                self = .act(try requiredString(args, "target"), verb,
                            object["section"] == nil ? nil : try requiredString(args, "section"), state)
            } else { throw AutomationFailure("batch supports act and select only.") }
        }
    }
}
