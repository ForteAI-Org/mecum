//
//  ChatHost.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import AgentTurn
import AutomationMCP
import AutomationRuntime
import ChatCore
import CLIProviders
import Darwin
import Foundation
import LocalMCP
import Memory
import ModelTransports
import SeatBroker

/// ChatStopped is how `ChatHost.run` ends after `stop`: the cleanup is complete, and what is left is to
/// say so and exit. Its own type, so a stop is never read as a provider's failure.
struct ChatStopped: Error {}

/// ChatHost is the terminal chat's one host over the computer: what `ChatCommand` composes once the
/// conversation and the provider are chosen, and keeps for the life of the chat.
///
/// The turn itself is the app's: `AgentTurnHost`, the one turn core both entries run, owns the tools over
/// the desktop session, the router, the loopback MCP host, the connection file and the provider child, and
/// reports the turn's events in order. This host adds what a terminal needs around it: the broker's
/// desktop session for the chat (one `BrokeredAutomationSession`, waiting in the broker's queue under a
/// worker id stable for the chat, §22.3), the transcript the events are written to, the loop over the
/// lines with the chat's own commands, the stop for a signal and, at the end, the shutdown of the
/// broker's parked seats. Every turn runs inside the desktop's `turn`, so nothing is released between an
/// observation and an act; between turns the session stays as the broker's idle window and queue say.
///
/// Ending, in this order: the turn core closes (no further tool call, the call in flight drained, the
/// desktop session closed, the provider child waited for, the loopback host stopped and the connection
/// file's directory removed), then the broker's parked seats are taken down. `run` does it when the chat
/// ends and when a turn fails outside a terminal; `stop`, for SIGINT and SIGTERM, interrupts the provider
/// first, records the interruption, and `run` then throws `ChatStopped` once the cleanup is complete.
/// `/release` closes the desktop's session alone: the host, its broker and the turn core stay, and the
/// next turn opens a session again through the same queue.
///
/// The broker, the desktop and the living memory are the composer's: this host drives them and closes
/// them, and makes no seat of its own. The turn core is this host's, made here over the composer's
/// desktop; its tools record every call in the memory from the `cli` source, under the chat's worker id
/// as the stream and the conversation's id as the trace, and the memory is closed last, after the seats.
@MainActor
final class ChatHost {

    /// The instructions every chat turn runs with, the turn core's for a turn with no role: the tools'
    /// base text, then the broker session's line. The app's worker adds its role after them.
    static var instructions: String { AgentTurnHost.instructions(role: nil) }

    let broker    : SeatBroker
    let desktop   : BrokeredAutomationSession
    let transcript: ChatTranscript

    /// The living memory the chat's calls are recorded in, the composer's, closed with the host.
    let memory    : MemoryService

    /// The turn core, over `desktop`. Its tools answer `/status` between turns.
    let agent: AgentTurnHost

    /// The signed-in command line the conversation belongs to; the chat answers through it alone.
    private let commandLine: ChatProvider

    /// The invocation's turn configuration (`ChatOptions`): the role, the effort (nil for the command
    /// line's default) and whether the command line may search the web. They are the invocation's, not
    /// the conversation's, and reach the core on every turn as a worker's configuration does.
    private let role           : String?
    private let effort         : ReasoningEffort?
    private let allowsWebSearch: Bool

    /// The environment the provider child inherits, through the core's allow-list.
    private let environment: [String: String]

    /// The stop's cleanup, non-nil from `stop` on. `run` ends with `ChatStopped` once it has completed.
    private var stopping: Task<Void, Never>?

    /// What the provider reported each turn and compaction of this chat process cost, in order, as the
    /// turn core made it (`AgentTurnEvent.usage`); with whether the turn's own count is known. Kept
    /// in memory only: a saved conversation keeps none of it, so a resumed chat starts without it.
    private(set) var usages: [(usage: TurnUsage, ownCountKnown: Bool)] = []

    /// The provider session the next turn resumes, as it was when the running turn began.
    private var turnSession: String?

