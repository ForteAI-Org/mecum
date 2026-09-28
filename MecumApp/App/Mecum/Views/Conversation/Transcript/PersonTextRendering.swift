//
//  PersonTextRendering.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation

/// PersonTextRendering prepares the person's own message: its fenced code
/// blocks become coloured code blocks and its backtick spans inline code, and
/// every other character stays exactly as typed, so a `*` or `_` never
/// disappears into emphasis.
///
/// A fence opens and closes as in Markdown (`MarkdownSourceChunks`); one left
/// open runs to the end of the message. An inline span is a run of backticks
/// closed by the next run of the same length; an unmatched run stays literal.
/// Blank lines next to a fence become the space between blocks. Pure: any thread.
nonisolated enum PersonTextRendering {

    static func blocks(_ source: String) -> [PreparedBlock] {
        var blocks: [PreparedBlock] = []
        var prose : [Substring] = []
        var proseStart = 0
        var offset     = 0
        var fence: (opening: MarkdownSourceChunks.Fence, start: Int, lines: [Substring])?

        func flushProse() {
            while let first = prose.first, first.allSatisfy(\.isWhitespace) {
                proseStart += first.utf16.count + 1
                prose.removeFirst()
            }
            while let last = prose.last, last.allSatisfy(\.isWhitespace) { prose.removeLast() }
            if !prose.isEmpty { blocks.append(literal(prose.joined(separator: "\n"), at: proseStart)) }
            prose = []
        }

        func flushCode() {
            guard let open = fence else { return }
            let code = open.lines.map { MarkdownSourceChunks.outdent($0, by: open.opening.indent) }
            var block = PreparedBlock.code(code.joined(separator: "\n"), language: open.opening.language,
                                           isComplete: true)
            block.id = PreparedBlock.ID(offset: open.start, part: 0)
            if block.length > 0 { blocks.append(block) }
            fence = nil
        }

        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineOffset = offset
            offset += line.utf16.count + 1
            if let open = fence {
                if MarkdownSourceChunks.isClosing(line, of: open.opening) {
                    flushCode()
                } else {
                    fence?.lines.append(line)
                }
                continue
            }
            if let opening = MarkdownSourceChunks.opening(line) {
                flushProse()
                fence = (opening, lineOffset, [])
                continue
            }
            if prose.isEmpty { proseStart = lineOffset }
            prose.append(line)
        }
        flushCode()
        flushProse()
        return blocks
    }

    /// One text block of `text`, literal on the accent, its backtick spans as inline code.
    ///
    /// ponytail: each unmatched backtick run looks ahead for a partner, so a
    /// message made of many unmatched runs is quadratic in them; a person's
    /// message is short. Index runs by length if that ever shows.
    private static func literal(_ text: String, at offset: Int) -> PreparedBlock {
        var block = PreparedBlock(id: PreparedBlock.ID(offset: offset, part: 0), kind: .text)
        let characters = Array(text)
        var runs: [(start: Int, length: Int)] = []
        var index = 0
        while index < characters.count {
            guard characters[index] == "`" else {
                index += 1
                continue
            }
            let start = index
            while index < characters.count, characters[index] == "`" { index += 1 }
            runs.append((start, index - start))
        }

        var written = 0
        var run     = 0
        while run < runs.count {
            let open = runs[run]
            guard let close = runs[(run + 1)...].firstIndex(where: { $0.length == open.length }) else {
                run += 1
                continue
            }
            let end = runs[close]
            block.append(String(characters[written..<open.start]), role: .bodyOnAccent)
            var inner = String(characters[(open.start + open.length)..<end.start])
            // As in Markdown, one space inside each end is padding when the span is not only spaces.
            if inner.count >= 2, inner.first == " ", inner.last == " ", inner.contains(where: { $0 != " " }) {
                inner = String(inner.dropFirst().dropLast())
            }
            block.append(inner, role: .codeOnAccent)
            written = end.start + end.length
            run     = close + 1
        }
        block.append(String(characters[written...]), role: .bodyOnAccent)
        return block
    }
}
