import CoreGraphics
import Dispatch
import Foundation
@testable import InteractionListener
import Synchronization
import Testing

@Suite
struct InputQueueTests {
    private static func record(_ kind: InputRecord.Kind, id: UInt64 = 0, at time: UInt64 = 0) -> InputRecord {
        var record = InputRecord(kind: kind, timestamp: time, precedingRevision: id, revision: id + 1)
        record.x = Float32(id)
        return record
    }

    private func drain(_ queue: InputQueue) -> [InputRecord] {
        var records: [InputRecord] = []
        while let record = queue.pop() { records.append(record) }
        return records
    }

    @Test func recordLayoutIsDeclaredFixedAndPadFree() {
        #expect(MemoryLayout<InputRecord>.size == InputRecord.size)
        #expect(MemoryLayout<InputRecord>.stride == InputRecord.size)
        #expect(MemoryLayout<InputRecord>.alignment == 8)
        let offsets: [(PartialKeyPath<InputRecord>, Int)] = [
            (\.sequence, 0), (\.timestamp, 8), (\.startTimestamp, 16), (\.precedingRevision, 24),
            (\.revision, 32), (\.targetPID, 40), (\.sourcePID, 44), (\.windowNumber, 48),
            (\.windowLayer, 52), (\.attributionGeneration, 56), (\.lostCritical, 60),
            (\.lostCoalescible, 64), (\.type, 68), (\.flags, 70), (\.x, 72), (\.y, 76),
            (\.valueA, 80), (\.valueB, 84), (\.windowX, 88), (\.windowY, 92),
            (\.windowWidth, 96), (\.windowHeight, 100),
        ]
        for (path, offset) in offsets { #expect(MemoryLayout<InputRecord>.offset(of: path) == offset, "\(path)") }
        let kinds: [InputRecord.Kind] = [.empty, .click, .rightClick, .scrollDelta, .hover, .focus, .gap]
        #expect(kinds.map(\.rawValue) == [0, 1, 2, 3, 4, 5, 6])
        let flags: [InputRecord.Flag] = [.windowResolved, .staleAttribution, .hasSourceProcess]
        #expect(flags.map(\.rawValue) == [1, 2, 4])
    }

    @Test func recordRebuildsTheEventConsumersAlreadyRead() throws {
        var click = Self.record(.click, id: 4, at: 2_500_000_000)
        click.sequence = 9
        click.set(.windowResolved)
        click.set(.hasSourceProcess)
        click.targetPID = 631
        click.sourcePID = 77
        click.windowNumber = 6988
        click.windowLayer = 3
        click.windowX = 487
        click.windowY = -169.5
        click.windowWidth = 920
        click.windowHeight = 436
        let event = try #require(InteractionEvent(record: click, title: "Fixture"))
        #expect(event.kind == .click && event.sequence == 9 && event.startedAt == 2.5 && event.endedAt == 2.5)
        #expect(event.window == InteractionWindow(processID: 631, number: 6988, title: "Fixture", layer: 3,
                                                  frame: CGRect(x: 487, y: -169.5, width: 920, height: 436)))
        #expect(event.processID == 631 && event.sourceProcessID == 77)
        #expect(event.precedingRevision == 4 && event.revision == 5 && event.point == CGPoint(x: 4, y: 0))

        var stale = Self.record(.rightClick)
        stale.set(.staleAttribution)
        stale.targetPID = 631
        stale.windowNumber = 6988
        let unresolved = try #require(InteractionEvent(record: stale, title: "ignored"))
        #expect(unresolved.window == nil && unresolved.processID == 631 && unresolved.sourceProcessID == nil)

