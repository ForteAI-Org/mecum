//
//  ModelToolLoop.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import AutomationMCP
import AutomationRuntime
import ChatCore
import Foundation
import LocalMCP
import ModelTransports

/// ModelToolLoop is Mecum's own agent loop for a model provider (§7.1): the
/// turn a command line runs for itself, run here over the provider's transport
/// with the same tools and instructions.
///
/// Each round streams one tool turn, reports its text as one reply block, and
/// runs the calls it made in order, each one's result or failure going back to
/// the model the way the loopback MCP tells a command line. The assistant
/// message that made the calls keeps the provider's record of the round, which
/// its transport sends back instead of rebuilding it. A round without calls
/// ends the turn. A model that cannot call tools is sent none, and
/// instructions that say so.
///
/// Memory across turns is the history the caller passes; within a turn the
/// loop keeps every call and result. `summarize` compacts that history into a
/// summary the caller sends instead. A failure is never retried.
@MainActor
final class ModelToolLoop {

    // ponytail: a fixed ceiling of 100 tool rounds per turn; make it a setting if real work needs more.
    static let toolRoundLimit = 100

    private let call: @MainActor (String, JSONValue) async throws -> JSONValue

    /// Set by `stop`; checked before each round and each tool call.
    private var isStopRequested = false

    /// The round streaming now, cancelled by `stop`.
    private var round: Task<Round, Never>?

    /// `call` runs one tool by name, as `AutomationTools.call` does, and reports
    /// its records itself.
    init(call: @escaping @MainActor (String, JSONValue) async throws -> JSONValue) {
        self.call = call
    }

    /// The tools a model is handed: `AutomationTools.definitions`, each with its schema.
    static func definitions() throws -> [ToolDefinition] {
        try AutomationTools.definitions.map { definition in
            ToolDefinition(
                name       : definition["name"].string ?? "",
                description: definition["description"].string ?? "",
                parameters : try JSONEncoder().encode(definition["inputSchema"])
            )
        }
    }

    /// The window a loop turn on `selection` runs in: the `num_ctx` Mecum sends
    /// Ollama, else what the provider's catalogue states for the model, and nil
    /// when it states none.
    static func contextWindow(
        of selection: ModelSelection,
        settings    : ProviderSettings,
        catalogue   : [ModelInfo]
    ) -> Int? {
        guard selection.provider != .ollama else { return settings.ollamaContextTokens }
        return catalogue.first { $0.id == selection.model }?.contextWindow
    }

    /// Runs one turn and reports its events in order: each round's text as one
    /// `.assistant` block, the tools' records as they run them, then
    /// `.completed`. The text a round delivered stays reported even when the
    /// round then fails or is stopped.
    ///
    /// What the rounds that completed cost comes last, however the turn ends,
    /// as one `.usage`: their counts added up, the context the last of them
    /// left (its input and output), and `contextWindow`. A turn whose provider
    /// reported no count reports none.
    ///
    /// `seat`, Mecum's seat line, goes ahead of `prompt` when the model can
    /// call tools; one without tools is told it cannot use apps.
    ///
    /// Throws `CancellationError` after `stop`, once a tool call in flight has
    /// finished; the transport's failure, in the provider's words; or a failure
    /// naming `toolRoundLimit` when the model keeps calling tools.
    func run(
        transport    : any ModelTransport,
        role         : String?,
        history      : [TurnMessage],
        prompt       : String,
        seat         : String? = nil,
        contextWindow: Int? = nil,
        onEvent      : @escaping @MainActor (WorkerAgentEvent) -> Void
    ) async throws {
        let hasTools = try await transport.capabilities().supportsTools
        let tools    = hasTools ? try Self.definitions() : []
        var messages = [TurnMessage(
            role: .system,
            text: WorkerAgentHost.instructions(
                role    : role,
                hasTools: hasTools
            )
        )]
        messages += history
        let asked = if hasTools, let seat { seat + "\n\n" + prompt } else { prompt }
        messages.append(TurnMessage(
            role: .user,
            text: asked
        ))

        var spent  : ProviderUsage.Tokens?
        var context: Int?
        defer {
            if let spent {
                onEvent(.provider(.usage(ProviderUsage(
                    tokens       : spent,
                    contextTokens: context,
                    contextWindow: contextWindow
                ))))
            }
        }

        var toolRounds = 0
        while true {
            if isStopRequested { throw CancellationError() }

            let stream = try transport.converse(
                messages,
                tools  : tools,
                timeout: transport.requestTimeout
            )
            let task = Task { await Self.collect(stream) }
            round = task
            let reply = await task.value
            round = nil

            if let usage = reply.usage, usage.inputTokens != nil || usage.outputTokens != nil {
                let counted = Self.tokens(of: usage)
                spent   = (spent ?? ProviderUsage.Tokens()) + counted
                context = usage.inputTokens == nil ? nil : counted.input + counted.output
            }

            let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { onEvent(.provider(.assistant(text))) }
            if isStopRequested { throw CancellationError() }
            if let failure = reply.failure { throw failure }
            guard !reply.calls.isEmpty else {
                onEvent(.provider(.completed))
                return
            }
            guard toolRounds < Self.toolRoundLimit else {
                throw AutomationFailure("The model kept calling tools after \(Self.toolRoundLimit) rounds in one "
                                        + "response, so Mecum stopped it. Review the app before continuing.")
            }

            toolRounds += 1
            messages.append(TurnMessage(
                role     : .assistant,
                text     : reply.text,
                toolCalls: reply.calls,
                record   : reply.record
            ))
            for toolCall in reply.calls {
                if isStopRequested { throw CancellationError() }
                messages.append(await result(of: toolCall))
            }
        }
    }

