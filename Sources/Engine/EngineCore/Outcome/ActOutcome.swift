//
//  ActOutcome.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import PerceptionCore

/// ActOutcomeKind is the closed vocabulary an action answers with. A model's next move depends on
/// which one it is, so each names a distinct situation and none is a synonym for another.
public enum ActOutcomeKind: String, Sendable, Codable, CaseIterable {
    /// The target was found and a structural change was observed after acting.
    case foundActed = "found_acted"
    /// The gesture went out but no change could be attributed to it. Re-perceive, do not retry blind.
    case actedUnverified = "acted_unverified"
    /// Nothing was done on purpose, and the message says what to do instead.
    case actedNoop = "acted_noop"
    /// Several elements carry the target's name; the caller must add a section or an id.
    case ambiguous
    /// No such target on this screen.
    case honestMiss = "honest_miss"
    /// The action is not allowed here: a destructive target, a disabled row.
    case refused
    /// A dry run: what would have happened.
    case dryRun = "dry_run"
}

/// ActOutcome is one action's answer: its kind, a sentence a person can act on, and the scene after
/// acting when one was taken, so the caller never pays a second perception to see what happened.
/// `check` is what the operation's oracle controlled (`OperationCheck`), when the path that answered
/// reports it; nil for a path that does not, which the living memory records as an explicit gap.
public struct ActOutcome: Sendable, Equatable {

    public let kind: ActOutcomeKind
    public let message: String
    public let scene: SceneSnapshot?
    public let check: OperationCheck?

    public init(_ kind: ActOutcomeKind, _ message: String, scene: SceneSnapshot? = nil, check: OperationCheck? = nil) {
        self.kind    = kind
        self.message = message
        self.scene   = scene
        self.check   = check
    }

    /// The same outcome with another scene, its check kept.
    public func with(scene: SceneSnapshot?) -> ActOutcome {
        ActOutcome(kind, message, scene: scene, check: check)
    }

    /// The same outcome with another message, its scene and check kept.
    public func with(message: String) -> ActOutcome {
        ActOutcome(kind, message, scene: scene, check: check)
    }

    /// The same outcome with this check, its kind, message and scene kept.
    public func with(check: OperationCheck?) -> ActOutcome {
        ActOutcome(kind, message, scene: scene, check: check)
    }

    /// True for the one outcome that claims success. Everything else asks the caller to look again.
    public var isSuccess: Bool { kind == .foundActed }

    /// The outcome with a check: its own when its path stated one, else what its kind allows saying.
    /// A refusal, a miss, an ambiguity, a dry run or a no-op sent no gesture (a miss or an ambiguity
    /// resolved no target); an outcome that claims a gesture without a check says it is unknown.
    public var withStatedCheck: ActOutcome {
        guard check == nil else { return self }
        switch kind {
            case .honestMiss, .ambiguous:
                return with(check: .unchecked(performed: .none, limits: [.targetNotResolved]))
            case .refused, .dryRun, .actedNoop:
                return with(check: .unchecked(performed: .none))
            case .foundActed, .actedUnverified:
                return with(check: .unchecked(performed: .uncertain))
        }
    }
}
