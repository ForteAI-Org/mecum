//
//  SlashCommandSuggestions.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/09/2026.
//

import Foundation
import ModelTransports

/// SlashCommandContext is what the commands are read against: the open
/// conversation's worker as it is now. It decides which commands are listed,
/// which of those can run and why the others wait, and what a command asks
/// for once it runs, so the popup and `TeamModel.send` cannot disagree.
nonisolated struct SlashCommandContext: Equatable {

    /// The worker's name, which the reasons say.
    var worker: String

    /// A turn or a compaction is running; `isCompacting` says which.
    var isAnswering               = false
    var isCompacting              = false
    var holdsComputer             = false
    var hasScreen                 = false
    var showsScreenInConversation = false

    /// The toolbar's token counter and the composer's context ring are shown.
    var showsCounter = false
    var showsRing    = false

    /// The worker's model and effort, nil while it has none.
    var selection: ModelSelection?

    /// The provider's catalogue, nil while it has not been listed yet.
    var catalogue: [ModelInfo]?

    /// Why `/compact` waits, and why `/context` does not apply, while the ring is not shown.
    static let sizeUnknown = "Available once the context’s size is known."

    /// Whether a command is offered now.
    enum Availability: Equatable {

        case available

        /// Listed greyed, with why it waits.
        case unavailable(reason: String)

        /// Not listed at all: it does not apply now.
        case unlisted

        /// Why it waits, nil unless it does.
        var reason: String? {
            if case .unavailable(let reason) = self { return reason }
            return nil
        }
    }

    /// What a command asks for once it runs.
    enum Action: Equatable {

        case compact

        case startFresh

        /// Opens the model popup, as the model button does.
        case chooseModel

        /// Keeps a model or an effort, as the model popup's choice is kept.
        case select(ModelSelection)

        case stop

        case release

        case showScreen(inConversation: Bool)

        case showUsage

        case showContext
    }

    /// The levels the worker's model offers, as the model popup's slider shows them:
    /// its catalogue's, else the provider's for that model.
    var efforts: [ReasoningEffort] {
        guard let selection else { return [] }

        return catalogue?.first { $0.id == selection.model }?.efforts
            ?? ModelSelection.supportedEfforts(
                provider: selection.provider,
                model   : selection.model
            )
    }

    func availability(of command: SlashCommand) -> Availability {
        let busy = Availability.unavailable(reason: UsageWording.actionsWait(
            worker      : worker,
            isCompacting: isCompacting
        ))

        switch command {
        case .compact:
            if isAnswering { return busy }
            return showsRing ? .available : .unavailable(reason: Self.sizeUnknown)

        case .new:
            return isAnswering ? busy : .available

        case .model, .effort:
            if isAnswering { return busy }
            guard selection != nil else { return .unavailable(reason: "Available once \(worker) has a model.") }
            if command == .effort, efforts.isEmpty {
                return .unavailable(reason: "This model doesn’t offer Effort levels.")
            }
            return .available

        case .stop   : return isAnswering ? .available : .unlisted
        case .release: return holdsComputer ? .available : .unlisted
        case .screen : return hasScreen ? .available : .unlisted
        case .usage  : return showsCounter ? .available : .unlisted
        case .context: return showsRing ? .available : .unlisted
        }
    }

    /// What `invocation` does now, nil when it cannot run: its command is not
    /// available, or its argument is not one the command takes. `/model` alone
    /// opens the model popup and `/screen` alone moves the screen to the other
    /// place; `/effort` needs a level.
    func action(for invocation: SlashCommandInvocation) -> Action? {
        let command  = invocation.command
        let argument = invocation.argument
        guard availability(of: command) == .available else { return nil }
        if command.argument == .none, !argument.isEmpty { return nil }

        switch command {
        case .compact: return .compact
        case .new    : return .startFresh
        case .stop   : return .stop
        case .release: return .release
        case .usage  : return .showUsage
        case .context: return .showContext

        case .model:
            guard !argument.isEmpty else { return .chooseModel }
            return model(named: argument).flatMap(choosing).map(Action.select)

        case .effort:
            guard let selection, let effort = effort(named: argument) else { return nil }

            var chosen    = selection
            chosen.effort = effort
            return .select(chosen)

        case .screen:
            switch argument.lowercased() {
            case ""            : return .showScreen(inConversation: !showsScreenInConversation)
            case "conversation": return .showScreen(inConversation: true)
            case "inspector"   : return .showScreen(inConversation: false)
            default            : return nil
            }
        }
    }

    /// The catalogue's model whose id or name is `name`, whatever its case.
    func model(named name: String) -> ModelInfo? {
        catalogue?.first { Self.equal($0.id, name) || Self.equal($0.title, name) }
    }

    /// The model's level whose id or name for the provider is `name`, whatever its case.
    func effort(named name: String) -> ReasoningEffort? {
        guard let provider = selection?.provider else { return nil }

        return efforts.first { Self.equal($0.rawValue, name) || Self.equal($0.title(for: provider), name) }
    }

    /// The selection `model` makes, as the model popup chooses it: the effort
    /// stays when the model takes it, or the model has no levels, else the model's own.
    func choosing(_ model: ModelInfo) -> ModelSelection? {
        guard var chosen = selection else { return nil }

        chosen.model = model.id
        if !model.efforts.isEmpty, !model.efforts.contains(chosen.effort) { chosen.effort = model.startingEffort }
        return chosen
    }

    private static func equal(
        _ a: String,
        _ b: String
    ) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }
}

