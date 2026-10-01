import CoreGraphics
import Foundation
@testable import InteractionListener
import Testing

@Suite("Bounded listener delivery")
struct ListenerBufferTests {
    @Test func slowConsumerEndsWithAnExplicitFailure() async throws {
        let pair = AsyncThrowingStream<InteractionEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let context = TapContext(continuation: pair.continuation, hover: false, excludedPID: -1)
        func event(_ sequence: UInt64) -> InteractionEvent {
            .init(kind: .click, timestamp: Date(), startedAt: 0, endedAt: 0,
                  precedingRevision: 0, revision: sequence, point: .zero, window: nil,
                  processID: 123, sequence: sequence)
        }
        context.publish(event(1))
        context.publish(event(2))
        var iterator = pair.stream.makeAsyncIterator()
        #expect(try await iterator.next()?.sequence == 1)
        do {
            _ = try await iterator.next()
            Issue.record("Overflow silently lost an event")
        } catch ListenerFailure.consumerTooSlow { }
    }
}