    // MARK: Compaction

    /// What the summary call is told it is for.
    static let summaryInstructions = "You summarize a conversation between a person and an assistant, so "
        + "the assistant can go on from the summary alone."

    /// What the summary call asks for, after the history.
    static let summaryRequest = "Summarize the conversation so far for yourself to continue from: the "
        + "person's goals, the decisions made, the current state of the work, and the open items. Be "
        + "concise, a few hundred words at most, and write only the summary."

    /// What a later turn is sent before a summary, in place of the messages it replaced.
    static let summaryPreface = "Summary of the conversation before this point, which replaces it:\n\n"

    /// Asks the model for a summary of `history`, which a later turn is sent
    /// in place of it, in one call with no tools, so it needs no desktop.
    /// Returns the summary and what the call cost when the provider counted it:
    /// its input is the context before, its output the summary's size.
    ///
    /// Throws `CancellationError` after `stop`, the transport's failure, or a
    /// failure when the model wrote no summary. It is never retried.
    func summarize(
        transport: any ModelTransport,
        history  : [TurnMessage]
    ) async throws -> (summary: String, tokens: ProviderUsage.Tokens?) {
        var messages = [TurnMessage(
            role: .system,
            text: Self.summaryInstructions
        )]
        messages += history
        messages.append(TurnMessage(
            role: .user,
            text: Self.summaryRequest
        ))

        if isStopRequested { throw CancellationError() }
        let stream = try transport.converse(
            messages,
            tools  : [],
            timeout: transport.requestTimeout
        )
        let task = Task { await Self.collect(stream) }
        round = task
        let reply = await task.value
        round = nil

        if isStopRequested { throw CancellationError() }
        if let failure = reply.failure { throw failure }
        let summary = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { throw AutomationFailure("The model returned an empty summary.") }

        let counted = reply.usage.flatMap { $0.inputTokens != nil || $0.outputTokens != nil ? $0 : nil }
        return (summary, counted.map(Self.tokens(of:)))
    }

    /// Stops the running turn: the round streaming now is cancelled and no
    /// further tool call starts. A call already running finishes, and `run`
    /// then throws.
    func stop() {
        isStopRequested = true
        round?.cancel()
    }

    // MARK: Rounds

    /// What one round delivered: its text, its calls, the provider's record of it, what it cost when
    /// it completed, and the failure that ended it early, if any.
    private struct Round: Sendable {
        var text   = ""
        var calls  : [ToolCall] = []
        var record : TurnRecord?
        var usage  : ModelUsage?
        var failure: (any Error)?
    }

    private static func collect(_ stream: AsyncThrowingStream<TurnEvent, any Error>) async -> Round {
        var round = Round()
        do {
            for try await event in stream {
                switch event {
                case .delta(let text):       round.text += text
                case .toolCall(let call):    round.calls.append(call)
                case .record(let record):    round.record = record
                case .completed(let usage):  round.usage = usage
                }
            }
        } catch {
            round.failure = error
        }
        return round
    }

    /// A round's counts, with the cache reads and writes a provider counts apart from its input
    /// added to it, so `input` is everything the model read.
    private static func tokens(of usage: ModelUsage) -> ProviderUsage.Tokens {
        let reads  = usage.cacheReadTokens ?? 0
        let writes = usage.cacheWriteTokens ?? 0
        return ProviderUsage.Tokens(
            input      : (usage.inputTokens ?? 0) + reads + writes,
            cacheReads : reads,
            cacheWrites: writes,
            output     : usage.outputTokens ?? 0
        )
    }

    /// The tool's answer as the model reads it: the text of the MCP result, and
    /// on a thrown error the same failure result `MCPRouter` gives a command line.
    private func result(of toolCall: ToolCall) async -> TurnMessage {
        let result: JSONValue
        do {
            let arguments = try JSONDecoder().decode(
                JSONValue.self,
                from: toolCall.arguments
            )
            result = try await call(
                toolCall.name,
                arguments
            )
        } catch {
            result = MCPRouter.failureResult(error)
        }

        return TurnMessage(
            result : result["content"].array?.first?["text"].string ?? "",
            of     : toolCall,
            isError: result["isError"].bool == true
        )
    }
}