        var gap = Self.record(.gap)
        gap.sequence = 12
        gap.lostCritical = 2
        gap.lostCoalescible = 1
        let lost = try #require(InteractionEvent(record: gap, title: nil))
        #expect(lost.kind == .gap)
        #expect(lost.gap == .init(firstSequence: 10, lastSequence: 12, lostCritical: 2, lostCoalescible: 1))
        #expect(InteractionEvent(record: InputRecord(), title: nil) == nil)
    }

    @Test func wraparoundKeepsOrderAndSequencesAcrossManyLaps() {
        let queue = InputQueue(capacity: 4, reserved: 1)
        var expected: UInt64 = 1
        for lap in 0..<100 {
            for offset in 0..<3 { queue.push(Self.record(.click, id: UInt64(lap * 3 + offset))) }
            for record in drain(queue) {
                #expect(record.sequence == expected)
                #expect(record.precedingRevision == expected - 1)
                expected += 1
            }
        }
        #expect(expected == 301)
        #expect(queue.counters == InputQueueCounters(published: 300, coalescedHovers: 0, aggregatedScrolls: 0,
                                                     lostCritical: 0, lostCoalescible: 0, gaps: 0))
    }

    @Test func criticalRecordsSurviveWhenCoalescibleCapacityIsSaturated() {
        let queue = InputQueue(capacity: 8, reserved: 4)
        for id in 1...10 { queue.push(Self.record(.hover, id: UInt64(id))) }
        for id in 11...14 { queue.push(Self.record(.click, id: UInt64(id))) }
        let first = drain(queue)
        #expect(first.map(\.kind) == [.hover, .hover, .hover, .hover, .click, .click, .click, .click])
        #expect(first.map(\.x) == [1, 2, 3, 4, 11, 12, 13, 14])
        #expect(first.map(\.sequence) == Array(1...8))
        queue.retry()
        let held = drain(queue)
        #expect(held.map(\.x) == [10], "the last hover is kept, earlier ones are coalesced")
        #expect(held.first?.sequence == 9)
        #expect(queue.counters.coalescedHovers == 5)
        #expect(queue.counters.lostCritical == 0 && queue.counters.lostCoalescible == 0)
    }

    @Test func gapCarriesTheLostRangeAndCountsOnceRoomExists() {
        let queue = InputQueue(capacity: 4, reserved: 2)
        for id in 1...4 { queue.push(Self.record(.click, id: UInt64(id), at: UInt64(id))) }
        queue.push(Self.record(.click, id: 5, at: 5))
        queue.push(Self.record(.hover, id: 6, at: 6))
        queue.push(Self.record(.focus, id: 7, at: 7))
        var scroll = Self.record(.scrollDelta, id: 8, at: 8)
        scroll.valueB = 3
        queue.push(scroll)
        #expect(queue.pop()?.sequence == 1)
        #expect(queue.pop()?.sequence == 2)
        queue.push(Self.record(.click, id: 9, at: 9))
        let records = drain(queue)
        #expect(records.map(\.kind) == [.click, .click, .gap, .click])
        let gap = records[2]
        #expect(gap.firstLostSequence == 5 && gap.sequence == 7)
        #expect(gap.lostCritical == 2 && gap.lostCoalescible == 1)
        #expect(gap.startTimestamp == 5 && gap.timestamp == 7)
        #expect(gap.precedingRevision == 5 && gap.revision == 8)
        #expect(records[3].sequence == 8 && records[3].x == 9)
        queue.retry()
        let held = drain(queue)
        #expect(held.map(\.kind) == [.scrollDelta] && held.first?.sequence == 9 && held.first?.valueB == 3)
        #expect(queue.counters == InputQueueCounters(published: 7, coalescedHovers: 0, aggregatedScrolls: 0,
                                                     lostCritical: 2, lostCoalescible: 1, gaps: 1))
    }

    @Test func compatibleScrollsAggregateWhileWaitingAndABrokenChainIsCountedAsLoss() {
        let queue = InputQueue(capacity: 4, reserved: 2)
        queue.push(Self.record(.click, id: 0))
        queue.push(Self.record(.click, id: 1))
        var first = Self.record(.scrollDelta, id: 2, at: 10)
        first.valueA = 1
        first.valueB = 4
        var second = Self.record(.scrollDelta, id: 3, at: 20)
        second.valueA = -3
        second.valueB = 6
        queue.push(first)
        queue.push(second)
        #expect(queue.counters.aggregatedScrolls == 1)
        _ = drain(queue)
        queue.retry()
        let merged = drain(queue)
        #expect(merged.count == 1)
        #expect(merged.first?.valueA == -2 && merged.first?.valueB == 10)
        #expect(merged.first?.startTimestamp == 10 && merged.first?.timestamp == 20)
        #expect(merged.first?.precedingRevision == 2 && merged.first?.revision == 4)

        queue.push(Self.record(.click, id: 10))
        queue.push(Self.record(.click, id: 11))
        queue.push(Self.record(.scrollDelta, id: 20))
        queue.push(Self.record(.scrollDelta, id: 30))
        #expect(queue.counters.lostCoalescible == 1, "input between two scrolls keeps them apart")
    }

    @Test func closingUnderPressureStillDeliversTheGapAndTheHeldRecord() {
        let queue = InputQueue(capacity: 4, reserved: 2)
        for id in 1...4 { queue.push(Self.record(.click, id: UInt64(id))) }
        queue.push(Self.record(.click, id: 5))
        queue.push(Self.record(.hover, id: 6))
        queue.close()
        var records: [InputRecord] = []
        queue.waitForRecords(onSpace: {})
        queue.drainAfterClose { records.append($0) }
        #expect(records.map(\.kind) == [.click, .click, .click, .click, .gap, .hover])
        #expect(records.map(\.sequence) == [1, 2, 3, 4, 5, 6])
    }

    @Test func consumerAsksTheProducerForRoomOnlyWhenSomethingWaits() {
        let queue = InputQueue(capacity: 4, reserved: 2)
        queue.push(Self.record(.click, id: 1))
        queue.push(Self.record(.click, id: 2))
        queue.push(Self.record(.hover, id: 3))
        _ = drain(queue)
        var asked = 0
        queue.waitForRecords { asked += 1; queue.retry() }
        #expect(asked == 1)
        #expect(drain(queue).map(\.kind) == [.hover])
        queue.close()
        queue.waitForRecords { asked += 1 }
        #expect(asked == 1)
    }

    /// Two threads, over a million critical records and randomized consumer stalls. The producer never
    /// blocks inside the queue; it only paces clicks to the declared budget, as human input is, while
    /// hovers and chained scrolls are pushed unpaced, so coalescible capacity saturates and every
    /// degradation step runs: kept-last hovers, aggregated scrolls, losses and gaps.
    @Test func concurrentStressLosesDuplicatesAndReordersNoCriticalRecord() throws {
        let run = try #require(Self.stress(criticalTotal: 1_050_000, paced: true))
        #expect(run.tally.violations.isEmpty, "\(run.tally.violations.prefix(5))")
        #expect(run.tally.critical == run.produced.critical)
        #expect(run.tally.lostCritical == 0 && run.counters.lostCritical == 0)
        #expect(run.counters.coalescedHovers > 0 && run.counters.aggregatedScrolls > 0 && run.counters.gaps > 0,
                "coalescible capacity must saturate for this test to mean anything: \(run.counters)")
        Self.expectAccounted(run)
    }

    /// The same threads with clicks unpaced beyond the reserved budget: critical records are lost only
    /// inside gaps whose ranges and counts account for every one of them, and the rest stay in order.
    @Test func concurrentOverloadLosesCriticalRecordsOnlyInsideCountedGaps() throws {
        let run = try #require(Self.stress(criticalTotal: 300_000, paced: false))
        #expect(run.tally.violations.isEmpty, "\(run.tally.violations.prefix(5))")
        #expect(run.counters.lostCritical > 0, "the overload must exhaust reserved capacity: \(run.counters)")
        #expect(run.tally.critical + run.tally.lostCritical == run.produced.critical)
        #expect(UInt64(run.tally.lostCritical) == run.counters.lostCritical)
        Self.expectAccounted(run)
    }

    private static func expectAccounted(_ run: StressRun) {
        let counters = run.counters
        #expect(UInt64(run.tally.coalescible) + counters.coalescedHovers + counters.aggregatedScrolls
                    + counters.lostCoalescible == UInt64(run.produced.coalescible))
        #expect(UInt64(run.tally.lostCoalescible) == counters.lostCoalescible)
        #expect(UInt64(run.tally.gaps) == counters.gaps)
        #expect(run.tally.lastSequence
                    == counters.published - counters.gaps + counters.lostCritical + counters.lostCoalescible)
    }

    /// Runs one producer and one stalling consumer to completion, or nil if they did not finish.
    private static func stress(criticalTotal: Int, paced: Bool) -> StressRun? {
        let queue = InputQueue(capacity: 1024, reserved: 256)
        let shared = StressShared()
        let finished = DispatchSemaphore(value: 0)

        Thread {
            var random = SeededRandom(seed: 0x5EED)
            var critical = 0, coalescible = 0, scrolls: UInt64 = 0
            while critical < criticalTotal {
                let draw = random.next() % 8
                if draw < 2 {
                    queue.push(record(.hover, id: UInt64(coalescible)))
                    coalescible += 1
                    continue
                }
                if draw == 2 {
                    // Consecutive scrolls chain by revision, so a held one can absorb the next.
                    var scroll = record(.scrollDelta, id: StressTally.scrollBase + scrolls)
                    scroll.x = Float32(coalescible)
                    queue.push(scroll)
                    scrolls += 1
                    coalescible += 1
                    continue
                }
                // Declared load: a click never finds the ring without room for itself and one gap.
                while paced,
                      Int(queue.counters.published) &- shared.consumed.load(ordering: .acquiring) >= queue.capacity - 2 {
                    queue.retry()
                    sched_yield()
                }
                queue.push(record(critical % 7 == 0 ? .focus : .click, id: UInt64(critical)))
                critical += 1
            }
            queue.close()
            shared.produced.withLock { $0 = (critical, coalescible) }
            finished.signal()
        }.start()

        Thread {
            var random = SeededRandom(seed: 0xC0FFEE)
            var tally = StressTally()
            let check: (InputRecord) -> Void = { record in
                tally.observe(record)
                shared.consumed.add(1, ordering: .releasing)
                if random.next() % 2048 == 0 { usleep(UInt32(random.next() % 500)) }
            }
            while true {
                queue.waitForRecords(onSpace: {})
                while let record = queue.pop() { check(record) }
                if queue.isClosed {
                    queue.drainAfterClose(check)
                    break
                }
            }
            shared.tally.withLock { $0 = tally }
            finished.signal()
        }.start()

        // A lost wakeup or a stuck producer would hang here; the caller fails on nil.
        guard finished.wait(timeout: .now() + 120) == .success, finished.wait(timeout: .now() + 120) == .success else {
            return nil
        }
        return StressRun(produced: shared.produced.withLock { $0 }, tally: shared.tally.withLock { $0 },
                         counters: queue.counters)
    }
}

