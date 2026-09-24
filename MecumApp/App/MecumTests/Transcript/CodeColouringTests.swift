//
//  CodeColouringTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import Foundation
import Testing
@testable import Mecum

/// Syntax colouring and the person's own code: token kinds per language, the
/// neutral fallback, linear cost, byte exact copies and readable colours.
@Suite("Code: tokens per language, neutral fallback, linear cost, the person's code")
struct CodeColouringTests {

    /// The text of each token of `kind` in `source`.
    private static func texts(_ source: String, _ language: String?, _ kind: CodeToken.Kind) -> [String] {
        let string = source as NSString
        return CodeTokenizer.tokens(in: source, language: language)
            .filter { $0.kind == kind }
            .map { string.substring(with: $0.range) }
    }

    private static func expectKinds(
        _ source  : String,
        _ language: String,
        comment   : String? = nil,
        string    : String? = nil,
        number    : String? = nil,
        keyword   : String? = nil,
        type      : String? = nil
    ) {
        let expected: [(CodeToken.Kind, String?)] = [(.comment, comment), (.string, string), (.number, number),
                                                     (.keyword, keyword), (.type, type)]
        for case let (kind, text?) in expected {
            #expect(texts(source, language, kind).contains(text), "\(language): \(text) should be a \(kind)")
        }
    }

    @Test("Each language's snippet gives the expected token kinds")
    func perLanguage() {
        Self.expectKinds("// sum\nlet total: Int = 42\nprint(\"total\")", "swift",
                         comment: "// sum", string: "\"total\"", number: "42", keyword: "let", type: "Int")
        Self.expectKinds("# sum\ndef total(items: list) -> int:\n    return 'x' + str(3)", "python",
                         comment: "# sum", string: "'x'", number: "3", keyword: "def", type: "list")
        Self.expectKinds("/* sum */ const total: Map<string, number> = new Map(); `t${1}`", "ts",
                         comment: "/* sum */", string: "`t${1}`", keyword: "const", type: "Map")
        Self.expectKinds("{\"name\": \"mecum\", \"count\": 3, \"ok\": true}", "json",
                         string: "\"mecum\"", number: "3", keyword: "true", type: "\"name\"")
        Self.expectKinds("# build\nif [ -n \"$HOME\" ]; then echo 'ok' 2; fi", "bash",
                         comment: "# build", string: "'ok'", number: "2", keyword: "then")
        Self.expectKinds("// main\nfunc main() { var n int = 7; fmt.Println(\"go\") }", "go",
                         comment: "// main", string: "\"go\"", number: "7", keyword: "func", type: "int")
        Self.expectKinds("// tag\nfn main() { let s: &'a str = \"rust\"; let n: u8 = 9; }", "rust",
                         comment: "// tag", string: "\"rust\"", number: "9", keyword: "fn", type: "u8")
        Self.expectKinds("#include <stdio.h>\n/* c */ int main(void) { return printf(\"%d\", 0x1F); }", "c",
                         comment: "/* c */", string: "\"%d\"", number: "0x1F", keyword: "#include", type: "int")
        Self.expectKinds("@interface Row : NSObject\n@property NSString *name; // objc\n@end", "objc",
                         comment: "// objc", keyword: "@interface", type: "NSString")
        Self.expectKinds("<!-- note --><div class=\"row\">Don't 5</div>", "html",
                         comment: "<!-- note -->", string: "\"row\"", keyword: "div", type: "class")
        Self.expectKinds("/* css */ .row { color: #fff; margin: 4px !important; } @media print {}", "css",
                         comment: "/* css */", number: "4px", keyword: "@media", type: "color")
        Self.expectKinds("# config\nname: \"mecum\"\nretries: 3\nenabled: true", "yaml",
                         comment: "# config", string: "\"mecum\"", number: "3", keyword: "true", type: "retries")

        // Markup text is not code: an apostrophe outside a tag opens no string.
        #expect(!Self.texts("<p>Don't stop</p>", "html", .string).contains { $0.contains("t stop") })
        #expect(Self.texts("fn f<'a>(x: &'a str) -> char { 'z' }", "rust", .string) == ["'z'"])
    }

    @Test("An unknown or missing language gets strings, comments and numbers only")
    func neutralFallback() {
        let source = "# note\nlet total = \"sum\" + 42 // tail\nopen https://example.com it's fine"
        for language in [nil, "brainfuck"] {
            let kinds = Set(CodeTokenizer.tokens(in: source, language: language).map(\.kind))
            #expect(kinds == [.comment, .string, .number])
            #expect(Self.texts(source, language, .comment) == ["# note", "// tail"])
            #expect(Self.texts(source, language, .string) == ["\"sum\""])
        }
    }

