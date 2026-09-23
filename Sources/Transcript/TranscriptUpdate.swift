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
///
/// One exception keeps a reply from popping in: a worker's reply that lands
/// in the slot a thinking bubble leaves takes that bubble's row. It is neither
/// removed nor inserted but `changed`, and listed in `replaced`, so the cell
/// that showed the dots shows the reply, at the same position.
public struct TranscriptUpdate: Sendable, Equatable {

    /// Indices in the old rows, ascending.
    public let removed : [Int]

    /// Indices in the new rows, ascending.
    public let inserted: [Int]

    /// Ids present in both whose content differs, and the replies that took a thinking bubble's row.
    public let changed : [TranscriptItem.ID]

    /// Indices in the new rows of the replies that took a thinking bubble's row, ascending.
    public let replaced: [Int]

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
        removed.sort()
        inserted.sort()
        let replaced = Self.replacements(old, new, removed: &removed, inserted: &inserted)

        let previous = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let moved    = Set(inserted.map { new[$0].id })
        let taken    = Set(replaced.map { new[$0].id })
        self.removed  = removed
        self.inserted = inserted
        self.replaced = replaced
        self.changed  = new.compactMap { item in
            if taken.contains(item.id) { return item.id }
            guard !moved.contains(item.id), let before = previous[item.id], before != item else { return nil }
            return item.id
        }
    }

    /// Pairs each removed thinking bubble with a worker reply inserted into
    /// the same slot among the rows that stay, and drops both from the lists.
    /// A row that stays keeps its slot, which is its index less the removed
    /// rows before it in the old list, and less the inserted ones in the new.
    private static func replacements(
        _ old   : [TranscriptItem],
        _ new   : [TranscriptItem],
        removed : inout [Int],
        inserted: inout [Int]
    ) -> [Int] {
        var replaced: [Int] = []
        for oldIndex in removed where old[oldIndex].kind == .thinking {
            let slot = oldIndex - removed.filter { $0 < oldIndex }.count
            guard let newIndex = inserted.first(where: { index in
                guard case .workerReply = new[index].kind, new[index].authorWorkerID == old[oldIndex].authorWorkerID
                else { return false }
                return index - inserted.filter { $0 < index }.count == slot
            }) else { continue }
            removed.removeAll { $0 == oldIndex }
            inserted.removeAll { $0 == newIndex }
            replaced.append(newIndex)
        }
        return replaced.sorted()
    }
}
