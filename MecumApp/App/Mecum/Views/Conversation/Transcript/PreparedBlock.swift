//
//  PreparedBlock.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit

/// PreparedBlock is one block of a row's text: a paragraph or list, a
/// heading, a quote, a code block, a table or a rule. It is the unit the
/// transcript measures, caches and lays out (§12.3).
///
/// Its identity is where its source starts in the message, which appending to
/// the message never moves, so a block that did not change keeps both its id
/// and its value as a message grows.
nonisolated struct PreparedBlock: Sendable, Hashable {

    enum Kind: Sendable, Hashable {
        case text
        case heading(level: Int)
        case quote

        /// A fenced or indented code block. `isComplete` is false for the
        /// provisional lines of a fence that has not closed yet.
        case code(language: String?, isComplete: Bool)

        case table(Table)
        case rule
    }

    /// The source offset, in UTF-16 units, of the chunk the block came from,
    /// and the block's place among that chunk's blocks.
    struct ID: Sendable, Hashable {
        let offset: Int
        let part  : Int

        init(offset: Int, part: Int) {
            self.offset = offset
            self.part   = part
        }
    }

    /// A table's cells, in row order. Row 0 is the header.
    struct Table: Sendable, Hashable {

        enum Alignment: Sendable, Hashable { case leading, center, trailing }

        struct Cell: Sendable, Hashable {
            let row   : Int
            let column: Int
            let range : NSRange
        }

        let alignments: [Alignment]
        var cells     : [Cell] = []
    }

    var id: ID
    private(set) var kind  : Kind
    private(set) var string: String = ""
    private(set) var runs  : [PreparedText.Run] = []

    init(id: ID = ID(offset: 0, part: 0), kind: Kind) {
        self.id   = id
        self.kind = kind
    }

    /// The UTF-16 length of `string`.
    var length: Int { (string as NSString).length }

    /// True for a finished code block, the one kind with a Copy block action.
    var isCompleteCode: Bool {
        if case .code(_, true) = kind { true } else { false }
    }

    /// Adds `string` as one run. An empty string adds nothing.
    mutating func append(
        _ string: String,
        role    : PreparedText.Role,
        traits  : PreparedText.Traits = [],
        link    : String? = nil,
        indent  : Int = 0,
        hangs   : Bool = false
    ) {
        let added = (string as NSString).length
        guard added > 0 else { return }
        let range = NSRange(location: length, length: added)
        self.string += string
        runs.append(PreparedText.Run(range: range, role: role, traits: traits, link: link, indent: indent,
                                     hangs: hangs))
    }

    /// A code block of `source`, coloured by `language` (`CodeTokenizer`). The
    /// characters are the source's, so copying the block gives it byte for
    /// byte; the tokens only split it into runs, in one linear pass.
    static func code(_ source: String, language: String?, isComplete: Bool) -> PreparedBlock {
        var block  = PreparedBlock(kind: .code(language: language, isComplete: isComplete))
        block.string = source
        let length = (source as NSString).length
        var runs: [PreparedText.Run] = []
        var cursor = 0
        for token in CodeTokenizer.tokens(in: source, language: language) {
            if token.range.location > cursor {
                runs.append(PreparedText.Run(range: NSRange(location: cursor, length: token.range.location - cursor),
                                             role: .code))
            }
            runs.append(PreparedText.Run(range: token.range, role: .syntax(token.kind)))
            cursor = NSMaxRange(token.range)
        }
        if length > cursor {
            runs.append(PreparedText.Run(range: NSRange(location: cursor, length: length - cursor), role: .code))
        }
        block.runs = runs
        return block
    }

    /// Records the cell just appended, for a table block.
    mutating func addCell(row: Int, column: Int, range: NSRange) {
        guard case .table(var table) = kind else { return }
        table.cells.append(Table.Cell(row: row, column: column, range: range))
        kind = .table(table)
    }

    /// The attributed form at `style`. Safe on any thread: it creates its
    /// fonts, colours and table objects and shares none.
    func attributed(_ style: TranscriptStyle) -> NSAttributedString {
        let result = NSMutableAttributedString(string: string)
        for run in runs {
            result.addAttributes(PreparedText.attributes(run, style), range: run.range)
        }
        switch kind {
        case .table(let table): Self.applyTable(table, to: result)
        case .code:             Self.applyHangingIndents(to: result, style: style)
        default:                break
        }
        return result
    }

    /// Tabs in code advance to the next multiple of this many columns.
    static let codeTabColumns = 4

    /// Continuations of a wrapped code line sit this many columns past its own indentation.
    static let codeHangColumns = 2

    /// Deeper indentation than this many columns hangs no further, so a
    /// continuation always keeps room on a narrow row. ponytail: a fixed cap,
    /// relative to the laid out width if deeply nested code ever reads badly.
    static let codeHangLimitColumns = 24

    /// Gives every code line a hanging indent: its first line starts at the
    /// margin as written, and a continuation, where the line wraps, starts
    /// under that line's own leading whitespace plus `codeHangColumns`. Only
    /// paragraph attributes change, so the characters stay exactly the source.
    private static func applyHangingIndents(to text: NSMutableAttributedString, style: TranscriptStyle) {
        let font   = NSFont.monospacedSystemFont(ofSize: style.codePointSize, weight: .regular)
        let column = (" " as NSString).size(withAttributes: [.font: font]).width
        let source = text.string as NSString
        var start  = 0
        while start < source.length {
            let line = source.lineRange(for: NSRange(location: start, length: 0))
            var columns = 0, offset = line.location
            while offset < NSMaxRange(line) {
                let unit = source.character(at: offset)
                if unit == 0x20 {
                    columns += 1
                } else if unit == 0x09 {
                    columns += codeTabColumns - columns % codeTabColumns
                } else {
                    break
                }
                offset += 1
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = 0
            paragraph.headIndent          = CGFloat(min(columns, codeHangLimitColumns) + codeHangColumns) * column
            paragraph.tabStops            = []
            paragraph.defaultTabInterval  = CGFloat(codeTabColumns) * column
            text.addAttribute(.paragraphStyle, value: paragraph, range: line)
            start = NSMaxRange(line)
        }
    }

    /// Lays the cells out as a TextKit table: columns align, a cell too wide
    /// for its share of the width wraps, and the text stays selectable text.
    private static func applyTable(_ table: Table, to text: NSMutableAttributedString) {
        let grid = NSTextTable()
        grid.numberOfColumns = max(1, table.alignments.count)
        grid.layoutAlgorithm = .automaticLayoutAlgorithm
        grid.collapsesBorders = true
        for cell in table.cells {
            let block = NSTextTableBlock(table: grid, startingRow: cell.row, rowSpan: 1,
                                         startingColumn: cell.column, columnSpan: 1)
            block.setWidth(1, type: .absoluteValueType, for: .border)
            block.setBorderColor(.separatorColor)
            block.setWidth(6, type: .absoluteValueType, for: .padding)
            let paragraph = NSMutableParagraphStyle()
            paragraph.textBlocks = [block]
            switch table.alignments.indices.contains(cell.column) ? table.alignments[cell.column] : .leading {
            case .leading:  paragraph.alignment = .natural
            case .center:   paragraph.alignment = .center
            case .trailing: paragraph.alignment = .right
            }
            // The cell's paragraph includes its newline, which ends the cell.
            let end   = min(text.length, NSMaxRange(cell.range) + 1)
            let range = NSRange(location: cell.range.location, length: end - cell.range.location)
            text.addAttribute(.paragraphStyle, value: paragraph, range: range)
        }
    }
}
