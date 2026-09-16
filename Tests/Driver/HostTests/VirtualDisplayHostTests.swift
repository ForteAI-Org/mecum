//
//  VirtualDisplayHostTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import AppKit
import CoreGraphics
import Foundation
import PrivateSymbols
import SeatCore
import Testing
import VirtualScreens

/// A real AppKit event pump, and the reason this file exists in the Host tier
/// rather than the unit one.
///
/// `NSScreen.screens` is refreshed from the **application** event loop, not
/// from a `RunLoop` turn: a process that waits with `RunLoop.run` or with
/// `Task.sleep` never sees a virtual display appear, no matter how long it
/// waits. A `swift test` process has no `NSApplication`
/// loop of its own, so the suite drives one itself, `.accessory` so nothing
/// steals the person's focus and nothing appears in their Dock.
///
/// Each turn drains an autorelease pool the way `NSApplication.run` does.
///
/// The pumping has to happen **inside** the test body and never around a
/// blocking wait. A test that released a display and then slept for it to go
/// offline, instead of pumping, took the process down: the display never left
/// the online list, and when the test finally returned the concurrency
/// runtime's own drain loop ended the process with `exit(0)`, losing the
/// failure report and every test after it. That is why `VirtualDisplay` has no
/// `remove()` that waits for the caller.
@MainActor
enum AppKitPump {

    private static var isPrepared = false

    static func prepare() {
        guard !isPrepared else { return }
        isPrepared = true
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        keepProcessAlive()
        run(for: 0.2)
    }

    /// One main-queue block that always reschedules itself, started once for
    /// the whole tier and never stopped.
    ///
    /// It is the other half of the problem this type documents. An `async` main
    /// drains the **main dispatch queue**, and it ends the program when that
    /// queue has nothing left; a `@MainActor` test body suspended inside a Seat
    /// Host's teardown was enough for it to call `exit(0)` in the middle of the
    /// tier, exit code zero, no failure, no crash report, taking every suite
    /// after it with it. Measured as the sixth virtual display of a run, while
    /// eight in a row from a synchronous `main` are fine, which is what rules
    /// the display out as the cause.
    ///
    /// It has to be `asyncAfter` and not `Task.sleep`: a sleeping task lives on
    /// the concurrency runtime's own timer, which the dispatch drain loop does
    /// not count, and a keep-alive built on it was measured not to help. A
    /// timer source on the main queue is exactly the thing the loop waits for.
    private static func keepProcessAlive() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { keepProcessAlive() }
    }

    static func run(for seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
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

    /// Pumps until the condition holds or the timeout runs out, and answers
    /// whether it held.
    static func run(until condition: () -> Bool, timeout: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            run(for: 0.005)
        }
        return condition()
    }
}

/// Milliseconds between two `systemUptime` readings, which is how every wall
/// time in this suite is taken.
nonisolated func millisecondsSince(_ start: TimeInterval) -> Double {
    (ProcessInfo.processInfo.systemUptime - start) * 1000
}

extension VirtualDisplaySuites {

    /// The Display Facility against a real virtual display on the machine running
    /// the tests. It creates one, attaches it to the corner of the person's
    /// arrangement, verifies the User Seat invariants, takes it away, **verifies
    /// the removal with the online list**, restores the topology, and leaves the
    /// machine exactly as it found it.
    ///
    /// The budgets of spec section 8 are asserted here as well as in the benchmark,
    /// because a setup that has silently grown to two seconds should fail a test
    /// run and not only a `make bench` nobody ran.
    @Suite("The virtual display on the running host", .serialized)
    @MainActor
    struct VirtualDisplayHostTests {

        /// Spec section 8: setup at most 800 ms p95 without a settle.
        static let setupBudgetMilliseconds: Double = 800

        /// Spec section 8: removal at most 200 ms p95.
        static let removalBudgetMilliseconds: Double = 200

        /// What a **single** cycle is allowed to take: four times the p95
        /// budget above, which makes this a detector for something that hangs
        /// and not a budget.
        ///
        /// One sample cannot be checked against a p95: the p95 gate lives in
        /// `SeatBench display-lifecycle`, which runs cycles and takes the
        /// percentile. Checking it here failed one run in three on a machine
        /// under its own build, at 203 ms against a budget of 200 and a
        /// baseline of 78 to 94, which says nothing about the kit and
        /// everything about who had the CPU. Twice the budget was tried next
        /// and was still too tight: a removal measured **527 ms** against a
        /// graded p95 of 87 ms in the same hour, in a tier that had just run a
        /// suite of its own. The number to catch is a cycle that has silently
        /// grown to seconds, and a ceiling that fires on a scheduler hiccup
        /// only teaches people to run the tier again until it is green.
        static let singleCycleCeiling: Double = 4

        @Test("the Display facility resolves its primitives on this build", .enabled(if: tierEnabled()))
        func facilityResolves() {
            let missing = SymbolTable.shared.firstUnresolved(of: VirtualDisplay.surfacePrimitives)
            #expect(missing == nil, "unresolved surface primitive: \(missing ?? "")")

            // The whole Facility also needs `_AXUIElementGetWindow` and the
            // Accessibility grant. The grant is the consumer's to obtain, so the
            // readiness may legitimately be `permissionMissing` here; what may not
            // happen is `unavailable`, which would mean a primitive is gone.
            let gate = FacilityGate.current(facility: .display)
            if case .unavailable(let reason) = gate.readiness {
                Issue.record("display facility unavailable: \(reason)")
            }
        }

