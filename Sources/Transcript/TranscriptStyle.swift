//
//  TranscriptStyle.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import CoreGraphics

/// TranscriptStyle is everything besides content and width that changes how
/// tall a row is. It is part of every `LayoutMeasurementCache` key, so a
/// larger text size (§3.3) measures again instead of reusing a stale height.
public struct TranscriptStyle: Sendable, Hashable {

    /// The conversation body, in points. The spec's floor is 14.
    public var bodyPointSize: CGFloat

    public init(bodyPointSize: CGFloat = 14) {
        self.bodyPointSize = max(10, bodyPointSize)
    }

    /// Names, times and delivery states.
    public var captionPointSize: CGFloat { max(10, bodyPointSize - 3) }

    /// Tool lines and failure reasons.
    public var monospacedPointSize: CGFloat { max(10, bodyPointSize - 2) }

    /// The height of one caption line, rounded up to whole points.
    public var captionLineHeight: CGFloat { (captionPointSize * 1.35).rounded(.up) }

    /// A bubble for a short reply stays this narrow however wide the window.
    public var shortMeasure: CGFloat { (bodyPointSize * 34).rounded() }

    /// A long text gets a wider surface, still a readable line (about 75 characters).
    public var longMeasure: CGFloat { (bodyPointSize * 48).rounded() }
}
