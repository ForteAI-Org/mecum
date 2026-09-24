//
//  TurnMemory.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import Foundation
import LocalMCP
import Memory
import PerceptionCore

/// TurnMemory brings recall into a chat turn as data. At the start of a turn it loads a bounded set
/// of candidate experiences and their sightings, asks `Recall.suggest` with no fresh scene (a scene
/// from an earlier turn is never fresh), keeps the decision for the inspector, and returns a
/// briefing for the prompt. During the turn, every freshly captured scene is compared with the same
/// records, and the tools attach that comparison to the observation they return.
///
/// Nothing here calls a tool, opens an application or asks for permissions: every recall answer,
/// the legacy `fire` included, only becomes context. The briefing goes to the model inside a
/// delimited data block in the prompt, never into the system instructions, and the user's own
/// request stays separate so the briefing is never learned as a goal. Session authorizations are
/// not stored.
@MainActor
public final class TurnMemory {

    /// The most candidate experiences a turn loads.
    public static let candidateLimit = 20

    /// Preparation is what recall contributed to one turn.
    public struct Preparation: Sendable {
        /// The briefing for the prompt, or nil when nothing matched or the store could not be read.
        public let briefing: RecallBriefing?
        /// The experience the turn is offered, for attributing a later contradiction.
        public let followed: TurnAdmission.FollowedExperience?
        /// Why the living memory could not be read, when it could not. Not "nothing remembered".
        public let failure: String?
        /// Why the decision could not be kept for the inspector; the briefing still stands.
        public let decisionFailure: String?
    }

    private let store: any LivingMemoryStoring
    private let clock: () -> Date
    private var request: String?
    private var records: [ExperienceRecord] = []
    private var sightings: [Sighting] = []
    private var lastWindow: WindowContext?

    public init(store: any LivingMemoryStoring, clock: @escaping () -> Date = { Date() }) {
        self.store = store
        self.clock = clock
    }

    /// Starts a turn for the user's exact request. `sessionIsOpen` says whether a Seat session is
    /// still open: only then is the last observed window the context, by identity and never as
    /// evidence of presence.
    public func begin(request: String, turnID: UUID, sessionIsOpen: Bool) async -> Preparation {
        self.request = request
        if !sessionIsOpen { lastWindow = nil }
        let context = sessionIsOpen ? lastWindow : nil
        do {
            let candidates = try await store.candidates(for: request, in: nil)
                .sorted { ($0.lastVerifiedAt ?? $0.createdAt) > ($1.lastVerifiedAt ?? $1.createdAt) }
                .prefix(Self.candidateLimit)
            records = Array(candidates)
            sightings = try await store.sightings(in: Set(records.map(\.context.bundleID)))
            guard !records.isEmpty else {
                return Preparation(briefing: nil, followed: nil, failure: nil, decisionFailure: nil)
            }
            let answer = Recall.suggest(input: request, in: Recall.World(
                records  : records,
                sightings: sightings,
                context  : Recall.Context(bundleID: context?.bundleID, windowFamily: context?.windowFamily)
            ))
            var decisionFailure: String?
            do {
                try await store.record(answer.decisionRecord(id: "recall-\(turnID.uuidString)", at: clock(),
                                                             phrase: request, context: context))
            } catch {
                decisionFailure = String(describing: error)
            }
            var followed: TurnAdmission.FollowedExperience?
            if case .suggest(let suggestion, _) = answer {
                followed = TurnAdmission.FollowedExperience(id: suggestion.record.id, step: suggestion.record.step,
                                                            context: suggestion.record.context)
            }
            return Preparation(briefing: RecallBriefing(answer, records: records), followed: followed, failure: nil,
                               decisionFailure: decisionFailure)
        } catch {
            records = []
            sightings = []
            return Preparation(briefing: nil, followed: nil, failure: String(describing: error), decisionFailure: nil)
        }
    }

    /// Compares the turn's candidates with a scene captured just now, and remembers the scene's window
    /// as the context for later turns of the same session. Returns the briefing as JSON for the
    /// observation, or nil outside a turn or when nothing matched.
    public func observed(_ scene: SceneSnapshot) -> JSONValue? {
        lastWindow = WindowContext(bundleID: scene.bundleID, windowTitle: scene.windowTitle)
        guard let request, !records.isEmpty else { return nil }
        let answer = Recall.suggest(input: request, in: Recall.World(
            records: records, sightings: sightings, context: Recall.Context(freshScene: scene)
        ))
        guard let briefing = RecallBriefing(answer, records: records) else { return nil }
        // A briefing of strings, integers and dates always encodes; nil would only drop the annotation.
        return try? Self.decoder.decode(JSONValue.self, from: Self.encode(briefing))
    }

    /// Ends the turn: later observations are not compared until the next turn begins.
    public func end() {
        request = nil
        records = []
        sightings = []
    }

    /// The provider prompt: the briefing as one delimited JSON line, then the user's request as
    /// written. Inside the JSON, `<` and `>` are escaped, so no remembered text can close the block.
    public static func prompt(for request: String, briefing: RecallBriefing?) throws -> String {
        guard let briefing else { return request }
        let json = String(decoding: try encode(briefing), as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
        return "<mecum-memory>\n\(json)\n</mecum-memory>\n\n\(request)"
    }

    private static func encode(_ briefing: RecallBriefing) throws -> Data {
        let encoder = KnowledgeCoding.makeEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(briefing)
    }

    private static let decoder = JSONDecoder()
}
