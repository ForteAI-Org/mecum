//
//  LayoutMeasurementCache.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import CoreGraphics

/// LayoutMeasurementCache keeps the measured text size of a row by content
/// version, width and style (§12.2).
///
/// The content version is the prepared text itself, characters and runs, so
/// an unchanged row is never measured twice and a changed one, even by one
/// character of its time, can never reuse its old size. Width is the width
/// the text may take, in whole points rounded down, so the drawn width is never
/// narrower than the measured one and a resize that settles back hits again.
///
/// A value type. `TranscriptController` owns the one it reads, on the main
/// actor; a preparation pass off the main thread works on a copy and hands
/// back what it measured, so no instance is ever shared between threads.
public struct LayoutMeasurementCache: Sendable {

    public struct Key: Sendable, Hashable {
        public let content: PreparedText
        public let width  : Int
        public let style  : TranscriptStyle

        public init(content: PreparedText, width: CGFloat, style: TranscriptStyle) {
            self.content = content
            self.width   = Int(width.rounded(.down))
            self.style   = style
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
