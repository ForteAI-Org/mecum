//
//  LivingMemoryError.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

/// LivingMemoryError is a refused living-memory write. Each case is a rejection before any effect:
/// the store is unchanged, and repeating the same call is refused the same way.
public enum LivingMemoryError: Error, Sendable, Equatable {

    /// An event names an experience the store does not hold.
    case unknownExperience(ExperienceID)

    /// An event id was already recorded with different content. The id is an idempotency key, so
    /// reusing it for another event is a recorder bug, never a second event.
    case conflictingEvent(id: String)

    /// A recall decision id was already recorded with different content.
    case conflictingDecision(id: String)
}
