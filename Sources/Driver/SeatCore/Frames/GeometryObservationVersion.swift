//
//  GeometryObservationVersion.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

/// GeometryObservationVersion identifies one geometry reading inside one
/// observer generation. It is evidence that coordinates and pixels came from
/// the same reading, not a WindowServer generation: macOS exposes no atomic
/// geometry version capable of detecting a move away and back between reads.
/// The pair is scoped to its owning observer and is never a cross-stream cache
/// key, because two independent owners may both begin at generation one.
nonisolated public struct GeometryObservationVersion: Sendable, Equatable, Hashable {

    /// The lifetime of the observer that produced the reading. A restarted
    /// capture stream uses a new generation before its sequence starts again.
    public let observerGeneration: UInt64

    /// The reading's monotonic position inside `observerGeneration`.
    public let sequence: UInt64

    /// Creates a revision in the namespace of one owning observer.
    public init(observerGeneration: UInt64, sequence: UInt64) {
        self.observerGeneration = observerGeneration
        self.sequence           = sequence
    }
}
