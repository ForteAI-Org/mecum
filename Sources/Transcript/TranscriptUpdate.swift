//
//  TranscriptUpdate.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation

/// TranscriptUpdate is the difference between two projections of the same
/// conversation, as `TranscriptController` applies it: rows removed, rows
/// inserted, and rows whose identity stayed while their content changed.
///
/// Identity is what decides. A reply whose delivery moved is one `changed`
/// row, never a removal and an insertion, and no update replaces every id.
/// Rows never move relative to each other, so a difference that would need a
/// move is expressed as a removal and an insertion.
public struct TranscriptUpdate: Sendable, Equatable {

    /// Indices in the old rows, ascending.
    public let removed : [Int]

    /// Indices in the new rows, ascending.
    public let inserted: [Int]

    /// Ids present in both whose content differs.
    public let changed : [TranscriptItem.ID]

    public var isEmpty: Bool { removed.isEmpty && inserted.isEmpty && changed.isEmpty }

    public init(from old: [TranscriptItem], to new: [TranscriptItem]) {
        let difference = new.map(\.id).difference(from: old.map(\.id))
        var removed : [Int] = []
        var inserted: [Int] = []
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.append(offset)
            case .insert(let offset, _, _): inserted.append(offset)
            }
        }
        let previous = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let moved    = Set(inserted.map { new[$0].id })
        self.removed  = removed.sorted()
        self.inserted = inserted.sorted()
        self.changed  = new.compactMap { item in
            guard !moved.contains(item.id), let before = previous[item.id], before != item else { return nil }
            return item.id
        }
    }
}
