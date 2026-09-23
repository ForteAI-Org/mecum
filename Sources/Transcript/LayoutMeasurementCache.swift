//
//  LayoutMeasurementCache.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import CoreGraphics

/// LayoutMeasurementCache keeps the measured text size of each block by
/// content version, width and style (§12.2, §12.3).
///
/// The content version is the prepared block itself, kind, characters and
/// runs, so an unchanged block is never measured twice, a message that grows
/// measures only the block that changed, and a changed block, even by one
/// character, can never reuse its old size. The block's identity is left out:
/// two equal blocks share one size. Width is the width the text may take, in
/// whole points rounded down, so the drawn width is never narrower than the
/// measured one and a resize that settles back hits again.
///
/// A value type. `TranscriptController` owns the one it reads, on the main
/// actor; a preparation pass off the main thread works on a copy and hands
/// back what it measured, so no instance is ever shared between threads.
public struct LayoutMeasurementCache: Sendable {

    public struct Key: Sendable, Hashable {
        public let kind  : PreparedBlock.Kind
        public let string: String
        public let runs  : [PreparedText.Run]
        public let width : Int
        public let style : TranscriptStyle

        public init(content: PreparedBlock, width: CGFloat, style: TranscriptStyle) {
            self.kind   = content.kind
            self.string = content.string
            self.runs   = content.runs
            self.width  = Int(width.rounded(.down))
            self.style  = style
        }
    }

    /// Entries beyond this empty the cache, which then refills from the rows
    /// on screen. ponytail: all-or-nothing eviction, least recently used if a
    /// profile ever shows the refill.
    public static let capacity = 4096

    private var sizes: [Key: CGSize] = [:]

    public init() {}

    public var count: Int { sizes.count }

    public func size(for key: Key) -> CGSize? { sizes[key] }

    public mutating func store(_ size: CGSize, for key: Key) {
        if sizes.count >= Self.capacity { sizes.removeAll(keepingCapacity: true) }
        sizes[key] = size
    }

    /// Adds every entry of `other`, which a preparation pass measured.
    public mutating func merge(_ other: [Key: CGSize]) {
        for (key, size) in other { store(size, for: key) }
    }
}