/// SlashCommandSuggestions is what the composer's popup lists for a draft:
/// while the draft names a command, the listed commands that match it; after
/// `/model `, `/effort ` or `/screen `, with the space, the models, the levels
/// or the two places that match what follows. A draft that starts with `//`,
/// or names no command before its first space, has none. A command given an
/// argument it cannot take, `/compact now` or `/model nosuchmodel`, lists its
/// own row greyed with why, and so does a command that does not apply now,
/// `/stop` while the worker is idle, once its name is typed in full, so
/// Return never does nothing unseen.
///
/// A row matches when its name starts with what is typed, or holds its letters
/// in order (`/cmp` finds `/compact`); those that start with it come first, and
/// each group keeps the order the rows are listed in.
nonisolated struct SlashCommandSuggestions: Equatable {

    /// One row of the popup, with all it draws and what Tab and Return do with it.
    struct Row: Equatable, Identifiable {

        /// The command's name, or the command and the argument: "model:claude-opus-5".
        let id               : String

        /// Nil for a model or a level, which the popup lists by name alone.
        let symbol           : String?

        /// "/compact", or the model's, level's or place's name.
        let title            : String

        /// What a command does, nil for an argument.
        let summary          : String?

        /// "‹name›" after a command that takes an argument, else nil.
        let argumentHint     : String?

        /// The worker's model, effort or screen place now.
        let isCurrent        : Bool

        /// Why it cannot run now, nil while it can. Return does nothing on a row that has one.
        let unavailableReason: String?

        /// What Tab puts in the draft: "/compact", "/model " to go on to the models,
        /// "/model claude-opus-5".
        let completion       : String

        /// Whether Return runs `completion` as a command. False for a command
        /// that needs an argument, `/effort`, which Return completes instead.
        let runsOnReturn     : Bool
    }

    let rows: [Row]

    init(
        draft  : String,
        context: SlashCommandContext
    ) {
        let text = draft.drop { $0.isWhitespace }
        guard text.hasPrefix("/"), !text.hasPrefix("//") else {
            rows = []
            return
        }

        let body = text.dropFirst()
        guard let space = body.firstIndex(where: \.isWhitespace) else {
            let listed = Self.matching(
                SlashCommand.allCases.filter { context.availability(of: $0) != .unlisted },
                query: body
            ) { [$0.rawValue] }
            .map { context.row($0) }

            // A command that does not apply now, named in full, shows first, greyed with why.
            guard let command = SlashCommand(named: body), let reason = context.whyUnlisted(command) else {
                rows = listed
                return
            }
            rows = [
                context.row(
                    command,
                    reason: reason
                ),
            ] + listed
            return
        }

        let query = body[space...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let command = SlashCommand(named: body[..<space]) else {
            rows = []
            return
        }

        if let reason = context.whyUnlisted(command) {
            rows = [
                context.row(
                    command,
                    reason: reason
                ),
            ]
            return
        }

        let reason = context.availability(of: command).reason
        let found: [Row]
        switch command.argument {
        case .none:
            found = query.isEmpty ? [context.row(command)] : []

        case .model:
            let current = context.selection?.model
            found = Self.matching(
                context.catalogue ?? [],
                query: query
            ) { [$0.title, $0.id] }
            .map { model in
                Row(
                    id               : "model:\(model.id)",
                    symbol           : nil,
                    title            : model.title,
                    summary          : nil,
                    argumentHint     : nil,
                    isCurrent        : model.id == current,
                    unavailableReason: reason,
                    completion       : "/model \(model.id)",
                    runsOnReturn     : true
                )
            }

        case .effort:
            guard let selection = context.selection else {
                found = []
                break
            }
            found = Self.matching(
                context.efforts,
                query: query
            ) { [$0.title(for: selection.provider), $0.rawValue] }
            .map { effort in
                Row(
                    id               : "effort:\(effort.rawValue)",
                    symbol           : nil,
                    title            : effort.title(for: selection.provider),
                    summary          : nil,
                    argumentHint     : nil,
                    isCurrent        : effort == selection.effort,
                    unavailableReason: reason,
                    completion       : "/effort \(effort.rawValue)",
                    runsOnReturn     : true
                )
            }

        case .screenPlace:
            let places: [(name: String, symbol: String)] = [
                ("conversation", "bubble.left.and.text.bubble.right"),
                ("inspector", "sidebar.right"),
            ]
            found = Self.matching(
                places,
                query: query
            ) { [$0.name] }
            .map { place in
                Row(
                    id               : "screen:\(place.name)",
                    symbol           : place.symbol,
                    title            : place.name.capitalized,
                    summary          : nil,
                    argumentHint     : nil,
                    isCurrent        : (place.name == "conversation") == context.showsScreenInConversation,
                    unavailableReason: reason,
                    completion       : "/screen \(place.name)",
                    runsOnReturn     : true
                )
            }
        }

        guard found.isEmpty else {
            rows = found
            return
        }

        // A known command given an argument it cannot take shows greyed, with why, so Return never fails unseen.
        rows = [
            context.row(
                command,
                reason: query.isEmpty ? nil : context.refusal(
                    of: query,
                    by: command
                )
            )
        ]
    }

    /// The candidates any of whose keys `query` matches: a key equal to it first, then those a key starts with.
    static func matching<Candidate>(
        _ candidates: [Candidate],
        query       : some StringProtocol,
        keys        : (Candidate) -> [String]
    ) -> [Candidate] {
        let ranked = candidates.map { candidate in
            (candidate, keys(candidate).compactMap { rank(query, in: $0) }.min())
        }
        return [0, 1, 2].flatMap { level in ranked.filter { $0.1 == level }.map(\.0) }
    }

    /// 0 when `key` is `query`, 1 when it starts with it, 2 when it holds its letters in order, nil otherwise; case is ignored.
    static func rank(
        _ query: some StringProtocol,
        in key : String
    ) -> Int? {
        let query = query.lowercased()
        let key   = key.lowercased()
        if key == query { return 0 }
        if key.hasPrefix(query) { return 1 }

        var rest = Substring(key)
        for letter in query {
            guard let found = rest.firstIndex(of: letter) else { return nil }
            rest = rest[rest.index(after: found)...]
        }
        return 2
    }
}

nonisolated private extension SlashCommandContext {

    /// The popup's row of `command`, greyed with `reason` when one is given,
    /// else with why the command waits, if it does.
    func row(
        _ command: SlashCommand,
        reason   : String? = nil
    ) -> SlashCommandSuggestions.Row {
        SlashCommandSuggestions.Row(
            id               : command.rawValue,
            symbol           : command.symbol,
            title            : command.name,
            summary          : command.summary,
            argumentHint     : command.argumentHint,
            isCurrent        : false,
            unavailableReason: reason ?? availability(of: command).reason,
            completion       : command.argument == .none ? command.name : command.name + " ",
            runsOnReturn     : command.argument != .effort
        )
    }

    /// Why `command` does not apply now, nil while it is listed. The popup
    /// shows it only for a draft that names the command in full.
    func whyUnlisted(_ command: SlashCommand) -> String? {
        guard availability(of: command) == .unlisted else { return nil }

        switch command {
        case .stop   : return "Available while \(worker) is responding."
        case .release: return "Available while \(worker) holds the computer."
        case .screen : return "Available once \(worker) has a screen."
        case .usage  : return "Available once \(worker) has used tokens."
        case .context: return Self.sizeUnknown
        default      : return nil
        }
    }

    /// Why `command` cannot take `argument`, under which nothing is listed.
    /// While the models or the levels are not known, or there are none, it
    /// says why the command waits instead.
    func refusal(
        of argument: String,
        by command : SlashCommand
    ) -> String {
        let waits = availability(of: command).reason
        switch command.argument {
        case .none:
            return "\(command.name) takes no argument."

        case .model:
            guard catalogue != nil else { return waits ?? "Available once the models are listed." }
            return "No model named “\(argument)”."

        case .effort:
            guard !efforts.isEmpty else { return waits ?? "This model doesn’t offer Effort levels." }
            return "No level named “\(argument)”."

        case .screenPlace:
            return "No place named “\(argument)”."
        }
    }
}
