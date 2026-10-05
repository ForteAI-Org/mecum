//
//  Invocation.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

/// Invocation is the parsed command line: the subcommand, its positional words, and `--name value`
/// or `--flag` options, checked against the options the subcommand takes (`OptionSpec`).
///
/// The grammar, one rule for every vertical command and every batch step:
///
/// - `--name value` is a valued option, `--flag` a flag; an option the command does not take, an
///   option given twice (but a repeatable one), a valued option without its value, and a value that
///   reads as an option are refused before anything runs.
/// - `--` makes the one word after it a positional (or the value of the option before it), taken as
///   typed: the way to pass a label or a text that starts with `--`, such as `--then`, or is `--`.
/// - Words are never evaluated, split, trimmed or normalized: the shell's words reach the decoder as
///   their bytes, Unicode included.
///
/// Parsing is by shape only; what a command's words mean (a verb, a number, a key) is the shared
/// decoder's (`ToolRequestDecoder`) for the actions, and each command's own for the rest.
struct Invocation {

    let arguments: [String]
    let command: String?
    let positionals: [String]
    /// The last value of each valued option.
    let options: [String: String]
    /// Every value of each valued option, in order; more than one only for a repeatable option.
    let values: [String: [String]]
    let flags: Set<String>

    /// Parses by shape alone, as every command did before its options were checked: a word starting
    /// with `--` is a valued option when `OptionSpec.legacyValued` names it and a value follows, a flag
    /// otherwise. Kept for the dispatch in `main`, which needs the subcommand before its spec.
    init(arguments: [String]) {
        self.arguments = arguments
        var positionals: [String] = []
        var options: [String: String] = [:]
        var values: [String: [String]] = [:]
        var flags: Set<String> = []
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            if word.hasPrefix("--") {
                let name = String(word.dropFirst(2))
                if OptionSpec.legacyValued.contains(name), index + 1 < arguments.count {
                    options[name] = arguments[index + 1]
                    values[name, default: []].append(arguments[index + 1])
                    index += 1
                } else {
                    flags.insert(name)
                }
            } else {
                positionals.append(word)
            }
            index += 1
        }
        self.command     = positionals.first
        self.positionals = Array(positionals.dropFirst())
        self.options     = options
        self.values      = values
        self.flags       = flags
    }

    /// Parses `arguments` (the subcommand first) strictly against `spec`.
    init(arguments: [String], spec: OptionSpec) throws {
        guard let command = arguments.first, !command.hasPrefix("--") else {
            throw UsageError.missing("a command; run `mecum help`")
        }
        let words = try Words.parse(arguments.dropFirst(), spec: spec)
        self.arguments   = arguments
        self.command     = command
        self.positionals = words.positionals
        self.values      = words.values
        self.options     = words.values.compactMapValues(\.last)
        self.flags       = words.flags
    }

    /// The positional at `index`, or a usage error naming what is missing.
    func positional(_ index: Int, _ meaning: String) throws -> String {
        guard positionals.count > index else { throw UsageError.missing(meaning) }
        return positionals[index]
    }
}

/// OptionSpec is what one command or one batch step takes: valued options, flags, and the valued
/// options that may be given more than once.
struct OptionSpec: Equatable {

    var valued: Set<String> = []
    var flags: Set<String> = []
    var repeatable: Set<String> = []

    /// The valued options the shape-only parse knew before the commands checked their options.
    static let legacyValued: Set<String> = ["verb", "value", "section", "knowledge", "evidence", "window"]

    func merging(_ other: OptionSpec) -> OptionSpec {
        OptionSpec(valued: valued.union(other.valued), flags: flags.union(other.flags),
                   repeatable: repeatable.union(other.repeatable))
    }

    /// The options, sorted, for a sentence.
    var names: String {
        (valued.map { "--\($0) <value>" } + flags.map { "--\($0)" }).sorted().joined(separator: ", ")
    }
}

/// Words is the one tokenizer of the grammar `Invocation` describes, for a command's words and a
/// batch step's alike.
enum Words {

    struct Parsed: Equatable {
        var positionals: [String] = []
        var values: [String: [String]] = [:]
        var flags: Set<String> = []
    }