    @Test("A 3,000 line block costs a constant amount per character: linear, counted not timed")
    func linearCost() {
        let unit = """
            // A comment with "quotes" and 'apostrophes'
            struct Row { let id: Int = 0x1F; var name = "row \\(id)" }
            /* a block comment */ func f() -> [String] { return ["a", "b"] }

            """
        let short = String(repeating: unit, count: 100)
        let long  = String(repeating: unit, count: 1_000)
        #expect(long.split(separator: "\n", omittingEmptySubsequences: false).count > 3_000)

        let small = CodeTokenizer.scan(short, language: "swift")
        let large = CodeTokenizer.scan(long, language: "swift")
        let perCharacter = Double(large.inspected) / Double(long.utf16.count)
        #expect(perCharacter < 3, "inspections per character: \(perCharacter)")
        #expect(large.inspected == 10 * small.inspected)
        #expect(large.tokens.count == 10 * small.tokens.count)
        #expect(Double(large.tokens.count) / Double(long.utf16.count) < 0.5)

        // Tokens are ordered, never overlap and stay inside the source.
        var end = 0
        for token in large.tokens {
            #expect(token.range.location >= end)
            end = NSMaxRange(token.range)
        }
        #expect(end <= long.utf16.count)
    }

    @Test("A coloured block keeps its source exactly, and Copy block returns it byte for byte")
    func copyIsExact() async throws {
        let code  = "let café = \"naïve 👩🏽‍💻\"\t// tab\n\tprint(café)   \n"
        let reply = "Here:\n\n```swift\n\(code)```\n"
        let text  = MarkdownContent().prepare(reply, isOnAccent: false)
        let block = try #require(text.blocks.first { $0.isCompleteCode })
        #expect(block.string == String(code.dropLast()))
        #expect(Data(block.string.utf8) == Data(String(code.dropLast()).utf8))
        #expect(block.runs.contains { if case .syntax(.string) = $0.role { true } else { false } })
        #expect(block.runs.map(\.range.length).reduce(0, +) == block.length)
        #expect(block.attributed(TranscriptStyle()).string == block.string)
    }

    @Test("Every token colour reads on the code surface at WCAG AA, light and dark")
    func contrast() {
        let surfaces = [(false, TranscriptColors.codeSurfaceWhite.light), (true, TranscriptColors.codeSurfaceWhite.dark)]
        for (isDark, white) in surfaces {
            let surface = TranscriptColors.luminance(white, white, white)
            for kind in CodeToken.Kind.allCases {
                let (red, green, blue) = TranscriptColors.syntaxComponents(kind, isDark: isDark)
                let token = TranscriptColors.luminance(red, green, blue)
                let ratio = (max(token, surface) + 0.05) / (min(token, surface) + 0.05)
                #expect(ratio >= 4.5, "\(kind) \(isDark ? "dark" : "light"): \(ratio)")
            }
        }
    }

    @Test("The person's message renders a fence and inline code, and every other character stays literal")
    func personCode() throws {
        let message = "Why does *a* fail_here?\n\n```swift\nlet x = items.reduce(0, +)\n```\n"
            + "It says `reduce` is **ambiguous**."
        let text = MarkdownContent().prepare(message, isOnAccent: true)

        #expect(text.blocks.map(\.kind) == [.text, .code(language: "swift", isComplete: true), .text])
        #expect(text.blocks[0].string == "Why does *a* fail_here?")
        #expect(text.blocks[1].string == "let x = items.reduce(0, +)")
        #expect(text.blocks[1].runs.contains { $0.role == .syntax(.keyword) })
        #expect(text.blocks[2].string == "It says reduce is **ambiguous**.")
        let inline = try #require(text.blocks[2].runs.first { $0.role == .codeOnAccent })
        #expect((text.blocks[2].string as NSString).substring(with: inline.range) == "reduce")
        #expect(text.blocks[0].runs.allSatisfy { $0.role == .bodyOnAccent && $0.traits.isEmpty })
        #expect(RowAction.actions(in: text) == [.copyBlock(index: 1)])

        // Unmatched backticks and a message with no code stay exactly as typed.
        let plain = MarkdownContent().prepare("a `b and *c* _d_", isOnAccent: true)
        #expect(plain.string == "a `b and *c* _d_")
        #expect(plain.blocks.count == 1)
    }
}
