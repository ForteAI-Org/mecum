//
//  SlashCommandTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/09/2026.
//

import Foundation
import ModelTransports
import Testing
@testable import Mecum

/// Claude Code's catalogue as the command line lists it, by id.
private let claudeModels = [
    "claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-4-5",
    "claude-fable-5", "claude-opus-5", "claude-sonnet-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5",
    "claude-sonnet-4-6", "claude-sonnet-4-5",
]

/// Atlas on Claude's Sonnet, free, with nothing shown but the composer.
private func context(
    answering : Bool = false,
    compacting: Bool = false
) -> SlashCommandContext {
    SlashCommandContext(
        worker      : "Atlas",
        isAnswering : answering || compacting,
        isCompacting: compacting,
        selection   : ModelSelection(
            provider: .claudeCode,
            model   : "claude-sonnet-5",
            effort  : .low
        ),
        catalogue   : claudeModels.map {
            ModelInfo(
                id     : $0,
                title  : $0.replacingOccurrences(
                    of  : "-",
                    with: " "
                ).capitalized,
                efforts: ModelSelection.supportedEfforts(
                    provider: .claudeCode,
                    model   : $0
                )
            )
        }
    )
}

/// The titles of the rows `draft` suggests in `context`.
private func titles(
    _ draft   : String,
    in context: SlashCommandContext = context()
) -> [String] {
    SlashCommandSuggestions(
        draft  : draft,
        context: context
    ).rows.map(\.title)
}

@Suite("Slash commands")
struct SlashCommandTests {

    // MARK: Parsing

