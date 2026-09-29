import CoreGraphics
@testable import InteractionListener
import Testing

@Suite
struct CallbackHistogramTests {
    @Test func bucketsAreLog2OfNanoseconds() {
        let cases: [(UInt64, Int)] = [(0, 0), (1, 1), (2, 2), (3, 2), (4, 3), (1023, 10), (1024, 11), (4_100, 13),
                                      (1_000_000, 20), (UInt64(1) << 62, 63), (UInt64.max, 63)]
        for (nanoseconds, bucket) in cases { #expect(CallbackHistogram.bucket(nanoseconds) == bucket, "\(nanoseconds)") }
        var histogram = CallbackHistogram()
        for value: UInt64 in [3, 2, 1024, 1500, 0] { histogram.record(value) }
        #expect(histogram.buckets[0] == 1 && histogram.buckets[2] == 2 && histogram.buckets[11] == 2)
        #expect(histogram.count == 5 && histogram.maximum == 1500)
    }

    @Test func percentilesInterpolateInsideTheirBucketAndStopAtTheMaximum() {
        var histogram = CallbackHistogram()
        #expect(histogram.percentile(0.99) == 0)
        // Four samples in [1024, 2048), the maximum's bucket: they spread over [1024, 1400].
        for value: UInt64 in [1100, 1200, 1300, 1400] { histogram.record(value) }
        #expect(histogram.percentile(0.5) == 1212)
        #expect(histogram.percentile(0.25) == 1118)
        #expect(histogram.percentile(1) == 1400, "never above the maximum")
        // Below the maximum's bucket a rank interpolates over the whole octave.
        var octaves = CallbackHistogram()
        for value: UInt64 in [1100, 1200, 1300, 1400, 5000] { octaves.record(value) }
        #expect(octaves.percentile(0.4) == 1536)
        // 98 fast samples and 2 slow ones: p50 stays in the fast bucket, p99 lands in the slow one.
        var tail = CallbackHistogram()
        for _ in 0..<98 { tail.record(3_000) }
        for _ in 0..<2 { tail.record(900_000) }
        #expect((2048...4096).contains(tail.percentile(0.5)))
        #expect((524_288...900_000).contains(tail.percentile(0.99)))
        #expect(tail.percentile(0.98) <= 4096)
    }

    @Test func takeHandsOverTheSamplesAndResets() {
        var histogram = CallbackHistogram()
        for value: UInt64 in [5_000, 7_000] { histogram.record(value) }
        let taken = histogram.take()
        #expect(taken.count == 2 && taken.maximum == 7_000)
        #expect(histogram == CallbackHistogram())
        histogram.record(1)
        #expect(histogram.count == 1 && histogram.maximum == 1)
    }

    @Test func lineNamesTheRoleAndKindInMicroseconds() {
        #expect(CallbackHistogram().line(role: "observer", kind: "timer") == "callback[observer] timer: n 0 (since last dump)")
        var histogram = CallbackHistogram()
        for value: UInt64 in [1100, 1200, 1300, 1400] { histogram.record(value) }
        #expect(histogram.line(role: "inprocess", kind: "input", atStop: true)
            == "callback[inprocess] input: n 4 p50 1.2us p90 1.4us p99 1.4us max 1.4us (since last dump, at stop)")
    }

    @Test func callbacksThatCanProduceAnEventAreInputAndTheRestPointer() {
        var latency = CallbackLatency()
        for type: CGEventType in [.leftMouseDown, .rightMouseDown, .scrollWheel] { latency.record(type, 2_000) }
        for type: CGEventType in [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .keyDown,
                                  .tapDisabledByTimeout] { latency.record(type, 300) }
        latency.timer.record(50_000)
        #expect(latency.input.count == 3 && latency.input.maximum == 2_000)
        #expect(latency.pointer.count == 6 && latency.pointer.maximum == 300)
        #expect(latency.timer.count == 1)
        let taken = latency.take()
        #expect(latency == CallbackLatency() && taken.input.count == 3)
        #expect(taken.lines(role: "inprocess").split(separator: "\n").map { $0.prefix(while: { $0 != ":" }) }
            == ["callback[inprocess] input", "callback[inprocess] pointer", "callback[inprocess] timer"])
        #expect(CallbackLatency().lines(role: "inprocess", atStop: true) == """
            callback[inprocess] input: n 0 (since last dump, at stop)
            callback[inprocess] pointer: n 0 (since last dump, at stop)
            callback[inprocess] timer: n 0 (since last dump, at stop)
            """)
    }
}
