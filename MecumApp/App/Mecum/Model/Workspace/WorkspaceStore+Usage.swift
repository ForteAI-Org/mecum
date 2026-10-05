//
//  WorkspaceStore+Usage.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import AgentTurn
import ChatCore
import Foundation
import ModelTransports
import SwiftData

extension WorkspaceStore {

    /// What the worker's turns used and how full its context is on `provider`,
    /// with the newest limits any turn on `provider` recorded in `workspace`,
    /// since limits belong to the account (`WorkerUsage`).
    ///
    /// Summed on every call, with the context moved by compactions and fresh
    /// contexts too. A `turnUsage` or `contextCompacted` row at another payload
    /// version, or one this build cannot decode, is skipped. The type is an enum
    /// column, which a predicate cannot compare on macOS 26 (see
    /// `WorkspaceStore+Recovery`), so these rows are selected by their key's
    /// prefix (`NewEvent.usageKeyPrefix`) and never by reading the worker's tool
    /// records, which carry whole scenes.
    // ponytail: sums every usage row of the worker on each read; keep a running total when
    // workers reach many thousands of turns.
    func usage(
        of worker   : UUID,
        on provider : ModelProvider?,
        in workspace: UUID
    ) throws -> WorkerUsage {
        let prefix = NewEvent.usageKeyPrefix
        let events = try readingContext().fetch(FetchDescriptor<WorkspaceEvent>(
            predicate: #Predicate { $0.workerID == worker && $0.deduplicationKey.starts(with: prefix) },
            sortBy   : [SortDescriptor(\.localOrder)]
        ))
        let limits = try provider.map {
            try latestRateLimits(
                for: $0,
                in : workspace
            )
        }

        return WorkerUsage(
            records   : events.compactMap(record(of:)),
            provider  : provider,
            rateLimits: limits ?? []
        )
    }

    /// The newest usage a turn on `provider` recorded in `conversation`, nil before one.
    func latestTurnUsage(
        in conversation: UUID,
        on provider    : ModelProvider
    ) throws -> TurnUsage? {
        let prefix = NewEvent.usageKeyPrefix
        return try newest(where: #Predicate { $0.conversationID == conversation && $0.deduplicationKey.starts(with: prefix) }) { event in
            turnUsage(of: event).flatMap { $0.provider == provider ? $0 : nil }
        }
    }

    /// Where Mecum's loop starts `conversation`'s history: its newest fresh
    /// context, or its newest compaction through the loop, with that one's
    /// summary. Nil when there was neither. A command line's compaction keeps its
    /// own session, so it leaves the loop's history as it was.
    func contextStart(in conversation: UUID) throws -> (date: Date, summary: String?)? {
        let prefix = NewEvent.usageKeyPrefix
        return try newest(where: #Predicate { $0.conversationID == conversation && $0.deduplicationKey.starts(with: prefix) }) { event in
            switch record(of: event) {
            case .compacted(let compaction)? where compaction.summary != nil: (event.timestamp, compaction.summary)
            case .reset?:                                                      (event.timestamp, nil)
            default:                                                           nil
            }
        }
    }

    /// The newest limits a turn on `provider` reported in `workspace`, empty before any.
    private func latestRateLimits(
        for provider: ModelProvider,
        in workspace: UUID
    ) throws -> [ProviderUsage.RateLimit] {
        let prefix = NewEvent.usageKeyPrefix
        return try newest(where: #Predicate { $0.workspaceID == workspace && $0.deduplicationKey.starts(with: prefix) }) { event in
            turnUsage(of: event).flatMap { $0.provider == provider && !$0.rateLimits.isEmpty ? $0.rateLimits : nil }
        } ?? []
    }

    /// The first value `match` makes of an event, newest first, read a page at
    /// a time; `predicate` selects usage rows only, so a page is 250 turns.
    // ponytail: gives up 5,000 usage rows back, so a provider that never reports limits reads that
    // many turns' usage on every read; keep the newest limits apart when that grows slow.
    private func newest<Value>(
        where predicate: Predicate<WorkspaceEvent>,
        _ match        : (WorkspaceEvent) -> Value?
    ) throws -> Value? {
        let context    = readingContext()
        var descriptor = FetchDescriptor<WorkspaceEvent>(
            predicate: predicate,
            sortBy   : [SortDescriptor(\.localOrder, order: .reverse)]
        )
        descriptor.fetchLimit  = 250
        descriptor.fetchOffset = 0
        while let offset = descriptor.fetchOffset, offset < 5_000 {
            let page = try context.fetch(descriptor)
            if let found = page.lazy.compactMap(match).first { return found }
            guard page.count == descriptor.fetchLimit else { return nil }

            descriptor.fetchOffset = offset + page.count
        }
        return nil
    }

    /// What a usage or context event says, nil for any other event and for one
    /// this build cannot read.
    private func record(of event: WorkspaceEvent) -> WorkerUsage.Record? {
        switch event.type {
        case .turnUsage:
            return turnUsage(of: event).map(WorkerUsage.Record.turn)
        case .contextCompacted:
            guard event.payloadVersion == ContextCompaction.payloadVersion else { return nil }
            return event.payload.flatMap(ContextCompaction.decoded).map(WorkerUsage.Record.compacted)
        case .contextReset:
            return .reset
        default:
            return nil
        }
    }

    /// The usage a `turnUsage` event holds, nil for any other event and for one
    /// this build cannot read.
    private func turnUsage(of event: WorkspaceEvent) -> TurnUsage? {
        guard event.type == .turnUsage,
              event.payloadVersion == TurnUsage.payloadVersion,
              let payload = event.payload
        else { return nil }
        return TurnUsage.decoded(payload)
    }
}
