import Foundation
import ChatCore
import ModelTransports
import Testing
@testable import mecum

@Suite("Chat command parsing")
struct ChatOptionsTests {
    @Test
    func promptAndResumeAreKeptLiteral() throws {
        let options = try ChatOptions(arguments: [
            "click \"New Path...\"; $(not a shell)", "--provider", "gpt",
            "--model", "chosen-model", "--resume", "last", "--once"
        ])
        #expect(options.provider?.rawValue == "codex")
        #expect(options.model == "chosen-model")
        #expect(options.resume == "last")
        #expect(options.prompt == "click \"New Path...\"; $(not a shell)")
        #expect(options.once)
        // The turn configuration keeps the chat's defaults when nothing asks otherwise.
        #expect(options.role == nil)
        #expect(options.effort == nil && !options.hasEffortOption)
        #expect(!options.webSearch)
    }

    @Test(arguments: [
        ["--provider", "unknown"], ["--model"], ["--once"], ["two", "words"],
        ["--provider", "claude", "--provider", "codex"], ["--unknown"],
        ["--list", "do something"], ["--list", "--resume", "last"],
        ["--effort", "turbo"], ["--effort"], ["--role"], ["--role", "  \n"],
        ["--effort", "high", "--effort", "low"], ["--web-search", "--web-search"], ["--role", "--web-search"]
    ])
    func invalidArgumentsCannotLaunchAProvider(_ args: [String]) {
        #expect(throws: (any Error).self) { _ = try ChatOptions(arguments: args) }
    }

    @Test
    func delimiterAllowsPromptThatLooksLikeAnOption() throws {
        let options = try ChatOptions(arguments: ["--provider", "claude", "--", "--remember this"])
        #expect(options.prompt == "--remember this")
    }

    /// The turn configuration a worker has in the app: the role's exact text, a level of the one effort
    /// domain, and web search; `default` is the command line's own effort, said explicitly.
    @Test
    func roleEffortAndWebSearchAreParsedWithTheirDefaults() throws {
        let options = try ChatOptions(arguments: [
            "hello", "--provider", "claude", "--role", "  Edit video. ", "--effort", "high", "--web-search"
        ])
        #expect(options.role == "  Edit video. ", "the exact text; the turn core trims it")
        #expect(options.effort == .high && options.hasEffortOption)
        #expect(options.webSearch)
        #expect(options.prompt == "hello")

        let explicitDefault = try ChatOptions(arguments: ["--provider", "codex", "--effort", "default"])
        #expect(explicitDefault.effort == nil && explicitDefault.hasEffortOption)
        for level in ReasoningEffort.allCases {
            #expect(try ChatOptions(arguments: ["--effort", level.rawValue]).effort == level)
        }
        #expect(ChatOptions.effortLevels == "low|medium|high|xhigh|max|ultra")
        for word in ["--role <text>", "--effort <low|medium|high|xhigh|max|ultra|default>", "--web-search",
                     "give them again with --resume", "/model"] {
            #expect(ChatOptions.usage.contains(word), "\(word)")
        }
    }
}
