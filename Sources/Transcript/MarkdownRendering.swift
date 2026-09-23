//
//  MarkdownRendering.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation

/// MarkdownRendering turns one chunk of Markdown into prepared blocks,
/// through Foundation's parser with full interpretation, whose
/// `PresentationIntent` carries the block structure.
///
/// What it never does, whatever the source says (§12.4): execute or
/// interpret HTML, which stays as the characters the model sent; fetch an
/// image, whose reference becomes its alt text and its destination; hide a
/// link's destination, which is shown beside its text unless the text is
/// the destination already. A pure function: no view, no network, any thread.
enum MarkdownRendering {

    private static let options = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: false,
        interpretedSyntax       : .full,
        failurePolicy           : .returnPartiallyParsedIfPossible
    )

    /// The blocks `markdown` renders as. Source the parser rejects shows as
    /// the characters it is, in one text block, so nothing a model sent is lost.
    static func blocks(_ markdown: String) -> [PreparedBlock] {
        let parsed: AttributedString
        do {
            parsed = try AttributedString(markdown: markdown, options: options)
        } catch {
            var block = PreparedBlock(kind: .text)
            block.append(markdown, role: .body)
            return [block]
        }
        var builder = Builder()
        for run in parsed.runs {
            builder.add(String(parsed[run.range].characters), intent: run.presentationIntent,
                        inline: run.inlinePresentationIntent ?? [], link: run.link, image: run.imageURL)
        }
        return builder.finish()
    }

    /// The destination as shown: without the scheme, cut at 60 characters.
    static func shownDestination(_ url: URL) -> String {
        var shown = url.absoluteString
        for scheme in ["https://", "http://", "mailto:"] where shown.hasPrefix(scheme) {
            shown.removeFirst(scheme.count)
        }
        if shown.hasSuffix("/") { shown.removeLast() }
        return shown.count > 60 ? shown.prefix(59) + "…" : shown
    }

    // MARK: Building

    /// Builder walks the parser's runs in order and cuts them into blocks.
    private struct Builder {

        private var blocks : [PreparedBlock] = []
        private var current: PreparedBlock?
        private var segment: Int?

        /// The innermost block the last run belonged to, a paragraph or a cell.
        private var paragraph: Int?
        private var hangs     = false

        /// The list nesting of the paragraph being built.
        private var depth     = 0
        private var markedItems: Set<Int> = []

        /// A link or image whose destination is shown once its last run is in.
        private var pendingLink: (url: URL, text: String)?

        /// A table's cells, gathered until the table ends, by row and column.
        private var cells: [TableCellKey: [Piece]] = [:]
        private var cellKey: TableCellKey?

        private struct TableCellKey: Hashable { let row: Int; let column: Int }

        private struct Piece {
            let text  : String
            let role  : PreparedText.Role
            let traits: PreparedText.Traits
            let link  : String?
        }

        mutating func add(
            _ text: String,
            intent: PresentationIntent?,
            inline: InlinePresentationIntent,
            link  : URL?,
            image : URL?
        ) {
            let components = intent?.components ?? []
            let (key, kind) = Self.segment(of: components)
            let target = image ?? link

            if pendingLink.map({ $0.url != target }) ?? false { flushLink() }
            if key != segment || kind == nil {
                finishBlock()
                segment = key
                current = PreparedBlock(kind: kind ?? .text)
            }
            let innermost = components.first?.identity
            if innermost != paragraph {
                flushLink()
                startParagraph(components)
            }

            var role: PreparedText.Role
            switch current?.kind {
            case .heading(let level)?: role = .heading(level: level)
            case .code?:               role = .code
            default:                   role = .body
            }
            if inline.contains(.code) { role = .code }
            var traits: PreparedText.Traits = []
            if inline.contains(.emphasized)         { traits.insert(.italic) }
            if inline.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if inline.contains(.strikethrough)      { traits.insert(.strikethrough) }
            if case .table = current?.kind, cellKey?.row == 0 { traits.insert(.bold) }

            var shown = text
            if inline.contains(.softBreak) || inline.contains(.lineBreak) { shown = "\u{2028}" }
            if case .code? = current?.kind, shown.hasSuffix("\n") { shown.removeLast() }
            if let target {
                role = .link
                if image != nil, shown.isEmpty { shown = "Image" }
                pendingLink = (target, (pendingLink?.text ?? "") + shown)
            }
            put(Piece(text: shown, role: role, traits: traits, link: target?.absoluteString))
        }

        mutating func finish() -> [PreparedBlock] {
            finishBlock()
            return blocks
        }

        // MARK: Segments and paragraphs

        /// The block a run belongs to: a code block or table wherever it
        /// nests, otherwise the top-level block. A run with no intent is raw
        /// block HTML, and each one is its own text block.
        private static func segment(of components: [PresentationIntent.IntentType])
            -> (key: Int?, kind: PreparedBlock.Kind?) {
            for component in components {
                switch component.kind {
                case .codeBlock(let language):
                    return (component.identity, .code(language: language, isComplete: true))
                case .table(let columns):
                    let alignments = columns.map { column -> PreparedBlock.Table.Alignment in
                        switch column.alignment {
                        case .center: .center
                        case .right:  .trailing
                        default:      .leading
                        }
                    }
                    return (component.identity, .table(PreparedBlock.Table(alignments: alignments)))
                default:
                    continue
                }
            }
            guard let outermost = components.last else { return (nil, nil) }
            switch outermost.kind {
            case .header(let level): return (outermost.identity, .heading(level: level))
            case .thematicBreak:     return (outermost.identity, .rule)
            case .blockQuote:        return (outermost.identity, .quote)
            default:                 return (outermost.identity, .text)
            }
        }

        /// Separates paragraphs inside a block and puts a list item's marker
        /// before its first paragraph.
        private mutating func startParagraph(_ components: [PresentationIntent.IntentType]) {
            let isFirst = paragraph == nil
            paragraph = components.first?.identity
            hangs     = false
            depth     = 0

            if case .table = current?.kind {
                var row = 0, column = 0
                for component in components {
                    switch component.kind {
                    case .tableCell(let index): column = index
                    case .tableRow(let index):  row = index
                    default:                    continue
                    }
                }
                cellKey = TableCellKey(row: row, column: column)
                return
            }
            if case .rule? = current?.kind { return }
            if !isFirst { current?.append("\n", role: .body) }

            let lists = components.filter {
                switch $0.kind { case .orderedList, .unorderedList: true; default: false }
            }
            depth = lists.count
            guard let itemIndex = components.firstIndex(where: {
                if case .listItem = $0.kind { true } else { false }
            }), case .listItem(let ordinal) = components[itemIndex].kind else { return }
            let item = components[itemIndex].identity
            guard !markedItems.contains(item) else { return }
            markedItems.insert(item)
            hangs = true

            let isOrdered: Bool
            if itemIndex + 1 < components.count, case .orderedList = components[itemIndex + 1].kind {
                isOrdered = true
            } else {
                isOrdered = false
            }
            let bullets = ["•", "◦", "▪"]
            let marker  = isOrdered ? "\(ordinal)." : bullets[min(lists.count, bullets.count) - 1]
            put(Piece(text: marker + "\t", role: .body, traits: [], link: nil))
        }

        /// Adds a piece to the current block, or to the current cell of a table.
        private mutating func put(_ piece: Piece) {
            if case .table = current?.kind, let cellKey {
                cells[cellKey, default: []].append(piece)
                return
            }
            if case .rule? = current?.kind { return }
            current?.append(piece.text, role: piece.role, traits: piece.traits, link: piece.link,
                            indent: depth, hangs: hangs)
        }

        /// Shows where the pending link points, unless its text already says so.
        private mutating func flushLink() {
            guard let (url, text) = pendingLink else { return }
            pendingLink = nil
            let shown = MarkdownRendering.shownDestination(url)
            guard text != url.absoluteString, text != shown else { return }
            put(Piece(text: " (\(shown))", role: .destination, traits: [], link: url.absoluteString))
        }

        private mutating func finishBlock() {
            flushLink()
            guard var block = current else { return }
            current     = nil
            paragraph   = nil
            markedItems = []
            if case .table(let table) = block.kind {
                block = tableBlock(table)
            }
            if block.length > 0 || block.kind == .rule { blocks.append(block) }
        }

        /// The table's text, row by row, one paragraph per cell. A cell the
        /// parser left without runs gets a space, so every column exists.
        private mutating func tableBlock(_ table: PreparedBlock.Table) -> PreparedBlock {
            var block = PreparedBlock(kind: .table(PreparedBlock.Table(alignments: table.alignments)))
            let rows  = (cells.keys.map(\.row).max() ?? -1) + 1
            for row in 0..<rows {
                for column in table.alignments.indices {
                    if row + column > 0 { block.append("\n", role: .body) }
                    let start  = block.length
                    let pieces = cells[TableCellKey(row: row, column: column)] ?? []
                    if pieces.isEmpty { block.append(" ", role: .body) }
                    for piece in pieces {
                        block.append(piece.text, role: piece.role, traits: piece.traits, link: piece.link)
                    }
                    block.addCell(row: row, column: column,
                                  range: NSRange(location: start, length: block.length - start))
                }
            }
            cells   = [:]
            cellKey = nil
            return block
        }
    }
}
