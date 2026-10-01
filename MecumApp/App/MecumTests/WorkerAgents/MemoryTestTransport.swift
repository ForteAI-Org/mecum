import Foundation
import ModelTransports
import Synchronization

final class MemoryTestTransport: ModelTransport {

    struct Sent: Sendable {
        let messages: [TurnMessage]
        let tools   : [ToolDefinition]
    }

    private struct State {
        var rounds      : [[TurnEvent]]
        var sent        : [Sent] = []
        var held        : AsyncThrowingStream<TurnEvent, any Error>.Continuation?
        var wasCancelled = false
    }

    private let supportsTools: Bool
    private let state        : Mutex<State>

    init(
        supportsTools: Bool,
        rounds       : [[TurnEvent]]
    ) {
        self.supportsTools = supportsTools
        self.state         = Mutex(State(rounds: rounds))
    }

    var streaming: StreamingSupport { .incremental }

    var sent: [Sent] { state.withLock { $0.sent } }

    var wasCancelled: Bool { state.withLock { $0.wasCancelled } }

    func complete(
        prompt : String,
        schema : Data,
        timeout: TimeInterval
    ) async throws -> (text: String, usage: ModelUsage) {
        throw ModelTransportError.streamingUnsupported("a scripted transport has no structured request")
    }

    func capabilities() async throws -> ModelCapabilities {
        ModelCapabilities(supportsTools: supportsTools)
    }

    func converse(
        _ messages: [TurnMessage],
        tools     : [ToolDefinition],
        timeout   : TimeInterval
    ) throws -> AsyncThrowingStream<TurnEvent, any Error> {
        let events = state.withLock { state -> [TurnEvent]? in
            state.sent.append(Sent(
                messages: messages,
                tools   : tools
            ))
            return state.rounds.isEmpty ? nil : state.rounds.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            guard let events else {
                continuation.onTermination = { _ in self.state.withLock { $0.wasCancelled = true } }
                state.withLock { $0.held = continuation }
                return
            }
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}
