//
//  SlashCommand.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/09/2026.
//

import Foundation

/// SlashCommand is one of Mecum's own commands, typed in the composer as
/// `/name`. The app runs it, the same for every provider: a command never
/// becomes a message and never reaches an agent. The order of the cases is
/// the order the composer's popup lists them in.
nonisolated enum SlashCommand: String, CaseIterable, Identifiable {

    case compact, new, model, effort, stop, release, screen, usage, context

    var id: String { rawValue }

    /// What follows the name, when the command takes anything.
    enum Argument: Equatable {

        case none

        /// One of the provider's models, by id or by name.
        case model

        /// One of the levels the worker's model offers.
        case effort

        /// Where the worker's screen shows: `conversation` or `inspector`.
        case screenPlace
    }

    /// The command as typed and as the popup shows it: "/compact".
    var name: String { "/" + rawValue }

    var symbol: String {
        switch self {
        case .compact: "arrow.down.right.and.arrow.up.left"
        case .new    : "arrow.counterclockwise"
        case .model  : "cpu"
        case .effort : "gauge.with.dots.needle.67percent"
        case .stop   : "stop.circle"
        case .release: "rectangle.portrait.and.arrow.right"
        case .screen : "display"
        case .usage  : "circle.hexagongrid"
        case .context: "chart.pie"
        }
    }

    /// What it does, on one line.
    var summary: String {
        switch self {
        case .compact: "Compact the context"
        case .new    : "Start a fresh context"
        case .model  : "Change the model"
        case .effort : "Change the effort"
        case .stop   : "Stop the response"
        case .release: "Release the computer"
        case .screen : "Move the screen"
        case .usage  : "Show the tokens used"
        case .context: "Show the context"
        }
    }

    var argument: Argument {
        switch self {
        case .model : .model
        case .effort: .effort
        case .screen: .screenPlace
        default     : .none
        }
    }

    /// What the popup shows after the name for a command that takes an argument: "‹name›".
    var argumentHint: String? {
        switch argument {
        case .none       : nil
        case .model      : "‹name›"
        case .effort     : "‹level›"
        case .screenPlace: "‹place›"
        }
    }

    /// The command a name stands for, whatever its case, without the slash; nil for any other.
    init?(named name: some StringProtocol) {
        self.init(rawValue: name.lowercased())
    }
}

/// SlashCommandInvocation is a draft read as a command: the command its first
/// token names and what follows, trimmed. Only a draft whose first token is
/// `/name` of a known command is one. A draft that starts with `//` is not,
/// and is sent with its first `/` removed (`messageText`); text that names no
/// command, a path such as `/Users/me/file`, is sent unchanged.
///
/// A command whose argument is `.none` takes no text after its name, and one
/// given any is a command that does not run (`SlashCommandContext.action`).
/// This matters most for `/compact`: the Claude compaction turn is the one
/// turn that runs command line slash commands, so no text of the person's may
/// reach it (`ProviderInvocation`, in `Sources/Chat/CLIProviders`).
nonisolated struct SlashCommandInvocation: Equatable {

    let command : SlashCommand

    /// What follows the name, trimmed; empty when nothing does.
    let argument: String

    init(
        _ command: SlashCommand,
        argument : String = ""
    ) {
        self.command  = command
        self.argument = argument
    }

    /// The command `draft` names, nil for a draft that is a message.
    init?(draft: String) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/"), !text.hasPrefix("//") else { return nil }

        let name = text.dropFirst().prefix { !$0.isWhitespace }
        guard let command = SlashCommand(named: name) else { return nil }

        self.command  = command
        self.argument = text.dropFirst(1 + name.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What a message's text is sent as: a text that starts with `//` loses its first `/`.
    static func messageText(_ text: String) -> String {
        text.hasPrefix("//") ? String(text.dropFirst()) : text
    }
}
