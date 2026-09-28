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
nonisolated struct RowGeometry: Sendable, Hashable {

    static let gutter      : CGFloat = 16
    static let avatarSide  : CGFloat = 28
    static let avatarGap   : CGFloat = 8
    static let bubblePadding      = CGSize(width: 12, height: 8)
    static let cardPadding        = CGSize(width: 12, height: 8)
    /// A tool line's card of steps, a little roomier than a failure's card so its lines breathe.
    static let toolCardPadding    = CGSize(width: 14, height: 10)
    static let blockSpacing       : CGFloat = 8
    static let ruleHeight         : CGFloat = 9

    /// The row width the parts were placed at; a live resize draws before they are placed again.
    let rowWidth  : CGFloat
    let height    : CGFloat
    /// The worker's name above the first bubble of its group; the person's bubbles have none.
    let header    : CGRect?

    /// The line under a bubble that holds its send time, under the last bubble
    /// of a group, and its delivery badge, under any bubble that has one.
    let footer    : CGRect?
    let avatar    : CGRect?
    let surface   : CGRect
    let text      : CGRect

    /// Each block's frame, which a finished code block fills with its own surface.
    let blocks    : [CGRect]

    /// Where each block's text is laid out: its origin, the width it was
    /// measured at and its measured height.
    let blockTexts: [CGRect]

    /// Where the delivery badge sits, on the footer line at the bubble's inner
    /// corner with the time beside it, when the row has one.
    let badge     : CGRect?

    /// The tail of the last bubble of a group, outside the surface at its
    /// bottom corner on the author's side, or nil. It lies within the gutter,
    /// clear of the mascot, and moves no text; the bubble is surface and tail.
    let tail      : CGRect?

    /// A bubble's quote of the message it replies to, at its top inside it:
    /// the inset block, the name line in it when the quoted message is the
    /// worker's, and where the excerpt is laid out. Nil on every other row.
    let quote    : CGRect?
    let quoteName: CGRect?
    let quoteText: CGRect?

    static let tailSize = CGSize(width: 6, height: 11)

    /// What a bubble's quote measured, before it is placed.
    struct QuoteSize: Sendable, Hashable {

        /// The excerpt's size, at most `quoteLines` lines, and the width it was laid out at.
        let text : CGSize
        let width: CGFloat

        /// The name line's width, nil when the quote has none.
        let name: CGFloat?
    }

    /// Room from the bubble's edge to its quote's block, on every side.
    static let quoteInset: CGFloat = 6

    /// The block's leading bar, which says who wrote the quoted message by its colour.
    static let quoteBar: CGFloat = 3

    /// Room inside the block around its name and excerpt, past the bar on the leading side.
    static let quotePadding = NSEdgeInsets(
        top   : 5,
        left  : quoteBar + 8,
        bottom: 5,
        right : 8
    )

    static let quoteLines         = 2
    static let quoteCornerRadius: CGFloat = 8

    static let toolShadowRoom: CGFloat = 4

    /// How far the footer's time and badge sit in from the bubble's edge, clear of its rounded corner.
    static let footerInset: CGFloat = 8

    /// Where the worker's bubbles and its tool lines start: past the mascot's
    /// column when replies show their author, at the gutter when they do not.
    static func leading(_ style: TranscriptStyle) -> CGFloat {
        style.showsAuthors ? gutter + avatarSide + avatarGap : gutter
    }

    /// The widest a row's prose may be laid out at, before it is measured.
    static func textWidthLimit(
        for kind: TranscriptItem.Kind,
        rowWidth: CGFloat,
        style   : TranscriptStyle
    ) -> CGFloat {
        max(40, surfaceLimit(for: kind, rowWidth: rowWidth, style: style, isWide: false) - 2 * padding(of: kind))
    }

    /// The room between a surface's edge and its text, on each side.
    private static func padding(of kind: TranscriptItem.Kind) -> CGFloat {
        switch shape(of: kind) {
        case .bubble:          bubblePadding.width
        case .line:            0
        case .card, .divider:  cardPadding.width
        }
    }

    /// The three dots of a thinking bubble take the place of one body line.
    static func thinkingSize(_ style: TranscriptStyle) -> CGSize {
        let dot = (style.bodyPointSize * 0.5).rounded()
        return CGSize(width: 3 * dot + 2 * (dot * 0.7).rounded(), height: (style.bodyPointSize * 1.2).rounded(.up))
    }

    /// The width `block`'s text is laid out and measured at, in whole points.
    static func textWidthLimit(
        for block: PreparedBlock.Kind,
        in kind  : TranscriptItem.Kind,
        rowWidth : CGFloat,
        style    : TranscriptStyle
    ) -> CGFloat {
        let column: CGFloat
        if isWide(block) {
            column = surfaceLimit(for: kind, rowWidth: rowWidth, style: style, isWide: true) - 2 * padding(of: kind)
        } else {
            column = textWidthLimit(for: kind, rowWidth: rowWidth, style: style)
        }
        let insets = blockInsets(block, style: style)
        return max(40, column - insets.left - insets.right).rounded(.down)
    }

    /// The widest a quote's excerpt and name may be laid out at: inside its
    /// block, when the bubble takes its widest short measure.
    static func quoteWidthLimit(
        for kind: TranscriptItem.Kind,
        rowWidth: CGFloat,
        style   : TranscriptStyle
    ) -> CGFloat {
        let block = surfaceLimit(
            for     : kind,
            rowWidth: rowWidth,
            style   : style,
            isWide  : false
        ) - 2 * quoteInset
        return max(40, block - quotePadding.left - quotePadding.right).rounded(.down)
    }

    /// The Copy block control, in a finished code block's top strip.
    static func copyControl(in block: CGRect, style: TranscriptStyle) -> CGRect {
        let size = CGSize(width: style.captionLineHeight, height: style.captionLineHeight)
        return CGRect(x: block.maxX - 8 - size.width, y: block.minY + 3, width: size.width, height: size.height)
    }

    init(
        item    : TranscriptItem,
        rowWidth: CGFloat,
        style   : TranscriptStyle,
        blocks  : [PreparedBlock.Kind],
        sizes   : [CGSize],
        quote   : QuoteSize? = nil
    ) {
        self.rowWidth = rowWidth
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
        let textSize = item.kind == .thinking
            ? Self.thinkingSize(style)
            : CGSize(width: stackWidth, height: stackHeight)
        let isWide   = blocks.contains(where: Self.isWide)

        let caption = style.captionLineHeight
        let limit   = Self.surfaceLimit(for: item.kind, rowWidth: rowWidth, style: style, isWide: isWide)
        let isPerson: Bool
        if case .personMessage = item.kind { isPerson = true } else { isPerson = false }

        // Only a bubble quotes, so the other shapes leave this nil.
        var placedQuote: (block: CGRect, name: CGRect?, text: CGRect)?

        switch Self.shape(of: item.kind) {
        case .bubble:
            let hasHeader = !item.continuesGroup
            let hasName   = hasHeader && !isPerson && style.showsAuthors
            let top       = hasName ? caption + 2 : 0
            let long      = Self.isLong(item.kind) && !isWide
            // A quote opens the bubble: its block, then the text an inset below it, and it may widen the bubble.
            let padding   = Self.quotePadding
            let measured  = quote.map { quote in
                (
                    width : max(quote.text.width, quote.name ?? 0) + padding.left + padding.right,
                    height: padding.top + (quote.name == nil ? 0 : caption + 1) + quote.text.height + padding.bottom
                )
            }
            let room      = measured.map { $0.height + 2 * Self.quoteInset - Self.bubblePadding.height } ?? 0
            let content   = max(
                textSize.width + 2 * Self.bubblePadding.width,
                (measured?.width ?? 0) + 2 * Self.quoteInset
            )
            let width     = long ? limit : min(limit, content)
            let bubbleX   = isPerson
                ? rowWidth - Self.gutter - width
                : Self.leading(style)
            let surface   = CGRect(x: bubbleX, y: top, width: width,
                                   height: textSize.height + 2 * Self.bubblePadding.height + room)
            let hasBadge  = DeliveryBadge(item.kind) != nil

            self.surface = surface
            self.text    = CGRect(
                x     : surface.minX + Self.bubblePadding.width,
                y     : surface.minY + Self.bubblePadding.height + room,
                width : surface.width - 2 * Self.bubblePadding.width,
                height: textSize.height
            )
            if let quote, let measured {
                let block = CGRect(
                    x     : surface.minX + Self.quoteInset,
                    y     : surface.minY + Self.quoteInset,
                    width : surface.width - 2 * Self.quoteInset,
                    height: measured.height
                )
                let name  = quote.name.map { _ in
                    CGRect(
                        x     : block.minX + padding.left,
                        y     : block.minY + padding.top,
                        width : max(0, block.width - padding.left - padding.right),
                        height: caption
                    )
                }
                let text  = CGRect(
                    x     : block.minX + padding.left,
                    y     : name.map { $0.maxY + 1 } ?? block.minY + padding.top,
                    width : quote.width,
                    height: quote.text.height
                )
                placedQuote = (block, name, text)
            }
            self.header  = hasName ? CGRect(x: bubbleX, y: 0, width: width, height: caption) : nil
            let footer   = (style.showsTimes && item.endsGroup && item.kind != .thinking) || hasBadge
                ? CGRect(x: bubbleX, y: surface.maxY + 2, width: width, height: caption)
                : nil
            self.footer  = footer
            self.avatar  = hasName
                ? CGRect(x: Self.gutter, y: top, width: Self.avatarSide, height: Self.avatarSide)
                : nil
            // The inner corner faces the conversation: the person's bubble's left, the worker's right.
            self.badge   = footer.flatMap { line in
                guard hasBadge else { return nil }
                let side = (caption * 0.85).rounded()
                let x    = isPerson ? line.minX + Self.footerInset : line.maxX - Self.footerInset - side
                return CGRect(x: x, y: line.midY - side / 2, width: side, height: side)
            }
            let tail     = Self.tailSize
            self.tail    = item.endsGroup
                ? CGRect(x: isPerson ? surface.maxX : surface.minX - tail.width, y: surface.maxY - tail.height,
                         width: tail.width, height: tail.height)
                : nil
            self.height  = max(footer?.maxY ?? surface.maxY, self.avatar?.maxY ?? 0).rounded(.up)

        case .card:
            // A stopped or failed turn's card spans the measure.
            let x       = Self.leading(style)
            let surface = CGRect(x: x, y: 0, width: limit,
                                 height: textSize.height + 2 * Self.cardPadding.height)
            self.surface = surface
            self.text    = surface.insetBy(dx: Self.cardPadding.width, dy: Self.cardPadding.height)
            self.header  = nil
            self.footer  = nil
            self.avatar  = nil
            self.badge   = nil
            self.tail    = nil
            self.height  = surface.maxY.rounded(.up)

        case .line:
            // No surface: a caption above the worker's answer, at its column.
            let x       = Self.leading(style)
            let surface = CGRect(x: x, y: 0, width: min(limit, textSize.width), height: textSize.height + 4)
            self.surface = surface
            self.text    = surface.insetBy(dx: 0, dy: 2)
            self.header  = nil
            self.footer  = nil
            self.avatar  = nil
            self.badge   = nil
            self.tail    = nil
            // An opened tool line's card of steps casts a shadow, which needs room below it, inside the row.
            let hasCard  = blocks.contains { if case .toolSteps = $0 { true } else { false } }
            self.height  = (surface.maxY + (hasCard ? Self.toolShadowRoom : 0)).rounded(.up)

        case .divider:
            let surface = CGRect(x: Self.gutter, y: 0, width: max(0, rowWidth - 2 * Self.gutter),
                                 height: max(caption, textSize.height) + 8)
            let textWidth = min(surface.width, textSize.width)
            self.surface = surface
            // On a whole point, so the label does not shimmer as the row is laid out again.
            self.text    = CGRect(x: (surface.midX - textWidth / 2).rounded(), y: 4, width: textWidth,
                                  height: textSize.height)
            self.header  = nil
            self.footer  = nil
            self.avatar  = nil
            self.badge   = nil
            self.tail    = nil
            self.height  = surface.maxY.rounded(.up)
        }

        self.quote     = placedQuote?.block
        self.quoteName = placedQuote?.name
        self.quoteText = placedQuote?.text

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
    /// with the strip that holds Copy, a quote's bar, the chevron after a tool
    /// line's summary, and a tool line's card of steps.
    static func blockInsets(_ block: PreparedBlock.Kind, style: TranscriptStyle) -> NSEdgeInsets {
        switch block {
        case .code(_, true): NSEdgeInsets(top: style.captionLineHeight + 6, left: 10, bottom: 8, right: 10)
        case .quote:         NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 0)
        case .toolSummary:   NSEdgeInsets(top: 0, left: 0, bottom: 0, right: disclosureSide(style) + 4)
        case .toolSteps:     NSEdgeInsets(top: toolCardPadding.height, left: toolCardPadding.width,
                                          bottom: toolCardPadding.height, right: toolCardPadding.width)
        default:             NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        }
    }

    /// The side of a tool line's chevron, drawn at the end of the room its summary keeps.
    static func disclosureSide(_ style: TranscriptStyle) -> CGFloat {
        (style.toolPointSize * 0.9).rounded()
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

    enum Shape { case bubble, card, line, divider }

    static func shape(of kind: TranscriptItem.Kind) -> Shape {
        switch kind {
        case .personMessage, .workerReply, .thinking:  .bubble
        case .executionFailed, .executionInterrupted:  .card
        case .toolRun:                                 .line
        case .daySeparator, .contextSeparator,
             .activityNotShown:                        .divider
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
        let indent  = leading(style)
        let measure = isWide ? style.wideMeasure
            : isLong(kind) || shape(of: kind) != .bubble ? style.longMeasure : style.shortMeasure
        switch kind {
        case .personMessage:
            // The person's bubble leaves room on the left, so it never spans the row.
            return max(60, min(measure, (rowWidth - 2 * gutter) * 0.8))
        case .daySeparator, .contextSeparator, .activityNotShown:
            return max(60, rowWidth - 2 * gutter)
        default:
            return max(60, min(measure, rowWidth - indent - gutter))
        }
    }
}