    /// `executable` is the provider's command line, as `ChatCommand` found it on `PATH`;
    /// `bridgeExecutable` the path the provider launches as `mecum mcp-bridge --connection <file>`; and
    /// `workingDirectory` the provider child's, created 0700 by the turn core on the first turn and kept
    /// the same across turns, since Claude Code finds a session to resume by it. `role`, `effort` and
    /// `allowsWebSearch` are the invocation's turn configuration, with the chat's defaults: no role, the
    /// command line's effort, no web search. `memory` is the chat's living memory and `workerID` the id
    /// the desktop waits in the queue under, which the calls are recorded for. `provider` stands in for
    /// the provider child in the controlled tests, and `environment` for the process's; the product
    /// leaves both to the process.
    init(
        broker          : SeatBroker,
        desktop         : BrokeredAutomationSession,
        transcript      : ChatTranscript,
        memory          : MemoryService,
        workerID        : UUID = UUID(),
        executable      : URL,
        bridgeExecutable: String,
        workingDirectory: URL,
        role            : String? = nil,
        effort          : ReasoningEffort? = nil,
        allowsWebSearch : Bool = false,
        provider        : any ProviderTurnRunning = CLIProvider(),
        environment     : [String: String] = ProcessInfo.processInfo.environment
    ) {
        let commandLine      = transcript.conversation.provider
        self.broker          = broker
        self.desktop         = desktop
        self.transcript      = transcript
        self.memory          = memory
        self.commandLine     = commandLine
        self.role            = role
        self.effort          = effort
        self.allowsWebSearch = allowsWebSearch
        self.environment     = environment
        self.agent           = AgentTurnHost(
            workingDirectory: workingDirectory,
            bridgeExecutable: URL(fileURLWithPath: bridgeExecutable),
            session         : { desktop },
            // The chat answers through the one command line its composer found, whatever is asked for.
            agents          : { _ in (commandLine, executable) },
            provider        : provider,
            memory          : memory,
            source          : .cli,
            streamID        : workerID.uuidString
        )
    }

    /// The trace the chat's calls are recorded under: the conversation.
    private var traceID: String { transcript.conversation.id.uuidString }

    /// Runs the chat: `prompt` first when there is one, then, while `interactive`, each line `read`
    /// answers with, until it answers nil (the end of input), the person types `/quit`, or the one turn
    /// of `once` is done. Lines starting with `/` are the chat's own commands. The chat then ends
    /// (`shutdown`) and the transcript is saved.
    ///
    /// Throws `ChatStopped` after `stop`, once its cleanup is complete, from wherever the loop was; a
    /// provider's failure when not `interactive`, after the same cleanup (in a terminal the failure is
    /// recorded and the chat goes on); and a transcript write that failed.
    func run(
        prompt     : String?,
        interactive: Bool,
        once       : Bool,
        read       : @MainActor () async -> String?
    ) async throws {
        var next = prompt
        do {
            while true {
                if let stopping { await stopping.value; throw ChatStopped() }
                let line: String?
                if let pending = next { line = pending; next = nil }
                else if interactive { line = await read() }
                else { break }
                guard let line else { break }
                let message = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if message.isEmpty { continue }
                if message == "/quit" || message == "/exit" { break }
                if message == "/help" { print(ChatOptions.usage); continue }
                if message == "/model" {
                    transcript.conversation.model = try await ChatMenu.model(transcript.conversation.provider)
                    try transcript.save()
                    // An effort chosen for the invocation may not fit the new model: said now, before a turn is refused.
                    if let refusal = effortRefusal() {
                        print("effort: \(refusal) The next turn is refused until the model fits, or the chat "
                              + "is started again with another --effort.")
                    }
                    continue
                }
                if message == "/release" { try await release(); continue }
                if message == "/status" { print(try await status()); continue }
                if message == "/usage" { print(usageReport()); continue }
                if message == "/compact" {
                    do {
                        try await compact()
                    } catch {
                        if let stopping { await stopping.value; throw ChatStopped() }
                        let reason = Self.reason(of: error)
                        try transcript.append(.error, "Compaction failed: \(reason)")
                        print("Compaction failed: \(reason)")
                        if !interactive { throw error }
                    }
                    if once { break }
                    continue
                }
                if message.hasPrefix("/") { print("Unknown command. Use /help."); continue }
                do {
                    try await turn(message)
                } catch {
                    if let stopping { await stopping.value; throw ChatStopped() }
                    let reason = Self.reason(of: error)
                    try transcript.append(.error, reason)
                    print("Chat error: \(reason)")
                    if !interactive { throw error }
                }
                if once { break }
            }
        } catch {
            if let stopping { await stopping.value; throw ChatStopped() }
            await shutdown()
            throw error
        }
        if let stopping { await stopping.value; throw ChatStopped() }
        await shutdown()
        try transcript.save()
    }

    /// The sentence a failed turn is recorded and printed with: an `AutomationFailure`'s own words (its
    /// `localizedDescription` is Foundation's generic one), and any other error's localized description.
    static func reason(of error: any Error) -> String {
        (error as? AutomationFailure)?.description ?? error.localizedDescription
    }

    /// Why the invocation's effort cannot be sent with the conversation's model now, nil when it can
    /// (`AgentTurnHost.effortRefusal`): checked by `ChatCommand` before the chat starts, said again after
    /// `/model`, and refused by the core before a turn.
    func effortRefusal() -> String? {
        effort.flatMap {
            AgentTurnHost.effortRefusal($0, commandLine: commandLine, model: transcript.conversation.model)
        }
    }

