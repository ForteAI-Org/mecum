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

/// TurnMemory brings recall into a chat turn as data. At the start of a turn it loads the matching
/// candidate experiences and their sightings, asks `Recall.suggest` with no fresh scene (a scene
/// from an earlier turn is never fresh), keeps the decision for the inspector, and returns a
/// briefing for the prompt. During the turn, every freshly captured scene is compared with newly loaded
/// candidates, and the tools attach that comparison to the observation they return.
///
/// Nothing here calls a tool, opens an application or asks for permissions: every recall answer,
/// the legacy `fire` included, only becomes context. The briefing goes to the model inside a
/// delimited data block in the prompt, never into the system instructions, and the user's own
/// request stays separate so the briefing is never learned as a goal. Session authorizations are
/// not stored.
@MainActor
public final class TurnMemory {

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
    private var turnID: UUID?
    private var observationIndex = 0

    /// The suggestion most recently supplied to the provider, frozen by the ledger before input.
    var followed: TurnAdmission.FollowedExperience?

    public init(store: any LivingMemoryStoring, clock: @escaping () -> Date = { Date() }) {
        self.store = store
        self.clock = clock
    }

    /// Starts a turn for the user's exact request. `sessionIsOpen` says whether a Seat session is
    /// still open: only then is the last observed window the context, by identity and never as
    /// evidence of presence.
    public func begin(request: String, turnID: UUID, sessionIsOpen: Bool) async -> Preparation {
        self.request = request
        self.turnID = turnID
        observationIndex = 0
        followed = nil
        if !sessionIsOpen { lastWindow = nil }
        let context = sessionIsOpen ? lastWindow : nil
        do {
            try await loadCandidates(for: request)
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
            followed = Self.followedExperience(in: answer)
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
    public func observed(_ scene: SceneSnapshot) async -> JSONValue? {
        lastWindow = WindowContext(bundleID: scene.bundleID, windowTitle: scene.windowTitle)
        guard let request, let turnID else { return nil }
        observationIndex += 1
        let decisionID = "recall-\(turnID.uuidString)-observation-\(observationIndex)"
        do {
            try await loadCandidates(for: request)
            let answer = Recall.suggest(input: request, in: Recall.World(
                records: records, sightings: sightings, context: Recall.Context(freshScene: scene)
            ))
            followed = Self.followedExperience(in: answer)
            var decisionFailure: String?
            do {
                try await store.record(answer.decisionRecord(
                    id: decisionID, at: clock(), phrase: request, context: lastWindow
                ))
            } catch {
                decisionFailure = String(describing: error)
            }
            guard let briefing = RecallBriefing(answer, records: records) else {
                return decisionFailure.map { Self.unavailable("The recall decision was not saved: " + $0) }
            }
            let value = try Self.decoder.decode(JSONValue.self, from: Self.encode(briefing))
            if let decisionFailure, case .object(var fields) = value {
                fields["decisionFailure"] = .string(decisionFailure)
                return .object(fields)
            }
            return value
        } catch {
            records = []
            sightings = []
            followed = nil
            return Self.unavailable(String(describing: error))
        }
    }

    /// Loads every matching record so recall can rank it with the current context. A global
    /// recency cutoff would discard a relevant record before a later observation can identify it.
    private func loadCandidates(for request: String) async throws {
        records = try await store.candidates(for: request, in: nil)
        sightings = try await store.sightings(in: Set(records.map(\.context.bundleID)))
    }

    private static func followedExperience(in answer: Recall.SuggestionAnswer) -> TurnAdmission.FollowedExperience? {
        guard case .suggest(let suggestion, _) = answer else { return nil }
        return TurnAdmission.FollowedExperience(
            id: suggestion.record.id, step: suggestion.record.step, context: suggestion.record.context
        )
    }

    private static func unavailable(_ reason: String) -> JSONValue {
        .object([
            "status": .string("unavailable"),
            "reason": .string(reason),
            "guidance": .string("Memory is unavailable. Decide from the fresh scene and the user's request.")
        ])
    }

    /// Ends the turn: later observations are not compared until the next turn begins.
    public func end() {
        request = nil
        turnID = nil
        followed = nil
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
