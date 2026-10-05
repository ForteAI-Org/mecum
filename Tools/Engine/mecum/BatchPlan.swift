import AutomationMCP
import EngineCore
import Foundation
import Memory

/// BatchPlan validates the whole sequence before any UI work: the header, then every step through
/// the tools' decoder (`ActionGrammar`), so a step that would be refused anywhere stops the batch
/// before its first effect. Shell tokenization preserves labels; this parser never evaluates a shell
/// string. A batch stays in one explicitly named window.
///
/// The header comes first (`batch <app> --window <title> --seat ...`), read by the same grammar as
/// every command, so an escape in it stays an escape: `--window -- --Window` is the title `--Window`,
/// and `batch -- --App` the application `--App`. The first `--` that is not such an escape ends the
/// header (`Words.headerEnd`); the steps follow, separated by each `--then` that is not escaped.
/// Inside a step, `--` makes the next word literal, so a label or a text `--then` is `-- --then`.
struct BatchPlan {

    let invocation: Invocation
    let application: String
    let steps: [BatchStep]

    init(arguments: [String]) throws {
        guard let boundary = try Words.headerEnd(arguments.dropFirst(), spec: CommandSpecs.batch, requiredPositionals: 1) else {
            throw UsageError.missing("-- before the first batch step")
        }
        let invocation = try Invocation(arguments: Array(arguments[..<boundary]), spec: CommandSpecs.batch)
        guard invocation.command == "batch", invocation.positionals.count == 1 else {
            throw UsageError.missing("batch <app> [options] -- <steps>")
        }
        guard invocation.flags.contains("seat") else { throw UsageError.missing("--seat for batch") }
        guard let window = invocation.options["window"] else { throw UsageError.missing("--window <title> for batch") }
        for word in [invocation.positionals[0], window] + invocation.values.values.flatMap({ $0 })
            where word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw UsageError.missing("a nonempty app, window or option value")
        }
        self.invocation = invocation
        application = invocation.positionals[0]
        steps = try Self.groups(Array(arguments[(boundary + 1)...])).enumerated().map { index, words in
            do {
                return BatchStep(request: try ActionGrammar.step(words))
            } catch {
                throw BatchPlanError(step: index + 1, cause: error)
            }
        }
    }

    /// The steps' words, split at each `--then` that is not escaped by `--`.
    static func groups(_ words: [String]) -> [[String]] {
        var groups: [[String]] = [[]]
        var index = 0
        while index < words.count {
            let word = words[index]
            if word == "--" {
                groups[groups.count - 1].append(word)
                if index + 1 < words.count { groups[groups.count - 1].append(words[index + 1]) }
                index += 2
                continue
            }
            if word == "--then" { groups.append([]) } else { groups[groups.count - 1].append(word) }
            index += 1
        }
        return groups
    }
}

/// BatchPlanError is a step the plan refused, by its number, with the reason.
struct BatchPlanError: Error, CustomStringConvertible {
    let step: Int
    let cause: any Error

    var description: String { "batch step \(step): \(cause). Nothing was run." }
}

/// BatchStep is one validated operation, as the tools' decoder read it, without its own Seat or
/// application lifetime.
struct BatchStep {

    let request: AgentCallRequest

    var summary: String { CallText.request(request) }

    /// The tools' rule: `found_acted`, or `acted_noop` for `set_toggle`.
    func accepts(_ kind: ActOutcomeKind) -> Bool { request.accepts(kind) }
}
