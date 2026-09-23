//
//  CodeGrammar.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation

/// CodeGrammar is what `CodeTokenizer` knows of one language: its comment
/// and string delimiters, its keywords and which identifiers read as types.
///
/// ponytail: a lexical table, not a grammar. It colours comments, strings,
/// numbers, keywords and type-like names by their first characters, with no
/// nesting, interpolation, regex literals or context beyond one token; a
/// language that needs more gets a real lexer, never a longer table.
struct CodeGrammar: Sendable {

    /// How the scanner treats characters outside comments and strings.
    enum Style: Sendable {
        case code
        case markup
        case stylesheet
        case yaml
        case json
    }

    var style         = Style.code
    var lineComments  : [String] = []

    /// A line comment opens only at a line's start or after a blank, as `#` in
    /// a shell, so `$#` or a URL's `//` stays what it is.
    var commentNeedsSpace = false
    var blockComment  : (open: String, close: String)?

    /// Quotes that open a string; the multiline ones may span lines.
    var quotes        : Set<UInt16> = [.quote]
    var multiline     : Set<UInt16> = []
    var tripleQuotes  = false

    /// `'` after a letter is an apostrophe, not a string.
    var guardsApostrophe = false

    /// `'` opens only a one-character literal, so a Rust lifetime such as `'a` is not a string.
    var apostropheIsCharacter = false
    var keywords      : Set<String> = []
    var types         : Set<String> = []
    var capitalIsType = false

    /// A character that makes the identifier after it a keyword: `@` for an attribute, `#` for a directive.
    var markers       : Set<UInt16> = []

    /// `$name` is a variable, coloured as a type.
    var dollarVariables = false

    /// The neutral grammar an unknown or missing language gets: strings, comments and numbers only.
    static let neutral = CodeGrammar(lineComments: ["//", "#"], commentNeedsSpace: true,
                                     blockComment: ("/*", "*/"), quotes: [.quote, .apostrophe],
                                     guardsApostrophe: true)

    /// The grammar for a fence's language tag, or `neutral`.
    static func named(_ language: String?) -> CodeGrammar {
        guard let tag = language?.lowercased() else { return neutral }
        switch tag {
        case "swift":
            return CodeGrammar(lineComments: ["//"], blockComment: ("/*", "*/"), tripleQuotes: true,
                               keywords: swiftKeywords, capitalIsType: true, markers: [.at, .hash])
        case "python", "py", "python3":
            return CodeGrammar(lineComments: ["#"], quotes: [.quote, .apostrophe], tripleQuotes: true,
                               keywords: pythonKeywords, types: pythonTypes, capitalIsType: true, markers: [.at])
        case "javascript", "js", "jsx", "mjs", "cjs", "typescript", "ts", "tsx":
            return CodeGrammar(lineComments: ["//"], blockComment: ("/*", "*/"),
                               quotes: [.quote, .apostrophe, .backtick], multiline: [.backtick],
                               keywords: scriptKeywords, capitalIsType: true, markers: [.at])
        case "json", "jsonc", "json5":
            return CodeGrammar(style: .json, lineComments: ["//"], blockComment: ("/*", "*/"),
                               keywords: ["true", "false", "null"])
        case "sh", "bash", "zsh", "shell", "console", "shell-session", "fish":
            return CodeGrammar(lineComments: ["#"], commentNeedsSpace: true, quotes: [.quote, .apostrophe],
                               multiline: [.quote, .apostrophe], keywords: shellKeywords, dollarVariables: true)
        case "go", "golang":
            return CodeGrammar(lineComments: ["//"], blockComment: ("/*", "*/"),
                               quotes: [.quote, .apostrophe, .backtick], multiline: [.backtick],
                               keywords: goKeywords, types: goTypes)
        case "rust", "rs":
            return CodeGrammar(lineComments: ["//"], blockComment: ("/*", "*/"), quotes: [.quote, .apostrophe],
                               guardsApostrophe: true, apostropheIsCharacter: true, keywords: rustKeywords,
                               types: rustTypes,
                               capitalIsType: true, markers: [.hash])
        case "c", "h", "cpp", "c++", "cc", "cxx", "hpp", "hh", "objc", "objective-c", "objectivec", "m", "mm":
            return CodeGrammar(lineComments: ["//"], blockComment: ("/*", "*/"), quotes: [.quote, .apostrophe],
                               keywords: cKeywords, types: cTypes, capitalIsType: true, markers: [.hash, .at])
        case "html", "htm", "xml", "xhtml", "svg", "plist", "xaml":
            return CodeGrammar(style: .markup, blockComment: ("<!--", "-->"), quotes: [.quote, .apostrophe])
        case "css", "scss", "less":
            return CodeGrammar(style: .stylesheet, lineComments: tag == "css" ? [] : ["//"],
                               blockComment: ("/*", "*/"), quotes: [.quote, .apostrophe],
                               keywords: ["important"], markers: [.at, .bang])
        case "yaml", "yml":
            return CodeGrammar(style: .yaml, lineComments: ["#"], commentNeedsSpace: true,
                               quotes: [.quote, .apostrophe], guardsApostrophe: true,
                               keywords: ["true", "false", "null", "yes", "no", "on", "off", "True", "False"])
        default:
            return neutral
        }
    }

