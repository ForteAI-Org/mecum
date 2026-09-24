//
//  MarkdownSourceChunks.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation

/// MarkdownSourceChunks splits a message's Markdown source into chunks that
/// parse independently, so a growing message parses only its tail (§12.3).
///
/// A chunk ends at a blank line followed by a line at column 0, or where a
/// code fence opens or closes. A line that is indented after a blank line
/// continues the chunk, so a list item's later paragraphs stay in its list.
/// The split is conservative: two chunks it keeps together only cost a
/// larger re-parse while they are the tail, never a different rendering.
///
/// Known limit: a reference-style link definition resolves only inside its
/// own chunk.
nonisolated enum MarkdownSourceChunks {

    struct Chunk: Sendable, Hashable {

        enum Kind: Sendable, Hashable {

            /// Complete Markdown, a closed fence included, for the parser.
            case markdown

            /// A fence still open at the end of the source: its lines so far,
            /// without the opening line, and the language it declared.
            case openFence(language: String?)
        }

        /// Where the chunk starts in the source, in UTF-16 units.
        let offset: Int
        let text  : String
        let kind  : Kind
    }

    struct Fence {
        let marker  : Character
        let length  : Int
        let indent  : Int
        let language: String?
    }

    static func split(_ source: String) -> [Chunk] {
        var chunks: [Chunk] = []
        var lines : [Substring] = []
        var start  = 0
        var offset = 0
        var fence  : Fence?
        var afterBlank = false

        func close(_ kind: Chunk.Kind) {
            while let last = lines.last, isBlank(last) { lines.removeLast() }
            if !lines.isEmpty { chunks.append(Chunk(offset: start, text: lines.joined(separator: "\n"), kind: kind)) }
            lines = []
        }

        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineOffset = offset
            offset += line.utf16.count + 1

            if let open = fence {
                lines.append(line)
                if isClosing(line, of: open) {
                    close(.markdown)
                    fence = nil
                }
                continue
            }
            if let open = opening(line) {
                close(.markdown)
                start      = lineOffset
                lines      = [line]
                fence      = open
                afterBlank = false
                continue
            }
            if isBlank(line) {
                afterBlank = true
                if !lines.isEmpty { lines.append(line) }
                continue
            }
            if afterBlank, line.first?.isWhitespace == false { close(.markdown) }
            if lines.isEmpty { start = lineOffset }
            afterBlank = false
            lines.append(line)
        }

        if let open = fence {
            // The opening line is dropped and the content is outdented as the parser would.
            let content = lines.dropFirst().map { outdent($0, by: open.indent) }
            if !content.isEmpty {
                chunks.append(Chunk(offset: start, text: content.joined(separator: "\n"),
                                    kind: .openFence(language: open.language)))
            }
        } else {
            close(.markdown)
        }
        return chunks
    }

    // MARK: Lines

    private static func isBlank(_ line: Substring) -> Bool {
        line.allSatisfy(\.isWhitespace)
    }

    private static func leadingSpaces(_ line: Substring) -> Int {
        line.prefix { $0 == " " }.count
    }

    /// A line of three or more backticks or tildes, indented at most three
    /// spaces. A backtick fence's info string may not contain a backtick.
    static func opening(_ line: Substring) -> Fence? {
        let indent = leadingSpaces(line)
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard let marker = rest.first, marker == "`" || marker == "~" else { return nil }
        let length = rest.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }
        let info = rest.dropFirst(length).trimmingCharacters(in: .whitespaces)
        if marker == "`", info.contains("`") { return nil }
        let language = info.split(separator: " ").first.map(String.init)
        return Fence(marker: marker, length: length, indent: indent, language: language)
    }

    static func isClosing(_ line: Substring, of fence: Fence) -> Bool {
        let indent = leadingSpaces(line)
        guard indent <= 3 else { return false }
        let rest   = line.dropFirst(indent)
        let length = rest.prefix { $0 == fence.marker }.count
        return length >= fence.length && rest.dropFirst(length).allSatisfy(\.isWhitespace)
    }

    static func outdent(_ line: Substring, by indent: Int) -> Substring {
        line.dropFirst(min(indent, leadingSpaces(line)))
    }
}
