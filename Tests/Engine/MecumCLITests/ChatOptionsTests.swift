import Foundation
import ChatCore
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
    }

    @Test(arguments: [
        ["--provider", "unknown"], ["--model"], ["--once"], ["two", "words"],
        ["--provider", "claude", "--provider", "codex"], ["--unknown"],
        ["--list", "do something"], ["--list", "--resume", "last"]
    ])
    func invalidArgumentsCannotLaunchAProvider(_ args: [String]) {
        #expect(throws: (any Error).self) { _ = try ChatOptions(arguments: args) }
    }

    @Test
    func delimiterAllowsPromptThatLooksLikeAnOption() throws {
        let options = try ChatOptions(arguments: ["--provider", "claude", "--", "--remember this"])
        #expect(options.prompt == "--remember this")
    }
}
