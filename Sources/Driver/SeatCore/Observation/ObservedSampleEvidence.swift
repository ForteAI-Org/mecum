//
//  ObservedSampleEvidence.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

/// ObservedSampleEvidence is the uniform verdict on one captured sample, taken
/// the same way for a stream frame and for a Still.
///
/// The three cases are kept apart because they lead to different consumer
/// actions and because merging two of them is how a blank surface becomes a
/// picture of the target. Evidence that is **absent** is a sample that did not
/// carry what a decision needs; evidence that is **invalid** is a sample that
/// carried it and contradicts itself. Neither is a failure of the capture
/// framework, and neither is decided by the colour of the pixels: a legitimately
/// black window and a blank surface are indistinguishable by colour, so nothing
/// here looks at one.
///
/// It conforms to `Error` because it is the failure side of the qualifier's
/// `Result`, the same way the other refusals of this kit are. The conformance
/// carries no authority of its own: a verdict is still produced only by the
/// qualifier.
nonisolated public enum ObservedSampleEvidence: Sendable, Equatable, Error {

    /// What a sample failed to carry. The metadata was not there, so nothing was
    /// contradicted and nothing can be concluded either.
    nonisolated public enum Gap: String, Sendable, Equatable {

        /// No geometry attachment and no qualified substitute for it.
        case geometryMissing

        /// The sample carries no attested window identity, so there is no
        /// lifetime to compare against the target.
        case identityNotAttested

        /// No qualified oracle relates the sample's clock to the caller's.
        case contentClockNotQualified

        /// The capture answered nothing at all inside its deadline.
        case sampleNotDelivered
    }

    /// What a sample carried and contradicted. The values were present and do
    /// not describe a usable observation of the requested surface.
    nonisolated public enum Defect: String, Sendable, Equatable {

        /// Rectangles, scales or pixel sizes that a coordinate transform cannot
        /// be defined on.
        case geometryMalformed

        /// The mapping from window points to surface points is not one scalar,
        /// so the surface is a crop or a transform of the window.
        case geometryNotUniform

        /// The sample is of another window lifetime than the one requested.
        case identityMismatch

        /// The capture reported the sample as incomplete or idle.
        case sampleIncomplete

        /// The timestamps present do not belong to one monotonic clock.
        case timestampsInconsistent
    }

    case sufficient
    case absent(Gap)
    case invalid(Defect)

    public var isSufficient: Bool { self == .sufficient }
}
