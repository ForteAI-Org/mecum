//
//  WorkspaceStore+Events.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import SwiftData

extension WorkspaceStore: EventStoring {

    /// Records the event and gives it the next local order.
    ///
    /// A terminal event for a subject that has already ended returns the row
    /// that is there, untouched, whatever outcome the second arrival carries:
    /// the first arrival keeps its type, its timestamp and its order, and no
    /// work ends twice.
    ///
    /// That guarantee is this method's, not the schema's. The unique constraint
    /// on `WorkspaceEvent.deduplicationKey` keeps one row per key, but on a
    /// conflict SwiftData updates the row with the later values. The lookup and
    /// the insert below run under the actor with no suspension between them,
    /// which is what makes first arrival hold, so this must stay the only code
    /// that inserts a `WorkspaceEvent`.
    @discardableResult
    public func append(_ event: NewEvent) throws -> RecordedEvent {
        let key = event.deduplicationKey
        if let existing = try first(WorkspaceEvent.self, where: #Predicate { $0.deduplicationKey == key }) {
            return RecordedEvent(existing)
        }

        let recorded = WorkspaceEvent(event, localOrder: try nextLocalOrder(in: event.workspaceID))
        modelContext.insert(recorded)
        try saveOrRollBack()
        return RecordedEvent(recorded)
    }

    public func events(matching query: EventQuery) throws -> [RecordedEvent] {
        var descriptor = FetchDescriptor<WorkspaceEvent>(
            predicate: Self.predicate(for: query.scope),
            sortBy   : [SortDescriptor(\.localOrder, order: query.isAscending ? .forward : .reverse)]
        )
        if let limit = query.limit {
            // Zero would mean no limit to the fetch, the opposite of what was asked.
            guard limit > 0 else { return [] }
            descriptor.fetchLimit = limit
        }
        return try modelContext.fetch(descriptor).map(RecordedEvent.init)
    }

    /// A conversation's events whose timestamp falls in `start ..< end`: the
    /// latest `limit` of them, returned in local order.
    ///
    /// The transcript reads the events between two messages with this, so a
    /// window of messages costs its own events and not the conversation's.
    public func events(
        inConversation conversation: UUID,
        from start                 : Date,
        before end                 : Date,
        limit                      : Int
    ) throws -> [RecordedEvent] {
        // A fetch limit of zero means no limit, so zero asked for is answered without a fetch.
        guard limit > 0 else { return [] }
        var descriptor = FetchDescriptor<WorkspaceEvent>(
            predicate: #Predicate {
                $0.conversationID == conversation && $0.timestamp >= start && $0.timestamp < end
            },
            sortBy   : [SortDescriptor(\.localOrder, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).reversed().map(RecordedEvent.init)
    }

    /// One predicate per scope. Written apart so each stays a single
    /// comparison the fetch can meet with an index.
    private static func predicate(for scope: EventQuery.Scope) -> Predicate<WorkspaceEvent> {
        switch scope {
        case .workspace(let id):    return #Predicate<WorkspaceEvent> { $0.workspaceID    == id }
        case .worker(let id):       return #Predicate<WorkspaceEvent> { $0.workerID       == id }
        case .conversation(let id): return #Predicate<WorkspaceEvent> { $0.conversationID == id }
        case .subject(let id):      return #Predicate<WorkspaceEvent> { $0.subjectID      == id }
        }
    }

    /// One past the highest order in the workspace. Exclusive within this
    /// actor, which is why two appends cannot take the same number.
    private func nextLocalOrder(in workspace: UUID) throws -> Int {
        var descriptor = FetchDescriptor<WorkspaceEvent>(
            predicate: #Predicate { $0.workspaceID == workspace },
            sortBy   : [SortDescriptor(\.localOrder, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try modelContext.fetch(descriptor).first?.localOrder ?? 0) + 1
    }
}
