//
//  RowGeometry.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit

/// RowGeometry places the parts of one row inside its frame, in flipped
/// coordinates (y grows downwards), from the row's kind, width, style and the
/// measured size of each of its blocks.
///
/// Measuring and drawing both go through this type, so the height a row was
/// measured at is the height it draws at: the only text-dependent input is
/// the blocks' sizes, which the measurer computes once, off the main thread.
///
/// Prose keeps a readable measure. A code block or a table may be laid out
/// wider, up to `TranscriptStyle.wideMeasure`, and the bubble then grows to
/// hold it while the prose inside keeps its own measure (§11.1).
public struct RowGeometry: Sendable, Hashable {

    public static let gutter      : CGFloat = 16
    public static let avatarSide  : CGFloat = 28
    public static let avatarGap   : CGFloat = 8
    static let bubblePadding      = CGSize(width: 12, height: 8)
    static let cardPadding        = CGSize(width: 12, height: 8)
    static let blockSpacing       : CGFloat = 8
    static let ruleHeight         : CGFloat = 9

    public let height    : CGFloat
    public let header    : CGRect?
    public let avatar    : CGRect?
    public let surface   : CGRect
    public let text      : CGRect

    /// Each block's frame, which a finished code block fills with its own surface.
    public let blocks    : [CGRect]

    /// Where each block's text is laid out: its origin, the width it was
    /// measured at and its measured height.
    public let blockTexts: [CGRect]

    /// Where the delivery badge sits, beside the bubble, when the row has one.
    public let badge     : CGRect?

    /// The widest a row's prose may be laid out at, before it is measured.
    public static func textWidthLimit(
        for kind: TranscriptItem.Kind,
        rowWidth: CGFloat,
        style   : TranscriptStyle
    ) -> CGFloat {
        let padding = shape(of: kind) == .bubble ? bubblePadding.width : cardPadding.width
        return max(40, surfaceLimit(for: kind, rowWidth: rowWidth, style: style, isWide: false) - 2 * padding)
    }

    /// The width `block`'s text is laid out and measured at, in whole points.
    public static func textWidthLimit(
        for block: PreparedBlock.Kind,
        in kind  : TranscriptItem.Kind,
        rowWidth : CGFloat,
        style    : TranscriptStyle
    ) -> CGFloat {
        let column: CGFloat
        if isWide(block) {
            let padding = shape(of: kind) == .bubble ? bubblePadding.width : cardPadding.width
            column = surfaceLimit(for: kind, rowWidth: rowWidth, style: style, isWide: true) - 2 * padding
        } else {
            column = textWidthLimit(for: kind, rowWidth: rowWidth, style: style)
        }
        let insets = blockInsets(block, style: style)
        return max(40, column - insets.left - insets.right).rounded(.down)
    }

    /// The Copy block control, in a finished code block's top strip.
    public static func copyControl(in block: CGRect, style: TranscriptStyle) -> CGRect {
        let size = CGSize(width: (style.captionPointSize * 3).rounded(.up), height: style.captionLineHeight)
        return CGRect(x: block.maxX - 8 - size.width, y: block.minY + 3, width: size.width, height: size.height)
    }

    public init(
        item    : TranscriptItem,
        rowWidth: CGFloat,
        style   : TranscriptStyle,
        blocks  : [PreparedBlock.Kind],
        sizes   : [CGSize]
    ) {
        // Blocks stack from the text's origin; the row is placed around their total size.
        var local: [CGRect] = []
        var stackWidth: CGFloat = 0, stackHeight: CGFloat = 0
        for (index, (kind, size)) in zip(blocks, sizes).enumerated() {
            if index > 0 { stackHeight += Self.spacing(after: blocks[index - 1], before: kind) }
            let insets = Self.blockInsets(kind, style: style)
            let height = kind == .rule ? Self.ruleHeight : size.height + insets.top + insets.bottom
            let frame  = CGRect(x: 0, y: stackHeight, width: size.width + insets.left + insets.right,
                                height: height)
            local.append(frame)
            stackWidth  = max(stackWidth, frame.width)
            stackHeight = frame.maxY
        }
        let textSize = CGSize(width: stackWidth, height: stackHeight)
        let isWide   = blocks.contains(where: Self.isWide)

        let caption = style.captionLineHeight
        let limit   = Self.surfaceLimit(for: item.kind, rowWidth: rowWidth, style: style, isWide: isWide)
        let isPerson: Bool
        if case .personMessage = item.kind { isPerson = true } else { isPerson = false }

        switch Self.shape(of: item.kind) {
        case .bubble:
            let hasHeader = !item.continuesGroup
            let top       = hasHeader ? caption + 2 : 0
            let long      = Self.isLong(item.kind) && !isWide
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

        // Code, tables and rules span the text column; the rest keep their measured width.
        let origin = self.text.origin
        var frames: [CGRect] = [], texts: [CGRect] = []
        for (index, kind) in blocks.enumerated() {
            var frame = local[index].offsetBy(dx: origin.x, dy: origin.y)
            if Self.spansColumn(kind) { frame.size.width = max(frame.width, self.text.width) }
            let insets = Self.blockInsets(kind, style: style)
            let width  = Self.textWidthLimit(for: kind, in: item.kind, rowWidth: rowWidth, style: style)
            frames.append(frame)
            texts.append(CGRect(x: frame.minX + insets.left, y: frame.minY + insets.top, width: width,
                                height: sizes[index].height))
        }
        self.blocks     = frames
        self.blockTexts = texts
    }

    // MARK: Blocks

    static func isWide(_ block: PreparedBlock.Kind) -> Bool {
        switch block {
        case .code, .table: true
        default:            false
        }
    }

    private static func spansColumn(_ block: PreparedBlock.Kind) -> Bool {
        switch block {
        case .code(_, true), .table, .rule: true
        default:                            false
        }
    }

    /// Room inside a block around its text: a finished code block's surface
    /// with the strip that holds Copy, and a quote's bar.
    static func blockInsets(_ block: PreparedBlock.Kind, style: TranscriptStyle) -> NSEdgeInsets {
        switch block {
        case .code(_, true): NSEdgeInsets(top: style.captionLineHeight + 6, left: 10, bottom: 8, right: 10)
        case .quote:         NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 0)
        default:             NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        }
    }

    /// An open fence's provisional lines read as one run; a heading gets more room above.
    private static func spacing(after previous: PreparedBlock.Kind, before next: PreparedBlock.Kind) -> CGFloat {
        switch (previous, next) {
        case (.code(_, false), .code(_, false)): 0
        case (_, .heading):                      blockSpacing + 4
        default:                                 blockSpacing
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

    /// The surface's widest, from the row's width and a readable measure, or
    /// the wide measure when the row holds code or a table.
    private static func surfaceLimit(
        for kind: TranscriptItem.Kind,
        rowWidth: CGFloat,
        style   : TranscriptStyle,
        isWide  : Bool
    ) -> CGFloat {
        let indent  = gutter + avatarSide + avatarGap
        let measure = isWide ? style.wideMeasure
            : isLong(kind) || shape(of: kind) == .card ? style.longMeasure : style.shortMeasure
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
