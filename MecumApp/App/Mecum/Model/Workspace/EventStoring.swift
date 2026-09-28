//
//  EventStoring.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation

/// EventStoring is the seam the operational record is written and read
/// through.
///
/// It exists so that a full-text index can be added beside the store without
/// the domain noticing. SwiftData has no FTS5 and search is increment 5; when
/// it arrives, a conformer can write to the store and to an index in one
/// append, and every caller here keeps compiling.
///
/// Appending is idempotent for a terminal transition: a result repeated by the
/// network returns the event already recorded, with the order it already had,
/// rather than a second one.
nonisolated protocol EventStoring: Sendable {

    /// Records `event` and returns it with its assigned order. A terminal
    /// event already recorded is returned unchanged and nothing is written.
    func append(_ event: NewEvent) async throws -> RecordedEvent

    /// Reads the record in local order. Bounded by `query.limit` when set.
    func events(matching query: EventQuery) async throws -> [RecordedEvent]
}
