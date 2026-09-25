//
//  WebToolRecords.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import ChatCore
import Foundation

/// WebToolRecords writes a command line's own web searches and page reads
/// as the tool records `AutomationTools.record` writes, so the tool line
/// reads them like any other step: the call `→ web_search {"query":…}` or
/// `→ web_fetch {"url":…}`, then `← name done` or `← name error: …`.
///
/// A call is written as it starts when the provider already says what it
/// searches or reads (Claude Code), and otherwise as it finishes, just
/// before its result, since Codex names its query only then. One value
/// reads one turn.
nonisolated struct WebToolRecords {

    /// The calls written as they started, by id, waiting for their result.
    private var announced: Set<String> = []

    /// The records `event` adds, in order; none for an event that is not web activity.
    mutating func lines(for event: ProviderEvent) throws -> [String] {
        guard case .web(let id, let kind, let detail, let phase) = event else { return [] }

        let name      = kind == .search ? "web_search" : "web_fetch"
        let arguments = detail.map { [kind == .search ? "query" : "url": $0] } ?? [:]
        let encoder   = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let call      = "→ \(name) \(String(decoding: try encoder.encode(arguments), as: UTF8.self))"

        switch phase {
        case .started:
            guard detail != nil else { return [] }
            if let id { announced.insert(id) }
            return [call]
        case .finished(let failed):
            let result = failed ? "← \(name) error: The web tool reported a failure." : "← \(name) done"
            if let id, announced.remove(id) != nil { return [result] }
            return [call, result]
        }
    }
}
