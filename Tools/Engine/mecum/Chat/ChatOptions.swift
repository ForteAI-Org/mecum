import ChatCore
import Foundation

/// ChatOptions parses only the chat surface; quoted prompts are preserved as a single value.
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
            case "--provider", "--model", "--resume", "--history-dir", "--knowledge":
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
                default: knowledgeDirectory = value
                }
            default: throw invalid("Unknown chat option: \(word)")
            }
            index += 1
        }
        if once && prompt == nil { throw invalid("--once requires a quoted prompt.") }
        if list && (prompt != nil || resume != nil) { throw invalid("--list cannot send or resume a conversation.") }
    }

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

    Interactive: /help, /model, /status, /release, /quit
    Ctrl+C stops the turn, releases the Seat, and saves the conversation for --resume.
    Chat defaults to background Seat actions. No foreground fallback.
    macOS permissions still belong to the terminal launching Mecum.
    """
}
