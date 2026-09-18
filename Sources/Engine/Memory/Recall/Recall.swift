//
//  Recall.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import Foundation
import PerceptionCore

/// Recall is the one place that decides whether a remembered experience may replay. It answers
/// `fire` (a tool and its arguments, no model round), `hint` (something worth whispering, no action)
/// or `abstain` (no action, with a reason). Everything a decision reads arrives as a `World`, so
/// recall is a pure function of a value a test can construct. Policy lives here, never in a frontend.
public enum Recall {

    /// Fire is a replay: the tool, its arguments, and the line a frontend prints.
    public struct Fire: Sendable, Equatable {
        public let tool: String
        public let argsJSON: String
        public let note: String
    }

    /// Abstention is why recall answered with no action. `refused` names the remembered phrase recall
    /// had and would not trust: "seen but not trusted" is owed a sentence, "never seen it" is not.
    public struct Abstention: Sendable, Equatable {
        public let reason: String
        public let refused: String?

        public var narration: String? { refused == nil ? nil : "memory: \(reason)" }
    }

    public enum Answer: Sendable, Equatable {
        case fire(Fire)
        case hint(String)
        case abstain(Abstention)
    }

    /// World is everything a decision reads: the remembered experiences and the entity evidence.
    public struct World: Sendable {
        public let memories: [Experience]
        public let evidence: RecallEvidence

        public init(memories: [Experience], evidence: RecallEvidence) {
            self.memories = memories
            self.evidence = evidence
        }

        public init(memories: [Experience], graph: SightingGraph = SightingGraph()) {
            self.init(memories: memories, evidence: RecallEvidence(graph: graph))
        }
    }

    /// Matches the input against remembered experiences and answers once. An exact token match
    /// replays as-is; a one-token difference substitutes into the remembered arguments; an extra
    /// token naming another application graph retargets the verb there. Every substituted slot must
    /// pass the entity-evidence gate, or recall abstains and says why.
    public static func decide(input: String, in world: World) -> Answer {
        let inputTokens = Set(GoalPhrase.tokens(input))
        guard !inputTokens.isEmpty else {
            return .abstain(Abstention(reason: "nothing to match on in \"\(input)\"", refused: nil))
        }
        var refusal: Abstention?
        for memory in world.memories where memory.ok > memory.fail && memory.tool != "send_message" {
            switch consider(memory, inputTokens: inputTokens, evidence: world.evidence) {
                case .fire(let fire):
                    return .fire(fire)
                case .refuse(let abstention):
                    // A different memory may still earn its replay; the first refusal is what is said if none does.
                    if refusal == nil { refusal = abstention }
                case .noMatch:
                    continue
            }
        }
        if let refusal { return .abstain(refusal) }
        if let hint = MemoryHint.hint(input: input, from: world.memories) { return .hint(hint) }
        return .abstain(Abstention(reason: "nothing remembered matches \"\(input)\"", refused: nil))
    }

    private enum Candidate {
        case fire(Fire)
        case refuse(Abstention)
        case noMatch
    }

    private static func consider(
        _ memory   : Experience,
        inputTokens: Set<String>,
        evidence   : RecallEvidence
    ) -> Candidate {
        let memoryTokens = Set(memory.tokens)
        if memoryTokens == inputTokens {
            return .fire(Fire(tool: memory.tool, argsJSON: memory.argsJSON,
                              note: "remembered: \"\(memory.phrase)\" ✓×\(memory.ok)"))
        }
        var onlyMemory = memoryTokens.subtracting(inputTokens)
        var onlyInput = inputTokens.subtracting(memoryTokens)
        // A cross-graph hop: an extra token naming a known graph retargets the verb. Nominated here,
        // evidenced below.
        var hopToken: String?
        if let token = onlyInput.first(where: { !evidence.graph.bundles(matching: $0).isEmpty }) {
            hopToken = token
            onlyInput.remove(token)
            if let other = onlyMemory.first(where: { !evidence.graph.bundles(matching: $0).isEmpty }) {
                onlyMemory.remove(other)
            }
        }
        let pureHop = hopToken != nil && onlyMemory.isEmpty && onlyInput.isEmpty
        let oneSwap = onlyMemory.count == 1 && onlyInput.count == 1
        guard pureHop || oneSwap else { return .noMatch }
        guard let data = memory.argsJSON.data(using: .utf8),
              var arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else {
            return .noMatch
        }

        var swapNote = ""
        // The slots recall filled itself, by slot, judged on the value the call would actually carry.
        var substituted: [String: String] = [:]
        if oneSwap {
            guard let old = onlyMemory.first, let new = onlyInput.first else { return .noMatch }
            for (slot, value) in arguments where LabelText.coreKey(value) == LabelText.coreKey(old) {
                arguments[slot]   = new
                substituted[slot] = new
            }
            guard !substituted.isEmpty else { return .noMatch }
            swapNote = ": \(old) → \(new)"
        }
        if let hop = hopToken {
            let targets = evidence.graph.bundles(matching: hop)
            let entities = arguments.filter { $0.key != "app" }.map(\.value)
            if !entities.isEmpty {
                let evidenced = entities.contains { value in
                    targets.contains { evidence.graph.sighted[$0]?.contains(LabelText.coreKey(value)) == true }
                }
                guard evidenced else {
                    return .refuse(refusal(memory, "nothing from \"\(memory.phrase)\" has been seen in \(hop)"))
                }
            }
            // A hop that overwrites a value the swap just wrote would drop the word the user said.
            if let dropped = substituted["app"], dropped != hop {
                return .refuse(refusal(memory, "\"\(dropped)\" would be dropped, not used"))
            }
            arguments["app"]   = hop
            substituted["app"] = hop
            swapNote += " · → \(hop)"
        }
        for (slot, value) in substituted.sorted(by: { $0.key < $1.key }) {
            if let why = unevidenced(slot: slot, value: value, arguments: arguments, evidence: evidence) {
                return .refuse(refusal(memory, why))
            }
        }
        guard let out = try? JSONSerialization.data(withJSONObject: arguments),
              let json = String(data: out, encoding: .utf8) else { return .noMatch }
        return .fire(Fire(tool: memory.tool, argsJSON: json,
                          note: "generalized from \"\(memory.phrase)\" ✓×\(memory.ok)\(swapNote)"))
    }

    private static func refusal(_ memory: Experience, _ why: String) -> Abstention {
        Abstention(reason: "remembered \"\(memory.phrase)\" ✓×\(memory.ok), but \(why)", refused: memory.phrase)
    }

    /// Slots that name an application rather than something inside one.
    private static let appShapedSlots: Set<String> = ["app", "bundle", "bundle_id"]

    /// The gate in one sentence: an app-shaped slot must name exactly one known application, and any
    /// other slot must name something sighted inside the application the call targets. Returns why the
    /// value fails, or nil when it is evidenced.
    private static func unevidenced(slot: String, value: String, arguments: [String: String],
                                    evidence: RecallEvidence) -> String? {
        if appShapedSlots.contains(slot) {
            switch evidence.app(named: value) {
                case .one                  : return nil
                case .unknown              : return "\"\(value)\" names no app I know"
                case .several(let bundles) : return "\"\(value)\" could be any of \(bundles.count) apps I know"
            }
        }
        guard let appValue = arguments["app"] ?? arguments["bundle"], !appValue.isEmpty else {
            return "\"\(value)\" is in no app I can check"
        }
        guard evidence.sighting(value, inAppNamed: appValue) else {
            return "I have never seen \"\(value)\" in \(appValue)"
        }
        return nil
    }
}
