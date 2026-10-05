import ChatCore
import Foundation
import ModelTransports

/// ChatOptions parses only the chat surface; quoted prompts are preserved as a single value.
///
/// `role`, `effort` and `webSearch` configure the turns of this invocation the way a worker's
/// configuration does in the app, and belong to the invocation alone: a saved conversation keeps none of
/// them, so a chat resumed with `--resume` is given them again. Their defaults are the chat's of old:
/// no role, the command line's own effort, no web search.
struct ChatOptions {
    var provider: ChatProvider?
    var model: String?
    var hasModelOption = false
    var resume: String?
    var prompt: String?
    var historyDirectory: String?
    var knowledgeDirectory: String?
    var once = false
    var list = false
    var help = false
    var allowUnvalidated = false
    var allowDestructive = false

    /// The agent's role, the exact text given; the turn core trims it as it does a worker's.
    var role: String?

    /// The reasoning effort asked for, nil for the command line's default (`--effort default`, or none).
    var effort: ReasoningEffort?
    var hasEffortOption = false

    /// Whether the command line may search the web and read pages with its own tools.
    var webSearch = false

    /// Where a developer's diagnosis of every `select` goes (`--diagnose-select`); nil, the default, for none.
    var selectDiagnostics: String?

    init(arguments: [String]) throws {
        var index = 0
        var seen = Set<String>()
        while index < arguments.count {
            let word = arguments[index]
            if word == "--" {
                let remaining = Array(arguments.dropFirst(index + 1))
                guard remaining.count == 1, prompt == nil else { throw invalid("Expected one quoted prompt after --.") }
                prompt = remaining[0]
                break
            }
            if !word.hasPrefix("--") {
                guard prompt == nil else { throw invalid("Wrap the prompt in quotes.") }
                prompt = word
                index += 1
                continue
            }
            guard seen.insert(word).inserted else { throw invalid("Duplicate option: \(word)") }
            switch word {
            case "--once": once = true
            case "--list": list = true
            case "--help": help = true
            case "--allow-unvalidated-build": allowUnvalidated = true
            case "--allow-destructive": allowDestructive = true
            case "--web-search": webSearch = true
            case "--provider", "--model", "--resume", "--history-dir", "--knowledge", "--role", "--effort",
                 "--diagnose-select":
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("--"), !arguments[index].isEmpty else {
                    throw invalid("Missing value for \(word).")
                }
                let value = arguments[index]
                switch word {
                case "--provider":
                    guard let selected = ChatProvider(rawValue: value == "gpt" || value == "openai" ? "codex" : value) else {
                        throw invalid("--provider must be claude or codex.")
                    }
                    provider = selected
                case "--model":
                    model = value == "default" ? nil : value
                    hasModelOption = true
                case "--resume": resume = value
                case "--history-dir": historyDirectory = value
                case "--diagnose-select": selectDiagnostics = value
                case "--role":
                    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw invalid("--role needs the role's text.")
                    }
                    role = value
                case "--effort":
                    hasEffortOption = true
                    if value == "default" {
                        effort = nil
                    } else {
                        guard let level = ReasoningEffort(rawValue: value) else {
                            throw invalid("--effort must be one of \(Self.effortLevels), or default.")
                        }
                        effort = level
                    }
                default: knowledgeDirectory = value
                }
            default: throw invalid("Unknown chat option: \(word)")
            }
            index += 1
        }
        if once && prompt == nil { throw invalid("--once requires a quoted prompt.") }
        if list && (prompt != nil || resume != nil) { throw invalid("--list cannot send or resume a conversation.") }
    }

    /// The levels `--effort` takes, the one domain `ModelSelection` defines; which of them a provider and
    /// model accept is `ModelSelection.supportedEfforts`, checked before the first turn.
    static let effortLevels = ReasoningEffort.allCases.map(\.rawValue).joined(separator: "|")

    private func invalid(_ text: String) -> NSError {
        NSError(domain: "MecumChat", code: 2, userInfo: [NSLocalizedDescriptionKey: text])
    }

    static let usage = """
    mecum --chat [\"prompt\"] [options]
    mecum chat [\"prompt\"] [options]

      --provider claude|codex       use the installed, signed-in provider CLI
      --model <name>                provider model ID/alias; default uses the provider default
      --resume <UUID|last>          resume a saved Mecum conversation
      --list                       list saved conversations
      --once                       send the quoted prompt and exit
      --history-dir <directory>    override transcript storage
      --knowledge <directory>      override Mecum's application memory
      --allow-unvalidated-build    explicit Driver research opt-in
      --allow-destructive          allow Engine targets classified as destructive

    Turn configuration, as a worker's in the Mecum app (these belong to this invocation: a saved
    conversation keeps none of them, so give them again with --resume):
      --role <text>                the agent's role, added after Mecum's instructions; default none
      --effort <\(effortLevels)|default>
                                   the reasoning effort; default leaves the provider's own. A level the
                                   provider or model does not offer is refused before the first turn,
                                   and said again after /model changes the model. With the provider's
                                   default model only the known contract is checked.
      --web-search                 let the command line search the web and read pages with its own
                                   tools; default off

    Developer diagnosis (off by default):
      --diagnose-select <directory>
                                   for every select, write the images the selector perceived
                                   (before.png, menu.png, after.png) and diagnosis.json (the typed reason
                                   a selection did not happen, the labels and rows it read) under
                                   <directory>/<call id>/. They are pictures of the driven app's windows:
                                   use a temporary directory you name. Nothing goes to the memory.

    Interactive: /help, /model, /status, /usage, /compact, /release, /quit
    /usage shows what the provider reported each turn cost and the context it left (unknown is said as
    unknown, never 0); /compact compacts the provider session's context as the Mecum app does (no tool,
    no Seat). Both are kept for this chat process; the transcript keeps their usage: and compaction:
    lines, but a resumed conversation starts with no usage, so a resumed Codex session's first turn
    has an unknown own count.
    Ctrl+C stops the turn, releases the Seat, and saves the conversation for --resume.
    Chat defaults to background Seat actions. No foreground fallback.
    The chat drives apps through the same broker session as the Mecum app: open_session also launches
    an installed app that is not running (apps lists them, and a launched app is quit when the session
    ends). The Seat is given back 30 s after a turn with no next turn, or at once with /release; the
    next turn opens a session again.
    macOS permissions still belong to the terminal launching Mecum.
    """
}