    @Test("A known name is a command whatever its case, with what follows as its argument")
    func knownNames() {
        #expect(SlashCommandInvocation(draft: "/compact") == SlashCommandInvocation(.compact))
        #expect(SlashCommandInvocation(draft: "  /Model   Claude-Opus-5 \n") == SlashCommandInvocation(
            .model,
            argument: "Claude-Opus-5"
        ))
        #expect(SlashCommandInvocation(draft: "/SCREEN inspector")?.command == .screen)
        #expect(SlashCommandInvocation(draft: "/compact extra") == SlashCommandInvocation(
            .compact,
            argument: "extra"
        ))
    }

    @Test("A path, an unknown name, a doubled slash and plain text are messages")
    func messages() {
        for draft in ["/Users/me/file", "/compactly", "/", "//compact", "hello /compact", "compact"] {
            #expect(SlashCommandInvocation(draft: draft) == nil, "\(draft)")
        }
        #expect(SlashCommandInvocation.messageText("//compact") == "/compact")
        #expect(SlashCommandInvocation.messageText("/Users/me") == "/Users/me")
        #expect(SlashCommandInvocation.messageText("hello") == "hello")
    }

    // MARK: Actions

    @Test("A command with no argument given one does not run, /compact above all")
    func extraTextDoesNotRun() {
        let free = context()
        #expect(free.action(for: SlashCommandInvocation(
            .new,
            argument: "please"
        )) == nil)

        var ringed = free
        ringed.showsRing = true
        #expect(ringed.action(for: SlashCommandInvocation(.compact)) == .compact)
        #expect(ringed.action(for: SlashCommandInvocation(
            .compact,
            argument: "keep the plan"
        )) == nil)
    }

    @Test("/model and /effort keep a choice as the model popup does; /model alone opens it")
    func modelAndEffort() throws {
        let free = context()
        #expect(free.action(for: SlashCommandInvocation(.model)) == .chooseModel)
        #expect(free.action(for: SlashCommandInvocation(
            .model,
            argument: "CLAUDE-OPUS-5"
        )) == .select(ModelSelection(
            provider: .claudeCode,
            model   : "claude-opus-5",
            effort  : .low
        )))
        #expect(free.action(for: SlashCommandInvocation(
            .model,
            argument: "Claude Opus 5"
        )) == .select(ModelSelection(
            provider: .claudeCode,
            model   : "claude-opus-5",
            effort  : .low
        )), "a model is found by its name too")
        #expect(free.action(for: SlashCommandInvocation(
            .model,
            argument: "gpt-5"
        )) == nil)

        #expect(free.action(for: SlashCommandInvocation(
            .effort,
            argument: "High"
        )) == .select(ModelSelection(
            provider: .claudeCode,
            model   : "claude-sonnet-5",
            effort  : .high
        )))
        #expect(free.action(for: SlashCommandInvocation(.effort)) == nil, "a level is needed")
        #expect(free.action(for: SlashCommandInvocation(
            .effort,
            argument: "ultra"
        )) == nil, "Sonnet does not offer it")

        var haiku = free
        haiku.selection?.model = "claude-haiku-4-5"
        #expect(haiku.availability(of: .effort) == .unavailable(reason: "This model doesn’t offer Effort levels."))

        var ollama = free
        ollama.selection = ModelSelection(
            provider: .ollama,
            model   : "qwen3",
            effort  : .high
        )
        ollama.catalogue = nil
        #expect(ollama.action(for: SlashCommandInvocation(
            .effort,
            argument: "no thinking"
        )) == .select(ModelSelection(
            provider: .ollama,
            model   : "qwen3",
            effort  : .low
        )), "a level is found by the name the provider gives it")
    }

    @Test("/screen alone moves the screen to the other place, and a place moves it there")
    func screen() {
        var watched = context()
        watched.hasScreen = true
        #expect(watched.action(for: SlashCommandInvocation(.screen)) == .showScreen(inConversation: true))
        #expect(watched.action(for: SlashCommandInvocation(
            .screen,
            argument: "Inspector"
        )) == .showScreen(inConversation: false))
        #expect(watched.action(for: SlashCommandInvocation(
            .screen,
            argument: "desktop"
        )) == nil)

        watched.showsScreenInConversation = true
        #expect(watched.action(for: SlashCommandInvocation(.screen)) == .showScreen(inConversation: false))
    }

    // MARK: Availability

    @Test("While the worker answers, what acts on its context or model waits, with the context popover's reason")
    func whileAnswering() {
        let answering = context(answering: true)
        let reason    = "Available when Atlas finishes responding."
        for command in [SlashCommand.compact, .new, .model, .effort] {
            #expect(answering.availability(of: command) == .unavailable(reason: reason), "\(command)")
            #expect(answering.action(for: SlashCommandInvocation(command)) == nil, "\(command)")
        }
        #expect(answering.action(for: SlashCommandInvocation(.stop)) == .stop)

        let compacting = context(compacting: true)
        #expect(compacting.availability(of: .new) == .unavailable(reason: "Available when compacting finishes."))
    }

    @Test("/stop, /release, /screen, /usage and /context are listed only when they apply")
    func listedOnlyWhenTheyApply() {
        let free = context()
        #expect(titles("/") == ["/compact", "/new", "/model", "/effort"])
        #expect(free.availability(of: .compact) == .unavailable(reason: "Available once the context’s size is known."))
        #expect(free.action(for: SlashCommandInvocation(.stop)) == nil)

        var everything = context(answering: true)
        everything.holdsComputer = true
        everything.hasScreen     = true
        everything.showsCounter  = true
        everything.showsRing     = true
        #expect(titles(
            "/",
            in: everything
        ) == SlashCommand.allCases.map(\.name))

        var unconfigured = free
        unconfigured.selection = nil
        #expect(unconfigured.availability(of: .model) == .unavailable(reason: "Available once Atlas has a model."))
    }

    // MARK: Suggestions

    @Test("Names that start with what is typed come first, then those holding its letters in order")
    func filteringAndOrder() {
        #expect(titles("/cmp") == ["/compact"])
        #expect(titles("/e") == ["/effort", "/new", "/model"])
        #expect(titles("/MO") == ["/model"])
        #expect(titles("/zz").isEmpty)
        #expect(titles("//").isEmpty)
        #expect(titles("/Users/me/file").isEmpty)
        #expect(titles("/Users/me file").isEmpty)
        #expect(titles("hello").isEmpty)
        #expect(titles("/compact ") == ["/compact"])
        #expect(titles("/compact now") == ["/compact"], "greyed, since it takes no argument")
    }

    @Test("Each row says what Tab puts in the draft, whether Return runs it, and why it waits")
    func commandRows() throws {
        let rows = SlashCommandSuggestions(
            draft  : "/",
            context: context(answering: true)
        ).rows
        let compact = try #require(rows.first)
        #expect(compact.symbol == "arrow.down.right.and.arrow.up.left")
        #expect(compact.summary == "Compact the context")
        #expect(compact.argumentHint == nil)
        #expect(compact.completion == "/compact")
        #expect(compact.runsOnReturn)
        #expect(compact.unavailableReason == "Available when Atlas finishes responding.")

        let model = try #require(rows.first { $0.id == "model" })
        #expect(model.argumentHint == "‹name›")
        #expect(model.completion == "/model ")
        #expect(model.runsOnReturn, "alone it opens the model popup")

        let effort = try #require(rows.first { $0.id == "effort" })
        #expect(effort.completion == "/effort ")
        #expect(!effort.runsOnReturn, "Return completes it, since it needs a level")

        let stop = try #require(rows.first { $0.id == "stop" })
        #expect(stop.unavailableReason == nil)
    }

    @Test("After /model, /effort and /screen with a space, the rows are the models, the levels and the places")
    func argumentRows() throws {
        #expect(titles("/model ").count == claudeModels.count)
        #expect(titles("/model sonnet") == ["Claude Sonnet 5 5", "Claude Sonnet 5", "Claude Sonnet 4 6", "Claude Sonnet 4 5"])
        #expect(titles("/model hk") == ["Claude Haiku 4 5"], "letters in order match too")

        let sonnet = try #require(SlashCommandSuggestions(
            draft  : "/model claude-sonnet-5",
            context: context()
        ).rows.first)
        #expect(sonnet.isCurrent)
        #expect(sonnet.completion == "/model claude-sonnet-5")
        #expect(sonnet.runsOnReturn)

        #expect(titles("/effort ") == ["Low", "Medium", "High", "XHigh", "Max"])
        #expect(titles("/effort h") == ["High", "XHigh"])
        #expect(SlashCommandSuggestions(
            draft  : "/effort ",
            context: context()
        ).rows.first?.isCurrent == true)

        var watched = context()
        watched.hasScreen = true
        #expect(titles(
            "/screen ",
            in: watched
        ) == ["Conversation", "Inspector"])
        #expect(SlashCommandSuggestions(
            draft  : "/screen i",
            context: watched
        ).rows.map(\.completion) == ["/screen inspector", "/screen conversation"])
        #expect(titles("/screen ") == ["/screen"], "no screen, no places: the command alone, greyed")
    }

    @Test("A known command given an argument it cannot take lists its own row, greyed with why")
    func refusedArguments() throws {
        func refused(
            _ draft   : String,
            in context: SlashCommandContext = context()
        ) throws -> SlashCommandSuggestions.Row {
            let rows = SlashCommandSuggestions(
                draft  : draft,
                context: context
            ).rows
            try #require(rows.count == 1, "\(draft)")
            return rows[0]
        }

        let compact = try refused("/compact now")
        #expect(compact.id == "compact")
        #expect(compact.title == "/compact")
        #expect(compact.unavailableReason == "/compact takes no argument.")
        #expect(try refused("/new x").unavailableReason == "/new takes no argument.")
        #expect(try refused("/model nosuchmodel").unavailableReason == "No model named “nosuchmodel”.")
        #expect(try refused("/model nosuchmodel").id == "model")
        #expect(try refused("/effort extreme").unavailableReason == "No level named “extreme”.")

        var watched = context()
        watched.hasScreen = true
        #expect(try refused(
            "/screen desktop",
            in: watched
        ).unavailableReason == "No place named “desktop”.")

        // A list not known yet, or empty, says why the command waits.
        var haiku = context()
        haiku.selection?.model = "claude-haiku-4-5"
        #expect(try refused(
            "/effort high",
            in: haiku
        ).unavailableReason == "This model doesn’t offer Effort levels.")
        #expect(try refused(
            "/effort ",
            in: haiku
        ).unavailableReason == "This model doesn’t offer Effort levels.")

        var unlisted = context()
        unlisted.catalogue = nil
        #expect(try refused(
            "/model opus",
            in: unlisted
        ).unavailableReason == "Available once the models are listed.")
        let alone = try refused(
            "/model ",
            in: unlisted
        )
        #expect(alone.unavailableReason == nil, "alone it still opens the model popup")
        #expect(alone.runsOnReturn)

        // While the worker answers, the argument is still what keeps it from running.
        #expect(try refused(
            "/compact now",
            in: context(answering: true)
        ).unavailableReason == "/compact takes no argument.")
    }

    @Test("A command that does not apply now, named in full, lists its own row greyed with why; a prefix hides it")
    func unlistedNamedInFull() throws {
        let idle     = context()
        let expected = [
            ("/stop", "Available while Atlas is responding."),
            ("/release", "Available while Atlas holds the computer."),
            ("/screen", "Available once Atlas has a screen."),
            ("/usage", "Available once Atlas has used tokens."),
            ("/context", "Available once the context’s size is known."),
        ]
        for (draft, reason) in expected {
            for typed in [draft, draft.uppercased(), draft + " ", draft + " now"] {
                let rows = SlashCommandSuggestions(
                    draft  : typed,
                    context: idle
                ).rows
                let row  = try #require(rows.first, "\(typed)")
                #expect(row.title == draft, "\(typed)")
                #expect(row.unavailableReason == reason, "\(typed)")
                #expect(rows.count == 1, "\(typed)")
            }
        }

        for prefix in ["/sto", "/rel", "/scr", "/usa", "/conte"] {
            #expect(titles(prefix).isEmpty, "\(prefix)")
        }
        #expect(titles("/co") == ["/compact"], "/context stays hidden behind a prefix")

        var answering = context(answering: true)
        answering.showsRing = true
        #expect(SlashCommandSuggestions(
            draft  : "/stop",
            context: answering
        ).rows.first?.unavailableReason == nil, "listed, it runs")
        #expect(SlashCommandSuggestions(
            draft  : "/context",
            context: answering
        ).rows.map(\.title) == ["/context"], "listed, it is not shown twice")
    }
}
