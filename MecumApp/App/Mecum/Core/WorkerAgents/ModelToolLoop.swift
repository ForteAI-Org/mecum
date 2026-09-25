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
/// the model the way the loopback MCP tells a command line. A round without
/// calls ends the turn. A model that cannot call tools is sent none, and
/// instructions that say so.
///
/// Memory across turns is the history the caller passes; within a turn the
/// loop keeps every call and result. A failure is never retried.
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

    /// Runs one turn and reports its events in order: each round's text as one
    /// `.assistant` block, the tools' records as they run them, then
    /// `.completed`. The text a round delivered stays reported even when the
    /// round then fails or is stopped.
    ///
    /// Throws `CancellationError` after `stop`, once a tool call in flight has
    /// finished; the transport's failure, in the provider's words; or a failure
    /// naming `toolRoundLimit` when the model keeps calling tools.
    func run(
        transport: any ModelTransport,
        role     : String?,
        history  : [TurnMessage],
        prompt   : String,
        onEvent  : @escaping @MainActor (WorkerAgentEvent) -> Void
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
        messages.append(TurnMessage(
            role: .user,
            text: prompt
        ))

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
                toolCalls: reply.calls
            ))
            for toolCall in reply.calls {
                if isStopRequested { throw CancellationError() }
                messages.append(await result(of: toolCall))
            }
        }
    }

    /// Stops the running turn: the round streaming now is cancelled and no
    /// further tool call starts. A call already running finishes, and `run`
    /// then throws.
    func stop() {
        isStopRequested = true
        round?.cancel()
    }

    // MARK: Rounds

    /// What one round delivered: its text, its calls, and the failure that ended it early, if any.
    private struct Round: Sendable {
        var text   = ""
        var calls  : [ToolCall] = []
        var failure: (any Error)?
    }

    private static func collect(_ stream: AsyncThrowingStream<TurnEvent, any Error>) async -> Round {
        var round = Round()
        do {
            for try await event in stream {
                switch event {
                case .delta(let text):     round.text += text
                case .toolCall(let call):  round.calls.append(call)
                case .completed:           break
                }
            }
        } catch {
            round.failure = error
        }
        return round
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