private struct StressRun {
    let produced: (critical: Int, coalescible: Int)
    let tally: StressTally
    let counters: InputQueueCounters
}

/// StressShared is what the stress threads exchange; atomics and mutexes cannot be captured bare.
private final class StressShared: Sendable {
    let consumed = Atomic<Int>(0)
    let produced = Mutex((critical: 0, coalescible: 0))
    let tally = Mutex(StressTally())
}

/// StressTally checks each delivered record against the queue's contract as it arrives. Critical ids
/// only increase, so with nothing lost a count equal to the produced one means all of them, in order.
private struct StressTally: Sendable {
    static let scrollBase: UInt64 = 1 << 40
    var lastSequence: UInt64 = 0
    var critical = 0
    var lastCritical = -1
    var coalescible = 0
    var lastCoalescible: Float32 = -1
    var gaps = 0
    var lostCritical = 0
    var lostCoalescible = 0
    var violations: [String] = []

    mutating func observe(_ record: InputRecord) {
        let first = record.kind == .gap ? record.firstLostSequence : record.sequence
        if first != lastSequence + 1 { violations.append("sequence \(first) after \(lastSequence)") }
        lastSequence = record.sequence
        switch record.kind {
        case .click, .focus:
            if Int(record.precedingRevision) <= lastCritical {
                violations.append("critical \(record.precedingRevision) after \(lastCritical)")
            }
            lastCritical = Int(record.precedingRevision)
            critical += 1
        case .hover, .scrollDelta:
            if record.x <= lastCoalescible { violations.append("\(record.kind) \(record.x) reordered") }
            lastCoalescible = record.x
            coalescible += 1
        case .gap:
            gaps += 1
            lostCritical += Int(record.lostCritical)
            lostCoalescible += Int(record.lostCoalescible)
        default:
            violations.append("unexpected \(record.kind)")
        }
    }
}

/// SeededRandom makes stall patterns reproducible from their seed.
private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
