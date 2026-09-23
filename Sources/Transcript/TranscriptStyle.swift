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

    /// Code and tables may take this much, wider than prose (§11.1).
    public var wideMeasure: CGFloat { (bodyPointSize * 72).rounded() }

    /// Code, inline or in a block.
    public var codePointSize: CGFloat { max(10, bodyPointSize - 1) }

    /// One level of list nesting.
    public var indentStep: CGFloat { (bodyPointSize * 1.6).rounded() }

    /// A Markdown heading's size: three steps above the body, then the body's.
    public func headingPointSize(level: Int) -> CGFloat {
        switch level {
        case 1:  (bodyPointSize * 1.45).rounded()
        case 2:  (bodyPointSize * 1.25).rounded()
        case 3:  (bodyPointSize * 1.1).rounded()
        default: bodyPointSize
        }
    }

    // MARK: Text size

    /// The body sizes View > Bigger and Smaller step through. The first is
    /// Actual Size and the spec's floor (§3.3), so Smaller only undoes Bigger.
    public static let bodyPointSizes: [CGFloat] = [14, 15, 16, 18, 20, 22, 24]

    /// The style at Actual Size.
    public static let actualSize = TranscriptStyle(bodyPointSize: 14)

    /// The next size up, or nil at the largest. A size between two steps,
    /// such as one remembered from another build, moves to the step above it.
    public var bigger: TranscriptStyle? {
        Self.bodyPointSizes.first { $0 > bodyPointSize }.map(TranscriptStyle.init(bodyPointSize:))
    }

    /// The next size down, or nil at Actual Size.
    public var smaller: TranscriptStyle? {
        Self.bodyPointSizes.last { $0 < bodyPointSize }.map(TranscriptStyle.init(bodyPointSize:))
    }
}
