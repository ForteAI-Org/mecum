import CoreGraphics
import Foundation
import InteractionListener
import Testing

@Suite
struct GestureTests {
    private func tick(window: Int = 1, before: UInt64, after: UInt64, at: Double, dy: Double = 4, source: Int32? = nil) -> InteractionEvent {
        InteractionEvent(kind: .scroll, timestamp: Date(timeIntervalSince1970: at), startedAt: at, endedAt: at,
                         precedingRevision: before, revision: after, point: CGPoint(x: 10, y: 10),
                         window: .init(processID: 42, number: window, title: nil, layer: 0,
                                       frame: CGRect(x: 0, y: 0, width: 100, height: 100)), processID: 42, deltaX: 2, deltaY: dy, sourceProcessID: source)
    }

    @Test func scrollSettlesWithOriginalOwnerAndBothAxes() {
        var accumulator = ScrollGesture()
        #expect(accumulator.append(tick(before: 0, after: 1, at: 0)) == nil)
        #expect(accumulator.append(tick(before: 1, after: 2, at: 0.2)) == nil)
        #expect(accumulator.settled(at: 0.6) == nil)
        let gesture = accumulator.settled(at: 0.8)
        #expect(gesture?.deltaY == 8)
        #expect(gesture?.deltaX == 4)
        #expect(gesture?.precedingRevision == 0)
        #expect(gesture?.revision == 2)
        #expect(accumulator.take() == nil)
    }

    @Test func changingWindowOrInterveningInputSplitsGestures() {
        var accumulator = ScrollGesture()
        _ = accumulator.append(tick(before: 0, after: 1, at: 0))
        #expect(accumulator.append(tick(window: 2, before: 1, after: 2, at: 0.1))?.window?.number == 1)
        #expect(accumulator.append(tick(window: 2, before: 3, after: 4, at: 0.2))?.revision == 2)
        #expect(accumulator.take()?.revision == 4)
    }

    @Test func differentInputSourcesCannotBecomeOneGesture() {
        var accumulator = ScrollGesture()
        _ = accumulator.append(tick(before: 0, after: 1, at: 0, source: 100))
        let first = accumulator.append(tick(before: 1, after: 2, at: 0.1, source: 200))
        #expect(first?.sourceProcessID == 100)
        #expect(accumulator.take()?.sourceProcessID == 200)
    }

    @Test func oppositeScrollTicksStillProduceAnEvent() {
        var accumulator = ScrollGesture()
        _ = accumulator.append(tick(before: 0, after: 1, at: 0))
        _ = accumulator.append(tick(before: 1, after: 2, at: 0.1, dy: -4))
        #expect(accumulator.settled(at: 1)?.deltaY == 0)
    }

    @Test func hoverEmitsOnceUntilMovementOrInput() {
        var hover = HoverDwell()
        let window = tick(before: 0, after: 1, at: 0).window
        let point = CGPoint(x: 10, y: 10)
        let first = [0.0, 1, 1.3, 3].map { hover.sample(point: point, window: window, at: $0) }
        #expect(first == [false, false, true, false])
        hover.reset(at: 4)
        let reset = [4.0, 5.3].map { hover.sample(point: point, window: window, at: $0) }
        #expect(reset == [false, true])
    }
}
