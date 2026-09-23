//
//  ScrollAnchor.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import CoreGraphics

/// ScrollAnchor is what the reader is looking at, as a row and the distance
/// from that row's top to the viewport's top, in flipped points.
///
/// It is captured before an update and resolved after it, so rows loaded or
/// resized above the viewport move the content and not what is being read.
/// The same pair, restricted to messages, is the reading position a
/// conversation persists (`readingAnchorMessageID`, `readingOffset`).
public struct ScrollAnchor: Sendable, Equatable {

    public let itemID: TranscriptItem.ID
    public let offset: CGFloat

    public init(itemID: TranscriptItem.ID, offset: CGFloat) {
        self.itemID = itemID
        self.offset = offset
    }

    /// The first row, among those `isEligible` accepts, whose bottom is below
    /// `visibleTop`. `frames` are in row order.
    public static func capture(
        frames    : [(id: TranscriptItem.ID, frame: CGRect)],
        visibleTop: CGFloat,
        isEligible: (TranscriptItem.ID) -> Bool = { _ in true }
    ) -> ScrollAnchor? {
        guard let found = frames.first(where: { isEligible($0.id) && $0.frame.maxY > visibleTop }) else {
            return nil
        }
        return ScrollAnchor(itemID: found.id, offset: visibleTop - found.frame.minY)
    }

    /// The viewport top that puts the row back where it was, or nil when the
    /// row is gone. An offset deeper than the row now is, after a reflow,
    /// stops at the row's end.
    public func visibleTop(in frames: [TranscriptItem.ID: CGRect]) -> CGFloat? {
        guard let frame = frames[itemID] else { return nil }
        return frame.minY + min(offset, frame.height)
    }
}
