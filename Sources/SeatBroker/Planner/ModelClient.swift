import Foundation
import SeatCore

/// Raw plan as every provider returns it: `status`, `reason`, `steps` with a
/// `"<index>:<action>"` target. One schema, one parser, four transports.
struct RawPlan: Codable, Sendable {
    struct Step: Codable, Sendable {
        let target: String
        let text: String?
        /// The number of complete primary-button clicks for a `:click` step.
        /// Omitted means one; all other verbs leave it null.
        var count: Int? = nil
        let reason: String

        /// True only when the count asks for more than one click. Nil, 0 and 1
        /// all mean the same single press, and a structured-output mode that
        /// must emit the key fills one of those three on a step with nothing to
        /// click: refusing them refuses every plan the schema allows.
        var namesMultipleClicks: Bool { (count ?? 1) >= 2 }
    }
    let status: String
    let reason: String
    let steps: [Step]
    /// The application `status: "open"` asks for. Optional so a provider that
    /// leaves the key out entirely still decodes; validation is what refuses
    /// an open without a name.
    var application: String? = nil
}

struct PlanReply: Sendable {
    let plan: RawPlan
    let usage: ModelUsage?
}

/// A model transport. It receives the full prompt and the JSON schema the
/// answer must satisfy, and returns the decoded plan. It never sees the seat.
protocol ModelClient: Sendable {
    var schemaFlavor: PlanSchema.Flavor { get }
    /// Small local models get the short prompt: fewer rules, terser scene lines.
    var prefersCompactPrompt: Bool { get }
    /// How long one answer may take before the run gives up on it.
    var requestTimeout: TimeInterval { get }
    func plan(prompt: String, schema: Data, timeout: TimeInterval) async throws -> PlanReply
}

extension ModelClient {
    var prefersCompactPrompt: Bool { false }
    var requestTimeout: TimeInterval { 180 }
}

enum PlanValidationError: LocalizedError {
    case badTarget(String)
    case unknownElement(Int, count: Int)
    case missingText(Int)
    case missingItem(Int)
    case invalidClickCount(Int)
    case unexpectedClickCount(String)
    case badScrollDelta(String)
    case stepsWithoutPlan
    case missingApplication

    var errorDescription: String? {
        switch self {
        case .badTarget(let t): "Target \"\(t)\" is not <index>:<click|type|scroll|menu>."
        case .unknownElement(let i, let c): "Element \(i) is not in the scene (\(c) elements)."
        case .missingText(let i): "type on element \(i) has no text."
        case .missingItem(let i): "menu on element \(i) names no item to choose."
        case .invalidClickCount(let count):
            "click count \(count) is outside 1...\(InputCommand.maximumClickCount)."
        case .unexpectedClickCount(let target):
            "\(target) is not a click step but names more than one click."
        case .badScrollDelta(let s): "scroll text \"\(s)\" is not a signed integer."
        case .stepsWithoutPlan: "status is not plan but steps are present."
        case .missingApplication: "status is open but \"application\" names nothing."
        }
    }
}

/// The plan contract shared by every provider.
enum PlanSchema {
    /// Which JSON Schema subset the provider's structured-output mode accepts.
    enum Flavor: Sendable {
        /// Full draft schema: Codex `--output-schema`, Ollama `format`.
        case full
        /// Anthropic: `additionalProperties: false` required, no string or array length constraints.
        case anthropic
        /// Gemini: OpenAPI subset, `nullable` instead of type unions, no `additionalProperties`.
        case gemini
    }

    /// Targets the model may copy for this scene.
    static func targets(for observation: SceneObservation) -> [String] {
        observation.elements.flatMap { e in ["\(e.index):click", "\(e.index):type", "\(e.index):scroll"] }
            + KeyName.allCases.map { "key:\($0.rawValue)" }
    }

    /// JSON schema for a decision. Every field required, no extras: that is what
    /// structured-output modes demand.
    static func json(maximumSteps: Int, maximumTextLength: Int = 2000, flavor: Flavor = .full) throws -> Data {
        var text: [String: Any]
        switch flavor {
        case .full: text = ["type": ["string", "null"], "maxLength": maximumTextLength]
        case .anthropic: text = ["anyOf": [["type": "string"], ["type": "null"]]]
        case .gemini: text = ["type": "string", "nullable": true]
        }
        // Null for every status but open, and a structured output mode requires
        // what it declares: the "text" shape, minus a name's pointless length.
        var application = text
        application.removeValue(forKey: "maxLength")
        var step: [String: Any] = [
            "type": "object",
            "required": ["target", "text", "count", "reason"],
            "properties": ["target": ["type": "string"], "text": text,
                           "count": nullableInteger(for: flavor), "reason": ["type": "string"]],
        ]
        var steps: [String: Any] = ["type": "array", "items": step]
        if flavor == .full { steps["maxItems"] = maximumSteps }
        var root: [String: Any] = [
            "type": "object",
            "required": ["status", "reason", "steps", "application"],
            "properties": [
                "status": ["type": "string", "enum": ["plan", "completed", "blocked", "open"]],
                "reason": ["type": "string"],
                "steps": steps,
                "application": application,
            ],
        ]
        if flavor != .gemini {
            step["additionalProperties"] = false
            steps["items"] = step
            root["properties"] = (root["properties"] as! [String: Any]).merging(["steps": steps]) { $1 }
            root["additionalProperties"] = false
        }
        return try JSONSerialization.data(withJSONObject: root)
    }

