//
//  SceneStructureMatcher.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

import EngineCore

/// SceneStructureMatcher is structure-v3: the conservative comparison of one observed skeleton with
/// the known scenes of its application, and the decision the comparison earns. Three outcomes per
/// known scene, same, different or uncertain, and four decisions: confirmed only when exactly one
/// scene is the same and none is uncertain; candidates whenever anything is uncertain or more than
/// one scene is the same; a new scene only when every known scene is different (or none is known)
/// and the capture is complete, on a window, dialog or sheet, with at least one structural role;
/// nothing otherwise. No threshold, no score, no first-candidate pick: what the producer cannot
/// decide stays uncertain, and an uncertain capture never becomes a scene.
///
/// Pure. The repository that calls it runs it inside the same transaction that reads the known
/// scenes and writes the decision, so two complete captures of one skeleton cannot create two
/// scenes by running at the same time.
public enum SceneStructureMatcher {

    /// What `memory_event_scenes.matched_by` and `matcher_version` say about a decision of this matcher.
    public static let method = "structure"
    public static let version = "v3"

    /// Comparison is what one known scene is to the observed skeleton.
    public enum Comparison: Sendable, Equatable {

        /// Complete capture, known and equal surfaces, equal paths, roles, captions and collections.
        case same

        /// Complete capture and a proven structural difference: the surfaces are known and differ,
        /// or a role present in one skeleton is absent from every path of the other.
        case different(Difference)

        /// Everything else: an incomplete capture, an unknown surface, different paths, captions or
        /// collections on equal roles. Not evidence of a different scene.
        case uncertain(Uncertainty)
    }

    public enum Difference: String, Sendable, Equatable {
        case surface
        case roles
    }

    public enum Uncertainty: String, Sendable, Equatable {
        case incompleteCapture = "incomplete_capture"
        case surfaceUnknown    = "surface_unknown"
        case paths
        case captions
        case collections
    }

    /// Decision is what the repository writes for the sample.
    public enum Decision: Sendable, Equatable {

        /// One confirmed association with this scene, and that scene's observation counted.
        case confirmed(sceneID: String)

        /// One candidate association per listed scene; no scene counted, no scene created.
        case candidates([String])

        /// A new scene from the observed skeleton, with one confirmed association to it.
        case newScene

        /// No row at all, for the stated reason.
        case none(Refusal)
    }

    /// Refusal is why a sample produced no association and no scene.
    public enum Refusal: String, Sendable, Equatable {

        /// The capture is the union of a window with an open pop-up: not a structural surface.
        case popupUnion = "popup_union"

        /// A capture of a menu is kept as a sample and never associated.
        case menuPhase = "menu_phase"

        /// The capture did not finish, so its absences are not facts.
        case incompleteCapture = "incomplete_capture"

        /// The surface is not known, so no new scene can be placed on one.
        case surfaceUnknown = "surface_unknown"

        /// No structural role was seen: pixels alone are not a scene.
        case emptySkeleton = "empty_skeleton"
    }

    /// Compares an observed skeleton, with the completeness of its capture, to one known scene.
    public static func compare(observed: SceneSkeleton, isComplete: Bool, known: SceneSkeleton) -> Comparison {
        guard isComplete else { return .uncertain(.incompleteCapture) }
        if observed.roles != known.roles { return .different(.roles) }
        let surfacesKnown = observed.surface != .unknown && known.surface != .unknown
            && observed.surface != .popupUnion && known.surface != .popupUnion
        if surfacesKnown, observed.surface != known.surface { return .different(.surface) }
        guard surfacesKnown else { return .uncertain(.surfaceUnknown) }
        if observed.rolesByPath != known.rolesByPath { return .uncertain(.paths) }
        if observed.captionsByPath != known.captionsByPath { return .uncertain(.captions) }
        if observed.collections != known.collections { return .uncertain(.collections) }
        return .same
    }

    /// Decides for an observed skeleton among the known scenes of its application, in the order
    /// the scenes are given (the order only affects the order of the candidate list).
    public static func decide(
        observed  : SceneSkeleton,
        isComplete: Bool,
        phase     : CapturePhase,
        among known: [(id: String, skeleton: SceneSkeleton)]
    ) -> Decision {
        guard phase.isAssociable else { return .none(.menuPhase) }
        guard observed.surface != .popupUnion else { return .none(.popupUnion) }
        var same: [String] = []
        var uncertain: [String] = []
        for scene in known {
            switch compare(observed: observed, isComplete: isComplete, known: scene.skeleton) {
                case .same        : same.append(scene.id)
                case .uncertain   : uncertain.append(scene.id)
                case .different   : break
            }
        }
        if same.count == 1, uncertain.isEmpty, let id = same.first { return .confirmed(sceneID: id) }
        if !same.isEmpty || !uncertain.isEmpty { return .candidates(same + uncertain) }
        guard isComplete else { return .none(.incompleteCapture) }
        guard [.window, .dialog, .sheet].contains(observed.surface) else { return .none(.surfaceUnknown) }
        guard !observed.isEmpty else { return .none(.emptySkeleton) }
        return .newScene
    }
}
