import CoreGraphics
import Foundation
import InteractionListener
import Testing

@Suite
struct GestureTests {
    private func tick(
        window: UInt32 = 1, before: UInt64, after: UInt64, at: Double, dy: Float32 = 4, source: Int32 = 0
    ) -> InputRecord {
        var record = InputRecord(kind: .scrollDelta, timestamp: UInt64(at * 1e9),
                                 precedingRevision: before, revision: after)
        record.set(.windowResolved)
        record.set(.hasSourceProcess)
        record.targetPID = 42
        record.sourcePID = source
        record.windowNumber = window
        record.windowWidth = 100
        record.windowHeight = 100
        record.x = 10
        record.y = 10
        record.valueA = 2
        record.valueB = dy
        return record
    }

    @Test func scrollSettlesWithOriginalOwnerAndBothAxes() {
        var accumulator = ScrollGesture()
        #expect(accumulator.append(tick(before: 0, after: 1, at: 0)) == nil)
        #expect(accumulator.append(tick(before: 1, after: 2, at: 0.2)) == nil)
        #expect(accumulator.settled(at: 0.6) == nil)
        let gesture = accumulator.settled(at: 0.8)
        #expect(gesture?.valueB == 8)
        #expect(gesture?.valueA == 4)
        #expect(gesture?.precedingRevision == 0)
        #expect(gesture?.revision == 2)
        #expect(gesture?.startedAt == 0)
        #expect(gesture?.endedAt == 0.2)
        #expect(accumulator.take() == nil)
    }

    @Test func changingWindowOrInterveningInputSplitsGestures() {
        var accumulator = ScrollGesture()
        _ = accumulator.append(tick(before: 0, after: 1, at: 0))
        #expect(accumulator.append(tick(window: 2, before: 1, after: 2, at: 0.1))?.windowNumber == 1)
        #expect(accumulator.append(tick(window: 2, before: 3, after: 4, at: 0.2))?.revision == 2)
        #expect(accumulator.take()?.revision == 4)
    }

    @Test func differentInputSourcesCannotBecomeOneGesture() {
        var accumulator = ScrollGesture()
        _ = accumulator.append(tick(before: 0, after: 1, at: 0, source: 100))
        let first = accumulator.append(tick(before: 1, after: 2, at: 0.1, source: 200))
        #expect(first?.sourcePID == 100)
        #expect(accumulator.take()?.sourcePID == 200)
    }

    @Test func oppositeScrollTicksStillProduceAnEvent() {
        var accumulator = ScrollGesture()
        _ = accumulator.append(tick(before: 0, after: 1, at: 0))
        _ = accumulator.append(tick(before: 1, after: 2, at: 0.1, dy: -4))
        #expect(accumulator.settled(at: 1)?.valueB == 0)
    }

    @Test func settleDeadlineFollowsTheLastTickAndClearsWhenTaken() {
        var accumulator = ScrollGesture()
        #expect(accumulator.deadline == nil)
        _ = accumulator.append(tick(before: 0, after: 1, at: 1))
        #expect(accumulator.deadline == 1.5)
        _ = accumulator.append(tick(before: 1, after: 2, at: 1.25))
        #expect(accumulator.deadline == 1.75)
        #expect(accumulator.settled(at: 1.5) == nil)
        #expect(accumulator.settled(at: 1.75) != nil)
        #expect(accumulator.deadline == nil)
    }

    @Test func hoverEmitsOnceUntilMovementOrInput() {
        var hover = HoverDwell()
        let point = CGPoint(x: 10, y: 10)
        hover.moved(to: point, surface: 1, at: 0)
        let first = [0.0, 1, 1.3, 3].map { hover.fire(at: $0) }
        #expect(first == [false, false, true, false])
        hover.restart(at: 4)
        let reset = [4.0, 5.3].map { hover.fire(at: $0) }
        #expect(reset == [false, true])
    }

    @Test func dwellIgnoresJitterButReArmsOnMovementOrAnotherSurface() {
        var hover = HoverDwell()
        hover.restart(at: 0)
        #expect(hover.deadline == nil, "input before any pointer position arms nothing")
        hover.moved(to: CGPoint(x: 10, y: 10), surface: 1, at: 0)
        hover.moved(to: CGPoint(x: 12, y: 11), surface: 1, at: 0.5)
        #expect(hover.deadline == HoverDwell.delay)
        hover.moved(to: CGPoint(x: 20, y: 10), surface: 1, at: 0.8)
        #expect(hover.deadline == 0.8 + HoverDwell.delay)
        hover.moved(to: CGPoint(x: 20, y: 10), surface: 2, at: 1.0)
        #expect(hover.deadline == 1.0 + HoverDwell.delay)
        let early = hover.fire(at: 2.1), due = hover.fire(at: 2.3)
        #expect(!early && due)
        hover.moved(to: CGPoint(x: 21, y: 10), surface: 2, at: 3)
        #expect(hover.deadline == nil, "jitter after a hover does not arm another")
    }
}