    /// Runs one turn on `message` through the turn core, inside the desktop's turn: the message is
    /// recorded, the core runs the conversation's command line with the model it names (or the command
    /// line's default), the invocation's role, effort and web search, resuming the conversation's
    /// provider session, and each event is written to the transcript as it comes. A transcript write
    /// that fails ends the turn (the core is stopped) and is what this throws, ahead of the stop it
    /// caused. A failed turn leaves the desktop session closed, as the core does for both entries, and
    /// the next turn opens again; nothing is retried.
    func turn(_ message: String) async throws {
        try transcript.append(.user, message)
        var saving: (any Error)?
        turnSession = transcript.conversation.providerSessionID
        do {
            try await desktop.turn {
                try await agent.run(
                    prompt              : message,
                    commandLine         : commandLine,
                    model               : transcript.conversation.model,
                    effort              : effort,
                    sessionID           : transcript.conversation.providerSessionID,
                    role                : role,
                    lastUsage           : usages.last?.usage,
                    allowsWebSearch     : allowsWebSearch,
                    inheritedEnvironment: environment,
                    traceID             : traceID
                ) { [self] event in
                    guard saving == nil else { return }
                    do {
                        try record(event)
                    } catch {
                        // The transcript is the chat's record: a write that fails ends the turn, and is thrown.
                        saving = error
                        agent.stop()
                    }
                }
            }
        } catch {
            throw saving ?? error
        }
        if let saving { throw saving }
    }

    /// Writes one event of the turn to the transcript, as the chat has always recorded a turn: the
    /// provider's events through `ChatTranscript.event`, each tool record printed and kept, and what
    /// the turn cost, once, as the core reported it (`.usage`; the provider's own `.usage` never reaches
    /// here), printed and kept as one `usage:` line. The child's identity is the app's record alone.
    private func record(_ event: AgentTurnEvent) throws {
        switch event {
        case .provider(let event):
            try transcript.event(event)
        case .tool(let text):
            print("  \(text.prefix(240))")
            try transcript.append(.tool, text)
        case .usage(let usage):
            try keep(usage, resumed: turnSession)
        case .processStarted:
            break
        }
    }

    /// Keeps one usage: in this process's list, printed, and as a `usage:` line in the transcript.
    /// `resumed` is the session the turn resumed. A session total (Codex) counted with no earlier total
    /// of that session in this chat is the whole session's, not the turn's: its own count is unknown,
    /// and said so, never shown as the turn's.
    private func keep(_ usage: TurnUsage, resumed: String?) throws {
        // The core counted from the usage it was passed, the last one, when that was the same session.
        let counted = usages.last?.usage.session == usage.session
        let ownCountKnown = usage.sessionTotal == nil || resumed == nil || resumed != usage.session || counted
        usages.append((usage, ownCountKnown))
        let line = Self.usageLine(usage, ownCountKnown: ownCountKnown)
        print(line)
        try transcript.append(.tool, line)
    }

