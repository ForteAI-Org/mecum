//
//  RowGeometry.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import CoreGraphics

/// RowGeometry places the parts of one row inside its frame, in flipped
/// coordinates (y grows downwards), from the row's kind, width, style and the
/// measured size of its text.
///
/// Measuring and drawing both go through this type, so the height a row was
/// measured at is the height it draws at: the only text-dependent input is
/// `textSize`, which the measurer computes once, off the main thread.
public struct RowGeometry: Sendable, Hashable {

    public static let gutter      : CGFloat = 16
    public static let avatarSide  : CGFloat = 28
    public static let avatarGap   : CGFloat = 8
    static let bubblePadding      = CGSize(width: 12, height: 8)
    static let cardPadding        = CGSize(width: 12, height: 8)

    public let height    : CGFloat
    public let header    : CGRect?
    public let avatar    : CGRect?
    public let surface   : CGRect
    public let text      : CGRect

    /// Where the delivery badge sits, beside the bubble, when the row has one.
    public let badge     : CGRect?

    /// The widest the text may be laid out at, before it is measured.
    public static func textWidthLimit(
        for kind: TranscriptItem.Kind,
        rowWidth: CGFloat,
        style   : TranscriptStyle
    ) -> CGFloat {
        let padding = shape(of: kind) == .bubble ? bubblePadding.width : cardPadding.width
        return max(40, surfaceLimit(for: kind, rowWidth: rowWidth, style: style) - 2 * padding)
    }

    public init(
        item    : TranscriptItem,
        rowWidth: CGFloat,
        style   : TranscriptStyle,
        textSize: CGSize
    ) {
        let caption = style.captionLineHeight
        let limit   = Self.surfaceLimit(for: item.kind, rowWidth: rowWidth, style: style)
        let isPerson: Bool
        if case .personMessage = item.kind { isPerson = true } else { isPerson = false }

        switch Self.shape(of: item.kind) {
        case .bubble:
            let hasHeader = !item.continuesGroup
            let top       = hasHeader ? caption + 2 : 0
            let long      = Self.isLong(item.kind)
            let width     = long ? limit : min(limit, textSize.width + 2 * Self.bubblePadding.width)
            let bubbleX   = isPerson
                ? rowWidth - Self.gutter - width
                : Self.gutter + Self.avatarSide + Self.avatarGap
            let surface   = CGRect(x: bubbleX, y: top, width: width,
                                   height: textSize.height + 2 * Self.bubblePadding.height)
            let hasBadge  = DeliveryBadge(item.kind) != nil

            self.surface = surface
            self.text    = surface.insetBy(dx: Self.bubblePadding.width, dy: Self.bubblePadding.height)
            self.header  = hasHeader ? CGRect(x: bubbleX, y: 0, width: width, height: caption) : nil
            self.avatar  = hasHeader && !isPerson
                ? CGRect(x: Self.gutter, y: top, width: Self.avatarSide, height: Self.avatarSide)
                : nil
            self.badge   = hasBadge
                ? CGRect(x: bubbleX - 6 - caption, y: surface.maxY - caption - 6, width: caption, height: caption)
                : nil
            self.height  = max(surface.maxY, self.avatar?.maxY ?? 0).rounded(.up)

        case .card:
            let x       = Self.gutter + Self.avatarSide + Self.avatarGap
            let surface = CGRect(x: x, y: 0, width: limit,
                                 height: textSize.height + 2 * Self.cardPadding.height)
            self.surface = surface
            self.text    = surface.insetBy(dx: Self.cardPadding.width, dy: Self.cardPadding.height)
            self.header  = nil
            self.avatar  = nil
            self.badge   = nil
            self.height  = surface.maxY.rounded(.up)

        case .divider:
            let surface = CGRect(x: Self.gutter, y: 0, width: max(0, rowWidth - 2 * Self.gutter),
                                 height: max(caption, textSize.height) + 8)
            let textWidth = min(surface.width, textSize.width)
            self.surface = surface
            self.text    = CGRect(x: surface.midX - textWidth / 2, y: 4, width: textWidth,
                                  height: textSize.height)
            self.header  = nil
            self.avatar  = nil
            self.badge   = nil
            self.height  = surface.maxY.rounded(.up)
        }
    }

    // MARK: Shape

    enum Shape { case bubble, card, divider }

    static func shape(of kind: TranscriptItem.Kind) -> Shape {
        switch kind {
        case .personMessage, .workerReply:                   .bubble
        case .toolRun, .executionFailed, .executionInterrupted: .card
        case .executionStarted, .executionCompleted, .activityNotShown: .divider
        }
    }

    /// A text past a few lines or with paragraphs takes the wider surface.
    static func isLong(_ kind: TranscriptItem.Kind) -> Bool {
        switch kind {
        case .personMessage(let text, _, _), .workerReply(let text, _):
            text.count > 280 || text.contains("\n\n")
        default:
            false
        }
    }

    /// The surface's widest, from the row's width and a readable measure.
    private static func surfaceLimit(
        for kind: TranscriptItem.Kind,
        rowWidth: CGFloat,
        style   : TranscriptStyle
    ) -> CGFloat {
        let indent  = gutter + avatarSide + avatarGap
        let measure = isLong(kind) || shape(of: kind) == .card ? style.longMeasure : style.shortMeasure
        switch kind {
        case .personMessage:
            // The person's bubble leaves room on the left, so it never spans the row.
            return max(60, min(measure, (rowWidth - 2 * gutter) * 0.8))
        case .executionStarted, .executionCompleted, .activityNotShown:
            return max(60, rowWidth - 2 * gutter)
        default:
            return max(60, min(measure, rowWidth - indent - gutter))
        }
    }
}
