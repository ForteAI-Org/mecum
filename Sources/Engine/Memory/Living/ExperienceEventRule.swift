//
//  ExperienceEventRule.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

/// ExperienceHistoryEntry is a recorded event with the experience it was linked to at recording
/// time, or nil when it was linked to none.
public struct ExperienceHistoryEntry: Sendable, Equatable, Codable {

    public let event: ExperienceEvent
    public let experienceID: ExperienceID?

    public init(event: ExperienceEvent, experienceID: ExperienceID?) {
        self.event        = event
        self.experienceID = experienceID
    }
}

/// ExperienceEventRule decides what recording one event does, as a pure function of the event and
/// what the store already holds. Every `LivingMemoryStoring` conformer runs it inside its own
/// atomic step, so idempotency, creation and counting mean the same thing in every adapter.
public enum ExperienceEventRule {

    /// Resolution is the rule's answer.
    public enum Resolution: Sendable, Equatable {
        /// The identical event is already recorded: write nothing.
        case duplicate(ExperienceID?)
        /// Append the entry and, when there is one, store the record: new or updated.
        case write(entry: ExperienceHistoryEntry, record: ExperienceRecord?)
    }

    /// Resolves an event.
    ///
    /// - Parameters:
    ///   - event: the event to record.
    ///   - previous: the entry already recorded under `event.id`, if any.
    ///   - target: for `.step`, the experience with the draft's natural key; for `.experience`, the
    ///     experience with that id; nil when the store holds none. Ignored for `.unattributed`.
    ///   - newID: an unused persistent id, called only when a verified success starts an experience.
    /// - Throws: `LivingMemoryError.conflictingEvent` when `event.id` was recorded with other content,
    ///   `LivingMemoryError.unknownExperience` when an `.experience` subject names nothing stored.
    public static func resolve(
        _ event : ExperienceEvent,
        previous: ExperienceHistoryEntry?,
        target  : ExperienceRecord?,
        newID   : () -> ExperienceID
    ) throws -> Resolution {
        if let previous {
            guard previous.event == event else { throw LivingMemoryError.conflictingEvent(id: event.id) }
            return .duplicate(previous.experienceID)
        }
        switch event.subject {
            case .step(let draft):
                if var record = target {
                    record.apply(event.outcome, at: event.at)
                    return .write(entry: ExperienceHistoryEntry(event: event, experienceID: record.id), record: record)
                }
                // Only a verified success starts an experience; anything else stays unlinked history.
                guard case .verified = event.outcome else {
                    return .write(entry: ExperienceHistoryEntry(event: event, experienceID: nil), record: nil)
                }
                var record = ExperienceRecord(id: newID(), draft: draft, createdAt: event.at)
                record.apply(event.outcome, at: event.at)
                return .write(entry: ExperienceHistoryEntry(event: event, experienceID: record.id), record: record)
            case .experience(let id):
                guard var record = target, record.id == id else { throw LivingMemoryError.unknownExperience(id) }
                record.apply(event.outcome, at: event.at)
                return .write(entry: ExperienceHistoryEntry(event: event, experienceID: id), record: record)
            case .unattributed:
                return .write(entry: ExperienceHistoryEntry(event: event, experienceID: nil), record: nil)
        }
    }
}
