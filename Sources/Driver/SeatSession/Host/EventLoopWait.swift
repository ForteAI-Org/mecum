//
//  EventLoopWait.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import AppKit
import Foundation
import SeatCore

/// EventLoopWait is how the session layer waits, and it is the answer to the
/// question ADR 0007 leaves open.
///
/// A virtual display makes progress only while `NSApplication` pumps events, so
/// `VirtualDisplay` has no wait inside it and the Seat Host has the waits
/// instead: "the Seat Host owns the pumping question, which is right, it is the
/// component that has a run loop". This is that ownership, and it is one branch
/// wide.
///
/// **When the caller's application is running its own loop** (`isRunning`, which
/// is true from `NSApplication.run()` onwards), the wait suspends. The
/// application's loop is already turning, so it publishes the `NSScreen` and
/// removes the display, and a nested pump here would re-enter the person's own
/// application while it is in the middle of asking for something.
///
/// **When nobody is running a loop** (a benchmark, a test harness, a command
/// line tool that called `finishLaunching` and no more), the wait turns the loop
/// itself, synchronously, and never suspends. Both halves of that sentence are
/// load-bearing:
///
/// - turning it is the only way the display appears at all;
/// - never suspending is what keeps the process alive. On an `async` main, a
///   suspension hands the thread back to the concurrency runtime, whose drain
///   loop then decides the program is over and calls `exit(0)` in the middle of
///   the run. ADR 0007 measured that on the third display of a benchmark, and a
///   `swift test` process does the same: it exits zero with a host test half
///   finished and no report at all.
///
/// So the rule is: suspend where somebody else pumps, pump where nobody does.
///
/// ## Only a caller's own wait may pump
///
/// `step` is for a bounded wait **inside an operation the caller asked for**:
/// the display appearing during `start`, the window coming to rest during
/// `adopt`, the display leaving the list during `stop`. Those hold the main
/// actor for as long as they take anyway, so turning the loop there costs
/// nothing that was not already blocked.
///
/// A background loop must use `sleep` and never `step`. The watchdog's heartbeat
/// and the recovery's cadence run on their own tasks, and a task that pumped for
/// a second at a time would hold the main actor forever: measured here as a host
/// test that hung with the heartbeat pumping, because the test body could never
/// be resumed.
nonisolated enum EventLoopWait {

    /// The caller's own way of turning its event loop, when it has one it wants
    /// used (`SeatHostConfiguration.eventLoopPump`).
    ///
    /// A harness that already drives `nextEvent` somewhere else hands that same
    /// function over rather than letting a second call site appear, which is
    /// ADR 0007's rule taken literally: only the caller knows how it pumps, and
    /// two places turning one loop is a thing to avoid on principle rather than
    /// after it has cost something. There is one main event loop in a process
    /// and v1 has one host in it, so this is process-wide state on purpose.
    nonisolated(unsafe) private(set) static var installedPump: (@MainActor (Duration) -> Void)?

    @MainActor
    static func installPump(_ pump: (@MainActor (Duration) -> Void)?) {
        installedPump = pump
    }

    /// Waits roughly `interval`, by whichever of the two mechanisms applies.
    /// For a bounded wait inside an operation the caller is awaiting.
    @MainActor
    static func step(_ interval: Duration) async {

        if let installedPump { return installedPump(interval) }

        guard NSApplication.shared.isRunning else { return pump(interval) }

        await pauseIgnoringCancellation(nanoseconds: UInt64(interval.wholeNanoseconds))
    }

    /// Waits roughly `interval` without ever turning the event loop, for a
    /// periodic background loop. It gives the main actor back, which is the
    /// whole difference from `step`.
    ///
    /// It is `pauseIgnoringCancellation`, a `DispatchQueue.main.asyncAfter`,
    /// and not `Task.sleep`. A sleeping task lives on the concurrency
    /// runtime's own timer; a main-queue timer source is what an `async` main's
    /// drain loop actually waits for, and swapping the two made a whole test
    /// tier end in the middle of its run. The cost is that a cancelled
    /// heartbeat finishes its current interval before it notices.
    @MainActor
    static func sleep(_ interval: Duration) async {
        await pauseIgnoringCancellation(nanoseconds: UInt64(interval.wholeNanoseconds))
    }

    /// Waits until the condition holds, or the timeout runs out, and answers
    /// whether it held.
    @MainActor
    static func until(
        _ condition: @MainActor () -> Bool,
        timeout    : Duration,
        interval   : Duration = .milliseconds(20)
    ) async -> Bool {

        let deadline = Date().addingTimeInterval(
            Double(timeout.wholeNanoseconds) / 1_000_000_000
        )

        while Date() < deadline {
            if condition() { return true }
            await step(interval)
        }

        return condition()
    }

    /// One slice of the application event loop, which is what makes a virtual
    /// display move for a caller that has no loop of its own.
    @MainActor
    private static func pump(_ interval: Duration) {

        let deadline = Date().addingTimeInterval(
            Double(interval.wholeNanoseconds) / 1_000_000_000
        )

        // Two pools, and both are load-bearing. The inner one keeps one event's
        // autoreleased objects from piling up over a long slice; the outer one
        // is the pool the nested run loop's own objects land in, and it has to
        // be popped by the same frame that pushed it. Without it they land in
        // the pool the concurrency runtime established around this job, which
        // is popped by whichever job runs next: measured as a segfault inside
        // `objc_release` during `objc_autoreleasePoolPop`, on the main queue,
        // in the test after the one that pumped.
        autoreleasepool {
            repeat {
                autoreleasepool {
                    if let event = NSApplication.shared.nextEvent(
                        matching: .any,
                        until   : deadline,
                        inMode  : .default,
                        dequeue : true
                    ) {
                        NSApplication.shared.sendEvent(event)
                    }
                }
            } while Date() < deadline
        }
    }
}
