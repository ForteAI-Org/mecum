//
//  Invocation.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

/// Invocation is the parsed command line: the subcommand, its positional words, and `--name value`
/// or `--flag` options. Parsing is by shape only; each command reads what it needs and complains
/// about what it lacks.
struct Invocation {

    let arguments: [String]
    let command: String?
    let positionals: [String]
    let options: [String: String]
    let flags: Set<String>

    /// Option names that take a value; anything else starting with `--` is a flag.
    private static let valued: Set<String> = ["verb", "value", "section", "knowledge", "evidence", "window", "expect-window"]

    init(arguments: [String]) {
        self.arguments = arguments
        var positionals: [String] = []
        var options: [String: String] = [:]
        var flags: Set<String> = []
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            if word.hasPrefix("--") {
                let name = String(word.dropFirst(2))
                if Self.valued.contains(name), index + 1 < arguments.count {
                    options[name] = arguments[index + 1]
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
        self.flags       = flags
    }

    /// The positional at `index`, or a usage error naming what is missing.
    func positional(_ index: Int, _ meaning: String) throws -> String {
        guard positionals.count > index else { throw UsageError.missing(meaning) }
        return positionals[index]
    }
}

/// UsageError is a command line that cannot be acted on.
enum UsageError: Error, CustomStringConvertible {

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