    // MARK: Vocabularies

    private static let swiftKeywords: Set<String> = [
        "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue",
        "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate",
        "final", "for", "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "let", "mutating",
        "nil", "nonisolated", "open", "operator", "override", "package", "private", "protocol", "public",
        "repeat", "rethrows", "return", "self", "Self", "some", "static", "struct", "subscript", "super",
        "switch", "throw", "throws", "true", "try", "typealias", "var", "weak", "where", "while",
    ]

    private static let pythonKeywords: Set<String> = [
        "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def",
        "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is",
        "lambda", "match", "nonlocal", "not", "or", "pass", "raise", "return", "self", "try", "while", "with",
        "yield",
    ]

    private static let pythonTypes: Set<String> = [
        "bool", "bytes", "dict", "float", "frozenset", "int", "list", "object", "set", "str", "tuple", "type",
    ]

    private static let scriptKeywords: Set<String> = [
        "abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
        "declare", "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for",
        "from", "function", "get", "if", "implements", "import", "in", "instanceof", "interface", "keyof", "let",
        "namespace", "new", "null", "of", "private", "protected", "public", "readonly", "return", "set",
        "static", "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var",
        "void", "while", "yield", "any", "boolean", "never", "number", "string", "unknown",
    ]

    private static let shellKeywords: Set<String> = [
        "case", "cd", "declare", "do", "done", "echo", "elif", "else", "esac", "exit", "export", "fi", "for",
        "function", "if", "in", "local", "readonly", "return", "select", "set", "source", "then", "unset",
        "until", "while",
    ]

    private static let goKeywords: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "false", "for",
        "func", "go", "goto", "if", "import", "interface", "iota", "map", "nil", "package", "range", "return",
        "select", "struct", "switch", "true", "type", "var",
    ]

    private static let goTypes: Set<String> = [
        "any", "bool", "byte", "complex128", "complex64", "error", "float32", "float64", "int", "int16", "int32",
        "int64", "int8", "rune", "string", "uint", "uint16", "uint32", "uint64", "uint8", "uintptr",
    ]

    private static let rustKeywords: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false",
        "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
        "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while",
    ]

    private static let rustTypes: Set<String> = [
        "bool", "char", "f32", "f64", "i128", "i16", "i32", "i64", "i8", "isize", "str", "u128", "u16", "u32",
        "u64", "u8", "usize",
    ]

    private static let cKeywords: Set<String> = [
        "auto", "break", "case", "catch", "class", "const", "constexpr", "continue", "default", "delete", "do",
        "else", "enum", "explicit", "extern", "false", "for", "friend", "goto", "if", "inline", "namespace",
        "new", "noexcept", "nullptr", "operator", "private", "protected", "public", "register", "return",
        "sizeof", "static", "struct", "switch", "template", "this", "throw", "true", "try", "typedef",
        "typename", "union", "using", "virtual", "volatile", "while", "nil", "self", "super", "YES", "NO",
    ]

    private static let cTypes: Set<String> = [
        "bool", "char", "double", "float", "id", "int", "long", "short", "signed", "size_t", "unsigned", "void",
        "BOOL", "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t",
    ]
}

extension UInt16 {
    static let quote     : UInt16 = 0x22
    static let apostrophe: UInt16 = 0x27
    static let backtick  : UInt16 = 0x60
    static let at        : UInt16 = 0x40
    static let hash      : UInt16 = 0x23
    static let bang      : UInt16 = 0x21
}
