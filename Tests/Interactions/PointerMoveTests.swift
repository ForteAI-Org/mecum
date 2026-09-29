@preconcurrency import CoreGraphics
import Foundation
@testable import InteractionListener
import Synchronization
import Testing

/// Drives the tap callback's body with synthetic moves on a thread standing in for the tap thread, with
/// the real refresher and wake timer behind it. No tap is created, so Input Monitoring is not needed.
@Suite(.serialized)
struct PointerMoveTests {
    /// Prints the move path's p50/p99/max under paced input, 3000 moves 1 ms apart, in two shapes: every
    /// move entering another surface, which wakes the refresher as every move did before, and moves
    /// inside one surface entering another every 500. Debug-build numbers, never asserted.
    @Test func measuresTheMovePath() async {
        for (name, every) in [("every move enters a surface", 1), ("moves inside one surface", 500)] {
            let rig = Rig()
            await rig.waitForGeneration(atLeast: 1)
            let start = rig.generation
            let moves = (0..<3000).map { (index: Int) -> (CGEventType, CGEvent) in
                let window = index / every % 2 == 0 ? 101 : 102
                return Rig.event(.mouseMoved, x: Double(100 + index % 400), window: window)
            }
            let pointer = await rig.drive(moves, pace: 0.001).latency.pointer
            let refreshes = rig.generation - start
            rig.stop()
            func us(_ nanoseconds: Double) -> String { String(format: "%.2f us", nanoseconds / 1000) }
            print("move path, \(name): n \(pointer.count) p50 \(us(pointer.percentile(0.5))) "
                  + "p99 \(us(pointer.percentile(0.99))) max \(us(Double(pointer.maximum))), snapshot refreshes \(refreshes)")
            #expect(pointer.count == 3000)
        }
    }

    /// Moves inside one surface and drag movement leave the refresher asleep; entering another surface
    /// and the first move after a drag wake it.
    @Test func wakesTheRefresherOnlyOnEnteringASurfaceOrADragsEnd() async throws {
        let rig = Rig()
        defer { rig.stop() }
        await rig.waitForGeneration(atLeast: 1)
        _ = await rig.drive([Rig.event(.mouseMoved, x: 100, window: 101)])
        await rig.waitForGeneration(atLeast: rig.generation + 1)
        let entered = rig.generation
        _ = await rig.drive((0..<200).map { Rig.event(.mouseMoved, x: Double(101 + $0), window: 101) })
        _ = await rig.drive((0..<50).map { Rig.event(.leftMouseDragged, x: Double(300 + $0), window: 101) })
        try await Task.sleep(for: .milliseconds(400))
        #expect(rig.generation == entered, "moves and drags inside one surface refreshed the snapshot")
        _ = await rig.drive([Rig.event(.mouseMoved, x: 351, window: 101)])
        await rig.waitForGeneration(atLeast: entered + 1)
        #expect(rig.generation == entered + 1, "the first move after a drag refreshes once")
        _ = await rig.drive([Rig.event(.mouseMoved, x: 352, window: 102)])
        await rig.waitForGeneration(atLeast: entered + 2)
        #expect(rig.generation == entered + 2, "entering another surface refreshes once")
    }

    /// Each move re-anchors the dwell and pushes its deadline later; the wake timer stays armed at the
    /// first move's deadline instead of being moved on every event.
    @Test func movesThatPushTheDwellLaterLeaveTheTimerAlone() async {
        let rig = Rig()
        defer { rig.stop() }
        let moves = (0..<20).map { Rig.event(.mouseMoved, x: Double(100 + 10 * $0), window: 101) }
        let driven = await rig.drive(moves, pace: 0.01)
        let armedAfter = driven.fireDate - driven.started
        #expect(armedAfter > 1.1 && armedAfter < 1.3, "armed \(armedAfter) s after the first move, not after the last")
    }

    final class Rig: @unchecked Sendable {
        let context: TapContext

        init() {
            let pair = AsyncThrowingStream<InteractionEvent, any Error>.makeStream()
            // No real pid is -1: every synthetic event counts as the user's.
            context = TapContext(continuation: pair.continuation, hover: true, excludedPID: -1)
            let refresher = Thread { [context] in context.refresh() }
            refresher.qualityOfService = .utility
            refresher.start()
        }

        var generation: UInt32 { context.snapshot.withLock { $0.generation } }

        func stop() { context.requestStop() }

        func waitForGeneration(atLeast target: UInt32, timeout: Double = 2) async {
            let deadline = Date().addingTimeInterval(timeout)
            while generation < target, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        }

        /// What one drive left: the histograms, when it began and the wake timer's fire date at its end.
        struct Driven {
            let latency: CallbackLatency
            let started: CFAbsoluteTime
            let fireDate: CFAbsoluteTime
        }

        /// Delivers `events` on a dedicated thread with a wake timer on its run loop, `pace` seconds apart.
        func drive(_ events: [(CGEventType, CGEvent)], pace: Double = 0) async -> Driven {
            await withCheckedContinuation { done in
                Thread { [context] in
                    let timer = context.addWakeTimer(to: CFRunLoopGetCurrent())
                    let started = CFAbsoluteTimeGetCurrent()
                    for (type, event) in events {
                        context.receive(type: type, event: event)
                        if pace > 0 { Thread.sleep(forTimeInterval: pace) }
                    }
                    let fireDate = CFRunLoopTimerGetNextFireDate(timer)
                    CFRunLoopTimerInvalidate(timer)
                    done.resume(returning: Driven(latency: context.latency, started: started, fireDate: fireDate))
                }.start()
            }
        }

        static func event(_ type: CGEventType, x: Double, window: Int) -> (CGEventType, CGEvent) {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: 300),
                                mouseButton: .left)!
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window))
            event.setIntegerValueField(.eventTargetUnixProcessID, value: 4242)
            return (type, event)
        }
    }
}