    /// One usage as a line: the turn's own tokens (or why they are unknown), the session total when the
    /// provider counts one, the context it left against the window, and the account's limits. A field
    /// the provider did not report is `unknown`, never 0.
    static func usageLine(_ usage: TurnUsage, ownCountKnown: Bool) -> String {
        func tokens(_ value: ProviderUsage.Tokens) -> String {
            "\(value.input) in (\(value.cacheReads) cache read, \(value.cacheWrites) cache write), "
                + "\(value.output) out (\(value.reasoning) reasoning)"
        }
        var parts = ["usage: \(usage.isCompaction == true ? "compaction" : "turn")"
                     + " · \(usage.provider.title)" + (usage.model.map { " \($0)" } ?? " (default model)")]
        parts.append(ownCountKnown ? "this turn \(tokens(usage.turn))"
                                   : "this turn unknown (a resumed session with no earlier count in this chat)")
        if let total = usage.sessionTotal { parts.append("session total \(tokens(total))") }
        parts.append("context " + (usage.contextTokens.map(String.init) ?? "unknown") + " of "
                     + (usage.contextWindow.map { "\($0) tokens" } ?? "an unknown window"))
        if !usage.rateLimits.isEmpty {
            parts.append("limits " + usage.rateLimits.map { "\($0.window) \(Int(($0.usedFraction * 100).rounded()))%" }
                .joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    /// `/usage`: what this chat's turns and compactions cost, as the provider reported them: the last
    /// one in full, and the sum of the turns' own counts that are known, with how many are not. Nothing
    /// is summed twice: a session total is shown as such and never added.
    func usageReport() -> String {
        guard let last = usages.last else {
            return "No usage reported in this chat yet. Usage is kept for this chat process only; a resumed "
                + "conversation starts without it."
        }
        let known = usages.filter(\.ownCountKnown).map(\.usage.turn)
        let sum = known.reduce(ProviderUsage.Tokens(), +)
        let unknown = usages.count - known.count
        return [
            "Last: " + Self.usageLine(last.usage, ownCountKnown: last.ownCountKnown),
            "This chat: \(usages.count) reported (\(usages.filter { $0.usage.isCompaction == true }.count) compactions); "
                + "own counts summed over \(known.count): \(sum.input) in, \(sum.output) out"
                + (unknown > 0 ? "; \(unknown) with an unknown own count left out" : ""),
            "Kept for this chat process only; a resumed conversation starts without it.",
        ].joined(separator: "\n")
    }

    /// `/compact`: compacts the provider session's context through the turn core's compaction, the
    /// app's: Claude Code's own `/compact`, or Codex's compaction turn, with the conversation's model,
    /// the invocation's effort and role. It is no desktop task: it calls no tool and takes no Seat. Its
    /// outcome is printed and kept as a `compaction:` line, with what it cost when the provider said;
    /// a provider that did not compact is a failure, thrown, and nothing is invented or retried.
    func compact() async throws {
        let session = transcript.conversation.providerSessionID
        print("Compacting the \(commandLine.displayName) session's context…")
        let (compaction, usage) = try await agent.compact(
            commandLine         : commandLine,
            model               : transcript.conversation.model,
            effort              : effort,
            sessionID           : session,
            role                : role,
            trigger             : .manual,
            lastUsage           : usages.last?.usage,
            inheritedEnvironment: environment
        )
        if var usage {
            usage.isCompaction = true
            try keep(usage, resumed: session)
        }
        let line = "compaction: \(compaction.provider.title) \(compaction.trigger.rawValue) · context "
            + (compaction.preTokens.map(String.init) ?? "unknown") + " → " + (compaction.postTokens.map(String.init) ?? "unknown")
            + " tokens of " + (compaction.contextWindow.map { "\($0)" } ?? "an unknown window")
        print(line)
        try transcript.append(.tool, line)
    }

    /// `/release`: closes the desktop's session, so its window goes home, an application the agent
    /// launched is quit and the seat is given back, and says so in the transcript. The host stays, and
    /// the next turn opens a session again through the broker's queue.
    func release() async throws {
        await desktop.close()
        try transcript.append(.tool, "User released the Seat. Any previous session ID is now stale.")
        print("Seat released.")
    }

    /// `/status`: the status tool's answer as JSON, which needs no session. Its call and its result
    /// are printed and kept in the transcript as a turn's tool records are, through the core's
    /// `inspect`, so the diagnostic reads back like everything else the chat did. A transcript write
    /// that fails is thrown after the call, which is not run again; the result is not returned then.
    func status() async throws -> String {
        var saving: (any Error)?
        let result = try await agent.inspect("status", .object([:]), traceID: traceID) { [self] line in
            guard saving == nil else { return }
            do { try record(.tool(line)) }
            catch { saving = error }
        }
        if let saving { throw saving }
        return String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    }

    /// Stops the chat for a signal: no further tool call is accepted and the provider is interrupted at
    /// once; then, in the task returned, the turn core closes (the call in flight drained, the desktop
    /// session closed, the child waited for, the loopback host stopped and the configuration removed),
    /// the interruption is recorded and the broker's parked seats are taken down. Idempotent: a second
    /// stop returns the first's task. The caller awaits the task before exiting, and `run` throws
    /// `ChatStopped` once it has completed.
    @discardableResult
    func stop() -> Task<Void, Never> {
        if let stopping { return stopping }
        agent.stop()
        let cleanup = Task {
            await closeAgent()
            do { try transcript.append(.interrupted, "Interrupted. Inspect the current app state before continuing.") }
            catch { fputs("mecum: transcript save failed: \(error)\n", stderr) }
            await broker.queue.shutdown()
            await memory.close()
        }
        stopping = cleanup
        return cleanup
    }

    /// Ends the host's hold on everything: the turn core closes, then the broker's parked seats are
    /// taken down, then the memory is closed, with nothing left that could write to it. Safe at any
    /// point and twice; the broker itself is the composer's and is left as it is.
    func shutdown() async {
        await closeAgent()
        await broker.queue.shutdown()
        await memory.close()
    }

    /// Closes the turn core. The one thing its close throws for, a connection file directory it could
    /// not remove, is reported on standard error and never thrown: everything else was released first.
    private func closeAgent() async {
        do { try await agent.close() }
        catch { fputs("mecum: could not remove temporary chat configuration: \(error)\n", stderr) }
    }
}
