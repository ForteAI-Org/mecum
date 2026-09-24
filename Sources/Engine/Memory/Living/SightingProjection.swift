//
//  SightingProjection.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import PerceptionCore

/// SightingProjection turns one ingested scene into the sightings it evidences, from the anchors
/// that ingest accepted for this frame and nothing else: never the brain's historical anchors, and
/// never a second match. An anchor key is a reference into the brain, not a foreign key; a sighting
/// stays a valid observation by name even if its anchor never reaches the brain's disk.
public enum SightingProjection {

    /// Abstention is why a scene evidences no sighting at all.
    public enum Abstention: String, Sendable, Equatable {
        /// The provider did not say which surfaces the pixels came from.
        case coverageUnattributed
        /// Pop-up rows share the scene under the parent's title and cannot be told apart.
        case popupsInScene
        /// The scene has no persistent application identity: empty, or a process fallback.
        case noApplicationIdentity
        /// The window title has no letters to name the window by.
        case untitledWindow
    }

    /// Projection is the result for one scene.
    public enum Projection: Sendable, Equatable {
        case observations([SightingObservation])
        case abstained(Abstention)
    }

    /// The observations a scene's accepted anchors evidence. An anchor without a nameworthy name,
    /// canonical or detected, is skipped: a sighting is recalled by name.
    public static func project(_ scene: SceneSnapshot, ingest: BrainUpdater.IngestStats) -> Projection {
        switch scene.coverage {
            case .unattributed   : return .abstained(.coverageUnattributed)
            case .windowAndPopups: return .abstained(.popupsInScene)
            case .window         : break
        }
        guard !scene.bundleID.isEmpty, !WindowContext.isProcessFallback(scene.bundleID) else {
            return .abstained(.noApplicationIdentity)
        }
        guard let context = WindowContext(bundleID: scene.bundleID, windowTitle: scene.windowTitle) else {
            return .abstained(.untitledWindow)
        }
        // Stats that were never stamped come from no ingest and accepted nothing.
        guard let seenAt = ingest.observedAt else { return .observations([]) }
        let observations = ingest.accepted.compactMap { anchor -> SightingObservation? in
            let assigned = LabelText.isNameworthy(anchor.label)
            let name = assigned ? anchor.label : anchor.detectedLabel
            guard LabelText.isNameworthy(name) else { return nil }
            return SightingObservation(
                key             : SightingKey(context: context, identity: .anchor(anchor.anchorKey)),
                name            : name,
                nameSource      : assigned ? anchor.labelSource : .observed,
                seenAt          : seenAt,
                observationBlock: ingest.observationBlock
            )
        }
        return .observations(observations)
    }
}