    private static func nullableInteger(for flavor: Flavor) -> [String: Any] {
        switch flavor {
        case .full:
            ["type": ["integer", "null"], "minimum": 1, "maximum": InputCommand.maximumClickCount]
        case .anthropic:
            ["anyOf": [["type": "integer", "minimum": 1, "maximum": InputCommand.maximumClickCount],
                        ["type": "null"]]]
        case .gemini:
            ["type": "integer", "nullable": true, "minimum": 1, "maximum": InputCommand.maximumClickCount]
        }
    }

    /// `"3"` → click 3; `"[3]"` → click 3; an exact, unique label → that
    /// element, `type` when text came along, `click` otherwise. Nil when the
    /// string names nothing or more than one thing.
    private static func looseTarget(_ target: String, text: String?, in observation: SceneObservation?)
        -> (index: Int, verb: Substring)? {
        let verb: Substring = (text?.isEmpty == false) ? "type" : "click"
        let trimmed = target.trimmingCharacters(in: CharacterSet(charactersIn: " []#"))
        if let index = Int(trimmed) { return (index, verb) }
        let matches = (observation?.elements ?? []).filter { $0.label.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        guard matches.count == 1, let element = matches.first else { return nil }
        return (element.index, verb)
    }

    private static let targetPattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])(\d+):(click|type|scroll|menu)(?![A-Za-z0-9_])"#)
    private static let keyPattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])key:([A-Za-z⌘⇧⌥⌃+]+)"#)

    /// Chords the planner may not send: they end the window the run is driving,
    /// and no scene comes back after that. A person typing /key gets them.
    private static let forbiddenChords: Set<SemanticAction> = [
        .key(.q, modifiers: .command), .key(.w, modifiers: .command),
    ]

    /// Local validation of what the model returned. The schema is never
    /// trusted to have done this: every index is checked against the scene.
    ///
    /// No observation means nothing is adopted. An open is the one decision
    /// that does not name the scene, so it still passes; every step is refused
    /// against a scene of nought elements, which is exactly what it is.
    static func decision(from raw: RawPlan, observation: SceneObservation?) throws -> PlanDecision {
        guard let declared = PlanDecision.Status(rawValue: raw.status) else {
            throw PlanValidationError.badTarget(raw.status)
        }
        // An open replaces the window every index belongs to, so it is settled
        // before the steps: no target of this scene can survive it.
        if declared == .open {
            let named = raw.application?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !named.isEmpty else { throw PlanValidationError.missingApplication }
            return PlanDecision(status: .open, reason: raw.reason, steps: [], application: named)
        }
        // A small model sometimes declares "completed" or "blocked" and still
        // lists steps. The steps are what it wants done, so they win: the run
        // executes them and decides completion on the next scene.
        let status: PlanDecision.Status = raw.steps.isEmpty ? declared : .plan
        let steps = try raw.steps.map { step -> PlanStep in
            // "[69]:click", "#69: click" and "69:click" all mean the same thing.
            let target = step.target.replacingOccurrences(of: #"[\[\]#\s]"#, with: "", options: .regularExpression)
            let range = NSRange(target.startIndex..., in: target)
            let keyMatches = keyPattern.matches(in: target, range: range)
            if keyMatches.count == 1, let match = keyMatches.first,
               let nameRange = Range(match.range(at: 1), in: target),
               let action = SemanticAction.key(chord: String(target[nameRange])) {
                guard !step.namesMultipleClicks else { throw PlanValidationError.unexpectedClickCount(step.target) }
                guard !forbiddenChords.contains(action) else {
                    throw PlanValidationError.badTarget(step.target)
                }
                return PlanStep(action: action, reason: step.reason)
            }
            let matches = targetPattern.matches(in: target, range: range)
            let index: Int
            let verb: Substring
            if matches.count == 1, let match = matches.first,
               let indexRange = Range(match.range(at: 1), in: target),
               let verbRange = Range(match.range(at: 2), in: target),
               let parsed = Int(target[indexRange]) {
                index = parsed
                verb = target[verbRange]
            } else if let resolved = looseTarget(step.target, text: step.text, in: observation) {
                // A small model wrote the element's label or a bare index. When
                // that names exactly one element, the intent is clear enough.
                index = resolved.index
                verb = resolved.verb
            } else {
                throw PlanValidationError.badTarget(step.target)
            }
            let elements = observation?.elements ?? []
            guard elements.contains(where: { $0.index == index }) else {
                throw PlanValidationError.unknownElement(index, count: elements.count)
            }
            let action: SemanticAction
            switch verb {
            case "click":
                let count = step.count ?? 1
                guard (1...InputCommand.maximumClickCount).contains(count) else {
                    throw PlanValidationError.invalidClickCount(count)
                }
                action = .click(element: index, count: count)
            case "type":
                guard !step.namesMultipleClicks else { throw PlanValidationError.unexpectedClickCount(step.target) }
                guard let text = step.text, !text.isEmpty else { throw PlanValidationError.missingText(index) }
                action = .type(element: index, text: text)
            case "menu":
                guard !step.namesMultipleClicks else { throw PlanValidationError.unexpectedClickCount(step.target) }
                // The title is the whole of what a menu step names: without one
                // there is nothing to match, so no menu is opened to try.
                guard let item = step.text?.trimmingCharacters(in: .whitespaces), !item.isEmpty else {
                    throw PlanValidationError.missingItem(index)
                }
                action = .menu(element: index, item: item)
            default:
                guard !step.namesMultipleClicks else { throw PlanValidationError.unexpectedClickCount(step.target) }
                guard let text = step.text?.trimmingCharacters(in: .whitespaces), let delta = Int32(text) else {
                    throw PlanValidationError.badScrollDelta(step.text ?? "")
                }
                action = .scroll(element: index, deltaY: delta)
            }
            return PlanStep(action: action, reason: step.reason)
        }
        return PlanDecision(status: status, reason: raw.reason, steps: steps, application: nil)
    }
}
