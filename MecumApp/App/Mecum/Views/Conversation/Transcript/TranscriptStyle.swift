//
//  TranscriptStyle.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import CoreGraphics

/// TranscriptStyle is everything besides content and width that changes how
/// tall a row is. It is part of every `LayoutMeasurementCache` key, so a
/// larger text size (§3.3) measures again instead of reusing a stale height.
nonisolated struct TranscriptStyle: Sendable, Hashable {

    /// The conversation body, in points. The spec's floor is 14.
    var bodyPointSize: CGFloat

    /// Whether the worker's replies carry its name and mascot. A direct
    /// conversation has one other side, which the title bar already names, so it shows neither.
    var showsAuthors: Bool

    /// The family of the conversation's text, nil for the system font. Code stays monospaced.
    var fontFamily: String?

    /// Whether the time is written under the last message of a group. A delivery badge is shown either way.
    var showsTimes: Bool

    /// Whether a turn's tool steps open by default; toggling one opens or closes it against this.
    var opensToolSteps: Bool

    init(
        bodyPointSize : CGFloat = 14,
        showsAuthors  : Bool    = false,
        fontFamily    : String? = nil,
        showsTimes    : Bool    = true,
        opensToolSteps: Bool    = false
    ) {
        self.bodyPointSize  = max(10, bodyPointSize)
        self.showsAuthors   = showsAuthors
        self.fontFamily     = fontFamily.flatMap { $0.isEmpty ? nil : $0 }
        self.showsTimes     = showsTimes
        self.opensToolSteps = opensToolSteps
    }

    /// The conversation's text face at `size` and `weight`: the chosen family when it is
    /// installed, else the system font. Built through a descriptor, which is safe off the main
    /// thread, where rows are measured.
    func textFont(
        ofSize size: CGFloat,
        weight     : NSFont.Weight = .regular
    ) -> NSFont {
        guard let fontFamily else {
            return .systemFont(
                ofSize: size,
                weight: weight
            )
        }

        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: fontFamily,
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
        ])
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    /// Names, times and delivery states.
    var captionPointSize: CGFloat { max(10, bodyPointSize - 3) }

    /// Tool lines and their steps, a step below the caption: quieter than the replies they open.
    var toolPointSize: CGFloat { captionPointSize - 1 }

    /// Failure reasons.
    var monospacedPointSize: CGFloat { max(10, bodyPointSize - 2) }

    /// A reply's quote of the message it answers, inside its bubble: a step below the body.
    var quotePointSize: CGFloat { max(10, bodyPointSize - 2) }

    /// The height of one caption line, rounded up to whole points.
    var captionLineHeight: CGFloat { (captionPointSize * 1.35).rounded(.up) }

    /// A bubble for a short reply stays this narrow however wide the window.
    var shortMeasure: CGFloat { (bodyPointSize * 34).rounded() }

    /// A long text gets a wider surface, still a readable line (about 75 characters).
    var longMeasure: CGFloat { (bodyPointSize * 48).rounded() }

    /// Code and tables may take this much, wider than prose (§11.1).
    var wideMeasure: CGFloat { (bodyPointSize * 72).rounded() }

    /// Code, inline or in a block.
    var codePointSize: CGFloat { max(10, bodyPointSize - 1) }

    /// One level of list nesting.
    var indentStep: CGFloat { (bodyPointSize * 1.6).rounded() }

    /// A Markdown heading's size: three steps above the body, then the body's.
    func headingPointSize(level: Int) -> CGFloat {
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
    static let bodyPointSizes: [CGFloat] = [14, 15, 16, 18, 20, 22, 24]

    /// The style at Actual Size.
    static let actualSize = TranscriptStyle(bodyPointSize: 14)

    /// The next size up, or nil at the largest. A size between two steps,
    /// such as one remembered from another build, moves to the step above it.
    var bigger: TranscriptStyle? {
        Self.bodyPointSizes.first { $0 > bodyPointSize }.map { TranscriptStyle(bodyPointSize: $0) }
    }

    /// The next size down, or nil at Actual Size.
    var smaller: TranscriptStyle? {
        Self.bodyPointSizes.last { $0 < bodyPointSize }.map { TranscriptStyle(bodyPointSize: $0) }
    }
}
