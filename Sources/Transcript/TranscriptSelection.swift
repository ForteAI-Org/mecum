//
//  TranscriptSelection.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation

/// TranscriptSelection is the reader's text selection in logical coordinates
/// (§12.5): where it was started and where it now reaches, each a row id and
/// a character offset in that row's `PreparedText.string`, in UTF-16 units.
///
/// It names no view and no index, so a drag across rows the recycler has
/// reused, or a row that scrolls away and comes back, keeps the same
/// selection. The rows it is resolved against decide which end comes first.
///
/// A selection over several rows takes only their messages: a tool run, an
/// execution boundary or a notice between them is neither highlighted nor
/// copied. A selection inside one row takes that row, whatever its kind.
///
/// A value, owned by `TranscriptController` on the main actor.
public struct TranscriptSelection: Sendable, Equatable {

    public struct Point: Sendable, Hashable {
        public let itemID: TranscriptItem.ID
        public let offset: Int

        public init(itemID: TranscriptItem.ID, offset: Int) {
            self.itemID = itemID
            self.offset = offset
        }
    }

    /// Where the selection started. Extending moves `focus` and keeps this.
    public var anchor: Point
    public var focus : Point

    public init(anchor: Point, focus: Point) {
        self.anchor = anchor
        self.focus  = focus
    }

    /// The whole text of `row`, from its start to its end.
    public init(wholeOf row: PreparedRow) {
        anchor = Point(itemID: row.item.id, offset: 0)
        focus  = Point(itemID: row.item.id, offset: row.length)
    }

    public var isEmpty: Bool { anchor == focus }

    /// The selection's ends in row order, resolved against `rows`.
    public struct Span: Sendable {
        public let lower    : (row: Int, offset: Int)
        public let upper    : (row: Int, offset: Int)
        public let isForward: Bool

        /// The part of the row at `index` inside the span, or nil when none
        /// is: the row is outside it, or it is not a message and the span
        /// covers more than one row.
        public func range(ofRow index: Int, in rows: [PreparedRow]) -> NSRange? {
            guard index >= lower.row, index <= upper.row, rows.indices.contains(index) else { return nil }
            guard lower.row == upper.row || rows[index].item.messageID != nil else { return nil }
            let length = rows[index].length
            let start  = index == lower.row ? min(lower.offset, length) : 0
            let end    = index == upper.row ? min(upper.offset, length) : length
            return NSRange(location: start, length: max(0, end - start))
        }

        /// The selected text in reading order, rows apart by a blank line. A
        /// row taken whole gives its source, as its author wrote it; a row
        /// taken in part gives the characters selected in it.
        public func text(in rows: [PreparedRow]) -> String {
            var parts: [String] = []
            for index in lower.row...upper.row {
                guard let range = range(ofRow: index, in: rows), range.length > 0 else { continue }
                let row = rows[index]
                parts.append(range.length == row.length
                    ? row.item.copyText
                    : (row.text.string as NSString).substring(with: range))
            }
            return parts.joined(separator: "\n\n")
        }
    }

    /// The span in `rows`, or nil when either end's row is not among them.
    public func span(in rows: [PreparedRow]) -> Span? {
        guard let anchorRow = rows.firstIndex(where: { $0.item.id == anchor.itemID }),
              let focusRow  = rows.firstIndex(where: { $0.item.id == focus.itemID })
        else { return nil }
        let start     = (row: anchorRow, offset: anchor.offset)
        let end       = (row: focusRow, offset: focus.offset)
        let isForward = start.row < end.row || (start.row == end.row && start.offset <= end.offset)
        return Span(lower: isForward ? start : end, upper: isForward ? end : start, isForward: isForward)
    }

    /// The selection after `old` rows became `new` ones, or nil when none of
    /// the text it covered is left.
    ///
    /// An end whose row stays keeps its offset, clamped to the row's new
    /// length. An end whose row is gone moves inwards to the nearest row of
    /// the old span that stays. A selection inside one row whose text moved
    /// within it follows that text.
    public func kept(from old: [PreparedRow], in new: [PreparedRow]) -> TranscriptSelection? {
        guard let span = span(in: old) else { return nil }
        let fresh = Dictionary(new.map { ($0.item.id, $0) }, uniquingKeysWith: { first, _ in first })

        if span.lower.row == span.upper.row {
            let id = old[span.lower.row].item.id
            guard let row = fresh[id] else { return nil }
            let before   = old[span.lower.row].text.string as NSString
            let after    = row.text.string as NSString
            let range    = NSRange(location: span.lower.offset, length: span.upper.offset - span.lower.offset)
            guard range.length > 0, NSMaxRange(range) <= before.length else { return clamped(to: row) }
            let selected = before.substring(with: range)
            if NSMaxRange(range) <= after.length, after.substring(with: range) == selected { return self }
            let moved = after.range(of: selected)
            guard moved.location != NSNotFound else { return nil }
            return oriented(Point(itemID: id, offset: moved.location),
                            Point(itemID: id, offset: NSMaxRange(moved)), forward: span.isForward)
        }

        let covered = old[span.lower.row...span.upper.row]
        guard let first = covered.first(where: { fresh[$0.item.id] != nil }),
              let last  = covered.last(where: { fresh[$0.item.id] != nil }),
              let firstRow = fresh[first.item.id], let lastRow = fresh[last.item.id]
        else { return nil }
        let lower = first.item.id == old[span.lower.row].item.id
            ? Point(itemID: first.item.id, offset: min(span.lower.offset, firstRow.length))
            : Point(itemID: first.item.id, offset: 0)
        let upper = last.item.id == old[span.upper.row].item.id
            ? Point(itemID: last.item.id, offset: min(span.upper.offset, lastRow.length))
            : Point(itemID: last.item.id, offset: lastRow.length)
        return oriented(lower, upper, forward: span.isForward)
    }

    private func clamped(to row: PreparedRow) -> TranscriptSelection {
        TranscriptSelection(anchor: Point(itemID: anchor.itemID, offset: min(anchor.offset, row.length)),
                            focus : Point(itemID: focus.itemID, offset: min(focus.offset, row.length)))
    }

    private func oriented(_ lower: Point, _ upper: Point, forward: Bool) -> TranscriptSelection {
        forward ? TranscriptSelection(anchor: lower, focus: upper) : TranscriptSelection(anchor: upper, focus: lower)
    }
}

extension PreparedRow {

    /// The length of the row's text, in the UTF-16 units a selection counts.
    var length: Int { (text.string as NSString).length }
}