    /// Where a header ends in `words`: the index of the first `--` that is not an escape, nil when
    /// there is none. The grammar's own reading decides which `--` escapes: one in a valued option's
    /// value position (`--window -- --Window`), and one before `requiredPositionals` positionals have
    /// been read (`batch -- --App`), each with the word after it, which is taken as a word whatever
    /// it is (so an escaped `--` or `--then` never ends the header). Any other word is skipped as
    /// `parse` would read it; what it means, and whether it is allowed, stays `parse`'s to judge, so a
    /// valued option followed by an option-like word is left for `parse` to refuse. Throws when an
    /// escape has no word after it.
    static func headerEnd(_ words: ArraySlice<String>, spec: OptionSpec, requiredPositionals: Int) throws -> Int? {
        var index = words.startIndex
        var positionals = 0
        while index < words.endIndex {
            let word = words[index]
            if word == "--" {
                guard positionals < requiredPositionals else { return index }
                guard index + 1 < words.endIndex else { throw UsageError.missing("a word after --") }
                positionals += 1
                index += 2
                continue
            }
            if word.hasPrefix("--"), spec.valued.contains(String(word.dropFirst(2))) {
                guard index + 1 < words.endIndex else { throw UsageError.missing("value for \(word)") }
                if words[index + 1] == "--" {
                    guard index + 2 < words.endIndex else { throw UsageError.missing("value for \(word) after --") }
                    index += 3
                } else {
                    index += 2
                }
                continue
            }
            if !word.hasPrefix("--") { positionals += 1 }
            index += 1
        }
        return nil
    }

    static func parse(_ words: ArraySlice<String>, spec: OptionSpec) throws -> Parsed {
        var parsed = Parsed()
        var index = words.startIndex
        /// The word at `index`, taken as typed when it is `--`'s escape.
        func literal(after escape: Int, meaning: String) throws -> String {
            guard escape + 1 < words.endIndex else { throw UsageError.missing("\(meaning) after --") }
            return words[escape + 1]
        }
        while index < words.endIndex {
            let word = words[index]
            if word == "--" {
                parsed.positionals.append(try literal(after: index, meaning: "a word"))
                index += 2
                continue
            }
            guard word.hasPrefix("--") else {
                parsed.positionals.append(word)
                index += 1
                continue
            }
            let name = String(word.dropFirst(2))
            let isValued = spec.valued.contains(name)
            guard isValued || spec.flags.contains(name) else {
                throw UsageError.invalid(option: name, value: "",
                                         expected: spec.names.isEmpty ? "no option here" : "one of \(spec.names)")
            }
            let seen = parsed.flags.contains(name) || parsed.values[name] != nil
            guard !seen || spec.repeatable.contains(name) else {
                throw UsageError.invalid(option: name, value: "", expected: "it once")
            }
            guard isValued else {
                parsed.flags.insert(name)
                index += 1
                continue
            }
            guard index + 1 < words.endIndex else { throw UsageError.missing("value for --\(name)") }
            let next = words[index + 1]
            if next == "--" {
                parsed.values[name, default: []].append(try literal(after: index + 1, meaning: "value for --\(name)"))
                index += 3
            } else {
                guard !next.hasPrefix("--") else { throw UsageError.missing("value for --\(name)") }
                parsed.values[name, default: []].append(next)
                index += 2
            }
        }
        return parsed
    }
}

/// UsageError is a command line that cannot be acted on.
enum UsageError: Error, CustomStringConvertible, Equatable {

    case missing(String)
    case invalid(option: String, value: String, expected: String)
    case noSuchApplication(String)
    case windowSelection(title: String, count: Int, available: [String])

    var description: String {
        switch self {
            case .missing(let meaning):
                "missing \(meaning); run `mecum help`"
            case .invalid(let option, let value, let expected):
                "--\(option) \(value): expected \(expected)"
            case .noSuchApplication(let word):
                "no running application matches '\(word)' by bundle id or name"
            case .windowSelection(let title, let count, let available):
                "--window \(title): "
                    + (count == 0 ? "no open window has that title. Open the requested window first, then rerun."
                        : "\(count) open windows share that title; the target must be unique.")
                    + " Available windows: " + (available.isEmpty ? "none" : available.joined(separator: ", "))
        }
    }
}
