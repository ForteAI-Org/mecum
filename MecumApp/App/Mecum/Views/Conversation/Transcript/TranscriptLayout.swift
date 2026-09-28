//
//  TranscriptLayout.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit

/// TranscriptLayout stacks rows of known height from top to bottom (§12.1).
///
/// It measures nothing: `TranscriptController` hands it the heights the
/// preparation pass computed before any cell exists, so `prepare()` is one
/// linear pass of additions. A history shorter than the viewport sits at its
/// bottom, the way a conversation reads, without flipping the view.
@MainActor
final class TranscriptLayout: NSCollectionViewLayout {

    static let groupSpacing   : CGFloat = 4
    static let ordinarySpacing: CGFloat = 12
    static let verticalInset  : CGFloat = 16

    /// One entry per row, in row order. Set together, then invalidate.
    /// `continuesGroup` is whether a row sits close under the one above.
    var heights       : [CGFloat] = []
    var continuesGroup: [Bool]    = []

    /// Room above the first row and below the last that a floating header
    /// and composer cover, in points.
    var topInset   : CGFloat = 0
    var bottomInset: CGFloat = 0

    private(set) var frames: [CGRect] = []
    private var contentSize = NSSize.zero

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let width    = collectionView.enclosingScrollView?.contentView.bounds.width ?? collectionView.bounds.width
        let viewport = collectionView.enclosingScrollView?.contentView.bounds.height ?? 0

        var y = Self.verticalInset + topInset
        var placed: [CGRect] = []
        placed.reserveCapacity(heights.count)
        for (index, height) in heights.enumerated() {
            if index > 0 {
                y += continuesGroup.indices.contains(index) && continuesGroup[index]
                    ? Self.groupSpacing : Self.ordinarySpacing
            }
            placed.append(CGRect(x: 0, y: y, width: width, height: height))
            y += height
        }
        let total = y + Self.verticalInset + bottomInset
        let lift  = max(0, viewport - total)
        frames      = lift > 0 ? placed.map { $0.offsetBy(dx: 0, dy: lift) } : placed
        contentSize = NSSize(width: width, height: max(total, viewport))
    }

    override var collectionViewContentSize: NSSize { contentSize }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        // Frames ascend in y, so the first row that reaches the rect is found by bisection.
        var low = 0, high = frames.count
        while low < high {
            let middle = (low + high) / 2
            if frames[middle].maxY < rect.minY { low = middle + 1 } else { high = middle }
        }
        var result: [NSCollectionViewLayoutAttributes] = []
        var index = low
        while index < frames.count, frames[index].minY <= rect.maxY {
            result.append(attributes(at: index))
            index += 1
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        frames.indices.contains(indexPath.item) ? attributes(at: indexPath.item) : nil
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != contentSize.width
    }

    private func attributes(at index: Int) -> NSCollectionViewLayoutAttributes {
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: index, section: 0))
        attributes.frame = frames[index]
        return attributes
    }
}