        @Test("a display is created, attached, removed and the machine is left as found",
              .enabled(if: tierEnabled()))
        func fullLifecycle() throws {
            AppKitPump.prepare()

            let baselineOnline = Set(try DisplayList.online())
            let baselineMain   = CGMainDisplayID()

            // MARK: setup, measured without any settle
            let setupStart = ProcessInfo.processInfo.systemUptime
            let display    = try VirtualDisplay.create()

            // Both registrations need the application event loop to turn, and
            // AppKit's implies CoreGraphics's: waiting for the NSScreen covers both.
            let registered = AppKitPump.run(until: { display.appKitScreen != nil }, timeout: 5)
            #expect(registered, "AppKit never published an NSScreen for \(display.displayID)")
            #expect(display.isRegistered)

            try display.configureTopology()
            try display.verifyTopology()
            let setupMilliseconds = millisecondsSince(setupStart)

            // MARK: the invariants a seat cannot start without
            #expect(!display.mainChangedDuringCreation)
            #expect(CGMainDisplayID() == baselineMain)
            #expect(try display.isOnline)
            #expect(display.physicalOverlapArea == 0, "the virtual display overlaps the person's pixels")
            #expect(
                display.maximumPhysicalPortalLength <= 1.5,
                "portal \(display.maximumPhysicalPortalLength) pt, expected a single point"
            )
            #expect(display.quartzBounds.size == display.pixelSize)
            // The requested origin is a request. The window server snaps the corner
            // attachment to the nearest arrangement it accepts, measured here as
            // one point down from what was asked for, which is why the invariants
            // above are written about overlap and portal width and not about the
            // origin landing exactly where the kit pointed.
            #expect(abs(display.quartzBounds.minX - display.requestedOrigin.x) <= 1)
            #expect(abs(display.quartzBounds.minY - display.requestedOrigin.y) <= 1)

            // The topology is verified a second time after a deliberate wait, to
            // see whether the 300 ms settle that came out was ever load bearing.
            // If this ever disagrees with the verify above, the settle comes back.
            AppKitPump.run(for: 0.3)
            try display.verifyTopology()
            #expect(try display.isOnline)

            // MARK: removal, verified with the list and not with CGDisplayIsOnline
            let removalStart = ProcessInfo.processInfo.systemUptime
            display.invalidate()
            let removed = AppKitPump.run(until: { (try? display.isOnline) == false }, timeout: 2)
            let removalMilliseconds = millisecondsSince(removalStart)

            #expect(removed, "the display was still listed after 2 s")
            #expect(try !display.isOnline)
            #expect(try !DisplayList.online().contains(display.displayID))
            #expect(display.appKitScreen == nil)

            // MARK: the person's desk, put back
            let restoration = try display.restoreTopology()
            #expect(restoration != .topologyChangedByUser, "the display set changed during the test")
            AppKitPump.run(for: 0.3)

            try display.verifyTopology()
            #expect(CGMainDisplayID() == baselineMain)
            #expect(Set(try DisplayList.online()) == baselineOnline)

            // MARK: the budgets of spec section 8
            print(String(
                format: "display setup %.0f ms (budget %.0f), removal %.0f ms (budget %.0f), "
                    + "restore %@",
                setupMilliseconds, Self.setupBudgetMilliseconds,
                removalMilliseconds, Self.removalBudgetMilliseconds,
                String(describing: restoration)
            ))
            #expect(setupMilliseconds   <= Self.setupBudgetMilliseconds   * Self.singleCycleCeiling)
            #expect(removalMilliseconds <= Self.removalBudgetMilliseconds * Self.singleCycleCeiling)
        }

        @Test("the topology restore refuses while the display is still listed",
              .enabled(if: tierEnabled()))
        func restoreRefusesWhileOnline() throws {
            AppKitPump.prepare()

            let baselineOnline = Set(try DisplayList.online())
            let display        = try VirtualDisplay.create()
            #expect(AppKitPump.run(until: { display.appKitScreen != nil }, timeout: 5))
            try display.configureTopology()

            // The guard written as `CGDisplayIsOnline(id) == 0` never holds: the
            // restore behind it is not gated, it is skipped, every time.
            #expect(throws: DisplayFailure.displayStillOnline(display.displayID)) {
                try display.restoreTopology()
            }

            display.invalidate()
            #expect(AppKitPump.run(until: { (try? display.isOnline) == false }, timeout: 2))

            // Now it is allowed, and it is idempotent: a fail-closed teardown calls
            // it more than once on purpose.
            #expect(try display.restoreTopology() != .topologyChangedByUser)
            #expect(try display.restoreTopology() == .notNeeded)

            AppKitPump.run(for: 0.3)
            #expect(Set(try DisplayList.online()) == baselineOnline)
            try display.verifyTopology()
        }

        @Test("a second display in the same process is created and removed like the first",
              .enabled(if: tierEnabled()))
        func aSecondDisplayInTheSameProcess() throws {
            AppKitPump.prepare()

            // A process that creates one display per run never exercises this.
            // Two defects only appear from the second display on: an autoreleased
            // reference that delays the removal, and a registration wait that
            // answers "ready" for a display that was never published.
            let baselineOnline = Set(try DisplayList.online())
            for _ in 0..<2 {
                let display = try VirtualDisplay.create()
                #expect(AppKitPump.run(until: { display.appKitScreen != nil }, timeout: 5))
                #expect(display.isRegistered)
                try display.configureTopology()
                try display.verifyTopology()

                display.invalidate()
                #expect(AppKitPump.run(until: { (try? display.isOnline) == false }, timeout: 2))
                #expect(try display.restoreTopology() != .topologyChangedByUser)
                AppKitPump.run(for: 0.5)
            }
            #expect(Set(try DisplayList.online()) == baselineOnline)
        }
    }
}
