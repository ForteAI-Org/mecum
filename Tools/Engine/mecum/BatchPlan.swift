import EngineCore
import Foundation

/// BatchPlan validates the whole sequence before any UI work. Shell tokenization preserves labels;
/// this parser never evaluates a shell string. A batch stays in one explicitly named window.
struct BatchPlan {

    let invocation: Invocation
    let application: String
    let steps: [BatchStep]

    init(arguments: [String]) throws {
        guard let boundary = arguments.firstIndex(of: "--") else {
            throw UsageError.missing("-- before the first batch step")
        }
        let header = Array(arguments[..<boundary])
        try Self.validateOptions(header, valued: ["window", "knowledge", "evidence"],
                                 flags: ["seat", "allow-unvalidated-build", "allow-destructive"])
        let invocation = Invocation(arguments: header)
        guard invocation.command == "batch", invocation.positionals.count == 1 else {
            throw UsageError.missing("batch <app> [options] -- <steps>")
        }
        guard invocation.flags.contains("seat") else { throw UsageError.missing("--seat for batch") }
        guard invocation.options["window"] != nil else { throw UsageError.missing("--window <title> for batch") }
        self.invocation = invocation
        application = try invocation.positional(0, "<app>")
        let groups = arguments[(boundary + 1)...].split(separator: "--then", omittingEmptySubsequences: false)
        steps = try groups.map { group in
            let words = Array(group)
            guard let command = words.first, command == "select" || command == "act" else {
                throw UsageError.missing("select <dropdown> <item> or act <target> after -- / --then")
            }
            try Self.validateOptions(words, valued: command == "act" ? ["verb", "value", "section"] : [], flags: [])
            let step = Invocation(arguments: words)
            switch command {
                case "select":
                    guard step.positionals.count == 2 else {
                        throw UsageError.missing("select <dropdown> <item> (app is specified once for the batch)")
                    }
                    return .select(control: step.positionals[0], item: step.positionals[1])
                default:
                    guard step.positionals.count == 1 else {
                        throw UsageError.missing("act <target> (app is specified once for the batch)")
                    }
                    let action = try ActArguments(step, targetIndex: 0)
                    guard step.options["value"] == nil || action.verb == .setToggle else {
                        throw UsageError.invalid(option: "value", value: step.options["value"] ?? "",
                                                 expected: "--verb set_toggle")
                    }
                    return .act(action)
            }
        }
    }

    /// Rejects misspellings, duplicate options, missing values and options in the wrong scope.
    private static func validateOptions(_ words: [String], valued: Set<String>, flags: Set<String>) throws {
        var seen: Set<String> = []
        var index = 0
        while index < words.count {
            let word = words[index]
            guard !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw UsageError.missing("a nonempty app, window or target")
            }
            if word.hasPrefix("--") {
                let name = String(word.dropFirst(2))
                guard valued.contains(name) || flags.contains(name), seen.insert(name).inserted else {
                    throw UsageError.invalid(option: name, value: "", expected: "a supported, non-repeated option in this scope")
                }
                if valued.contains(name) {
                    guard index + 1 < words.count, !words[index + 1].hasPrefix("--"),
                          !words[index + 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw UsageError.missing("value for --\(name)")
                    }
                    index += 1
                }
            }
            index += 1
        }
    }
}

/// BatchStep is one validated operation, without its own Seat or application lifetime.
enum BatchStep {
    case select(control: String, item: String)
    case act(ActArguments)

    var summary: String {
        switch self {
            case .select(let control, let item): "select '\(control)' → '\(item)'"
            case .act(let action): "\(action.verb.rawValue) '\(action.target)'"
        }
    }

    func accepts(_ kind: ActOutcomeKind) -> Bool {
        if kind == .foundActed { return true }
        // Only set_toggle's verified "already in the requested state" is a completed no-op.
        if case .act(let action) = self, action.verb == .setToggle, kind == .actedNoop { return true }
        return false
    }
}
