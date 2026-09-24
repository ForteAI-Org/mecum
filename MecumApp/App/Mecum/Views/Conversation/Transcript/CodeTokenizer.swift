//
//  CodeTokenizer.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation

/// CodeToken is one coloured stretch of a code block: where it is, in UTF-16
/// units of the block's text, and what it is.
nonisolated struct CodeToken: Sendable, Hashable {

    enum Kind: Sendable, Hashable, CaseIterable {
        case comment
        case string
        case number
        case keyword
        case type
    }

    let range: NSRange
    let kind : Kind
}

/// CodeTokenizer finds the tokens of a code block in one forward pass over
/// its UTF-16 units, by the fence's language (`CodeGrammar`).
///
/// Linear by construction: every step consumes at least one unit, and the
/// look ahead at a position is bounded by the longest delimiter, or re-reads
/// only the blanks a key lookup skips, which the pass then consumes. Tokens
/// never overlap and come in order. Pure: any thread, no state between calls.
nonisolated enum CodeTokenizer {

    /// The tokens of `source` in `language`, and how many units the pass
    /// inspected, which a test compares with the source's length.
    static func scan(_ source: String, language: String?) -> (tokens: [CodeToken], inspected: Int) {
        var scanner = Scanner(units: Array(source.utf16), grammar: CodeGrammar.named(language))
        scanner.run()
        return (scanner.tokens, scanner.inspected)
    }

    static func tokens(in source: String, language: String?) -> [CodeToken] {
        scan(source, language: language).tokens
    }

    private struct Scanner {

        let units  : [UInt16]
        let grammar: CodeGrammar
        var tokens : [CodeToken] = []
        var inspected = 0

        private let lineComments: [[UInt16]]
        private let blockOpen   : [UInt16]?
        private let blockClose  : [UInt16]?
        private var index      = 0
        private var isInTag    = false
        private var braceDepth = 0

        init(units: [UInt16], grammar: CodeGrammar) {
            self.units        = units
            self.grammar      = grammar
            self.lineComments = grammar.lineComments.map { Array($0.utf16) }
            self.blockOpen    = grammar.blockComment.map { Array($0.open.utf16) }
            self.blockClose   = grammar.blockComment.map { Array($0.close.utf16) }
        }

        mutating func run() {
            while index < units.count {
                let start = index
                step()
                // Every step moves forward; one that did not would loop.
                if index == start { index += 1 }
            }
        }

        private mutating func step() {
            let unit = units[index]
            inspected += 1

            if let open = blockOpen, let close = blockClose, matches(open, at: index) {
                let end = find(close, from: index + open.count)
                add(index, end, .comment)
                return
            }
            if lineComments.contains(where: { matches($0, at: index) }), opensComment(at: index) {
                add(index, lineEnd(from: index), .comment)
                return
            }
            if grammar.style == .markup, !isInTag {
                markupText(unit)
                return
            }
            if grammar.quotes.contains(unit), opensString(unit, at: index) {
                string(unit)
                return
            }
            if isDigit(unit), !isWordCharacter(at: index - 1) {
                number()
                return
            }
            if grammar.markers.contains(unit), isIdentifierStart(at: index + 1) {
                let start = index
                index += 1
                identifierEnd()
                add(start, index, .keyword)
                return
            }
            if grammar.dollarVariables, unit == 0x24, isIdentifier(at: index + 1) {
                let start = index
                index += 1
                identifierEnd()
                add(start, index, .type)
                return
            }
            if isIdentifierStart(at: index) {
                word()
                return
            }
            punctuation(unit)
        }

        // MARK: Tokens

        private mutating func string(_ quote: UInt16) {
            let start = index
            let isTriple = grammar.tripleQuotes && (quote == .quote || quote == .apostrophe)
                && matches([quote, quote, quote], at: index)
            if isTriple {
                add(start, find([quote, quote, quote], from: index + 3), .string)
                return
            }
            let spansLines = grammar.multiline.contains(quote)
            index += 1
            while index < units.count {
                let unit = units[index]
                inspected += 1
                if unit == 0x5C {
                    index = min(units.count, index + 2)
                    continue
                }
                if unit == quote {
                    index += 1
                    break
                }
                if unit == 0x0A, !spansLines { break }
                index += 1
            }
            let kind: CodeToken.Kind = grammar.style == .json && nextIsColon() ? .type : .string
            add(start, index, kind)
        }

        private mutating func number() {
            let start = index
            while index < units.count, isIdentifier(at: index) || (units[index] == 0x2E && isDigit(at: index + 1)) {
                inspected += 1
                index += 1
            }
            add(start, index, .number)
        }

        /// An identifier: a keyword, a type-like name, a YAML key or a CSS property, or plain.
        private mutating func word() {
            let start = index
            identifierEnd()
            let text  = String(decoding: units[start..<index], as: UTF16.self)
            let first = units[start]
            if grammar.keywords.contains(text) {
                add(start, index, .keyword)
            } else if grammar.types.contains(text) || (grammar.capitalIsType && first >= 0x41 && first <= 0x5A) {
                add(start, index, .type)
            } else if grammar.style == .yaml, isLineStart(before: start), nextIsColon() {
                add(start, index, .type)
            } else if grammar.style == .stylesheet, braceDepth > 0, nextIsColon() {
                add(start, index, .type)
            } else if grammar.style == .markup, isInTag {
                add(start, index, .type)
            }
        }

        private mutating func markupText(_ unit: UInt16) {
            guard unit == 0x3C else {
                index += 1
                return
            }
            // A tag's name reads as a keyword; its attributes and values follow inside it.
            let start = index
            index += 1
            if index < units.count, units[index] == 0x2F || units[index] == 0x3F || units[index] == 0x21 {
                index += 1
            }
            if isIdentifierStart(at: index) {
                identifierEnd()
                add(start + 1, index, .keyword)
                isInTag = true
            }
        }

        private mutating func punctuation(_ unit: UInt16) {
            switch unit {
            case 0x7B: braceDepth += 1
            case 0x7D: braceDepth = max(0, braceDepth - 1)
            case 0x3E: isInTag = false
            case 0x23 where grammar.style == .stylesheet && isIdentifier(at: index + 1):
                // A hex colour reads as a number.
                let start = index
                index += 1
                identifierEnd()
                add(start, index, .number)
                return
            default: break
            }
            index += 1
        }

        // MARK: Looking

        private func matches(_ pattern: [UInt16], at position: Int) -> Bool {
            guard position >= 0, position + pattern.count <= units.count else { return false }
            for (offset, unit) in pattern.enumerated() where units[position + offset] != unit { return false }
            return true
        }

        /// The end of the first `pattern` from `position`, or the end of the source.
        private mutating func find(_ pattern: [UInt16], from position: Int) -> Int {
            var cursor = position
            while cursor + pattern.count <= units.count {
                inspected += 1
                if matches(pattern, at: cursor) { return cursor + pattern.count }
                cursor += 1
            }
            return units.count
        }

        private mutating func lineEnd(from position: Int) -> Int {
            var cursor = position
            while cursor < units.count, units[cursor] != 0x0A {
                inspected += 1
                cursor += 1
            }
            return cursor
        }

        private func opensComment(at position: Int) -> Bool {
            guard grammar.commentNeedsSpace else { return true }
            return position == 0 || isBlank(units[position - 1])
        }

        private func opensString(_ quote: UInt16, at position: Int) -> Bool {
            guard quote == .apostrophe else { return true }
            // An apostrophe inside a word is not a string, and a lifetime such as 'a has no closing quote near.
            if grammar.guardsApostrophe, isWordCharacter(at: position - 1) { return false }
            guard grammar.apostropheIsCharacter else { return true }
            let isEscape = position + 1 < units.count && units[position + 1] == 0x5C
            return isEscape || (position + 2 < units.count && units[position + 2] == .apostrophe)
        }

        /// True when the next non-blank unit on the line is a colon. The blanks
        /// read here are the ones the pass consumes next, so the pass stays linear.
        private mutating func nextIsColon() -> Bool {
            var cursor = index
            while cursor < units.count, units[cursor] == 0x20 || units[cursor] == 0x09 {
                inspected += 1
                cursor += 1
            }
            return cursor < units.count && units[cursor] == 0x3A
        }

        /// True when only indentation and list dashes precede `position` on its
        /// line. It re-reads the blanks the pass consumed before this word, once.
        private mutating func isLineStart(before position: Int) -> Bool {
            var cursor = position - 1
            while cursor >= 0, units[cursor] == 0x20 || units[cursor] == 0x09 || units[cursor] == 0x2D {
                inspected += 1
                cursor -= 1
            }
            return cursor < 0 || units[cursor] == 0x0A
        }

        private mutating func identifierEnd() {
            while index < units.count, isIdentifier(at: index) {
                inspected += 1
                index += 1
            }
        }

        private func isIdentifierStart(at position: Int) -> Bool {
            guard position >= 0, position < units.count else { return false }
            let unit = units[position]
            return isLetter(unit) || unit == 0x5F || unit >= 0x80
        }

        private func isIdentifier(at position: Int) -> Bool {
            guard position >= 0, position < units.count else { return false }
            let unit = units[position]
            return isLetter(unit) || isDigit(unit) || unit == 0x5F || unit >= 0x80
                || (unit == 0x2D && (grammar.style == .stylesheet || grammar.style == .markup))
        }

        /// A letter, digit or underscore: what a number or apostrophe after it would belong to.
        private func isWordCharacter(at position: Int) -> Bool {
            guard position >= 0, position < units.count else { return false }
            let unit = units[position]
            return isLetter(unit) || isDigit(unit) || unit == 0x5F || unit >= 0x80
        }

        private func isDigit(at position: Int) -> Bool {
            position >= 0 && position < units.count && isDigit(units[position])
        }

        private func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }

        private func isLetter(_ unit: UInt16) -> Bool { (unit | 0x20) >= 0x61 && (unit | 0x20) <= 0x7A }

        private func isBlank(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x09 || unit == 0x0A }

        private mutating func add(_ start: Int, _ end: Int, _ kind: CodeToken.Kind) {
            index = max(index, end)
            guard end > start else { return }
            tokens.append(CodeToken(range: NSRange(location: start, length: end - start), kind: kind))
        }
    }
}
