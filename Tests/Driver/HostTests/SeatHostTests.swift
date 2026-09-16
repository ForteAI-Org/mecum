//
//  SeatHostTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import AppKit
import CoreGraphics
import Foundation
import PrivateSymbols
import SeatCore
import SeatInput
import SeatSession
import Testing
import VirtualScreens
import WindowPlacement

/// What the event stream carried during the cycle.
@MainActor
final class SeatEventLog {
    private(set) var events: [SeatEvent] = []
    func record(_ event: SeatEvent) { events.append(event) }
}

extension VirtualDisplaySuites {

    /// The Seat Host and one cycle on it, against a real virtual display, a real
    /// event tap, a real window and a real window server.
    ///
    /// ## One test, one display, and one invocation of its own
    ///
    /// It is one test on purpose: only one virtual display can exist in a
    /// process at a time (`VirtualDisplaySuites`), so the whole cycle lives
    /// inside one start and one stop.
    ///
    /// It also has to run in its own `swift test` invocation, and the reason is
    /// **not** this suite. Run alone it passes every time; run in the same
    /// process as the other display-owning suites the run dies partway through
    /// with a SIGSEGV inside `objc_release`, during an autorelease pool pop on
    /// the main queue. The trigger was isolated by reproducing it with no
    /// session code at all: holding a `CursorFence` across the display creations of
    /// `VirtualDisplayHostTests.aSecondDisplayInTheSameProcess` makes that
    /// suite fail the same way. Six displays in one process without a fence are
    /// fine, and eight from a synchronous `main` are fine, which rules out both
    /// the count and this suite. It is an interaction between a live HID tap and
    /// the virtual display lifecycle, and it belongs to whoever owns those two.
    ///
    ///     AGENTSEAT_HOST_TESTS=1 swift test --filter theSeatCycle
    ///     AGENTSEAT_HOST_TESTS=1 swift test --filter HostTests --skip theSeatCycle
    ///
    /// ## Why the send is not here
    ///
    /// A measurement, not a preference: `CGEventPostToPid` aimed at the calling
    /// process ends `swiftpm-testing-helper` on the spot, exit code zero, no
    /// crash report, with the two events already routed. So a target that is our
    /// own window carries every step of the cycle except the one that posts, and
    /// the whole cycle including the post is the Live tier's, against a black box
    /// in another process, which is where it belongs anyway.
    ///
    /// It leaves the machine as it found it on every path: the display goes away,
    /// its absence is confirmed against the online list, the tap is released and
    /// the window is back at the frame it started from.
    @Suite("The seat host on the running machine", .serialized)
    @MainActor
    struct SeatHostTests {

        @Test("start, adopt, hold, release and stop, on a real display",
              .enabled(if: tierEnabled()))
        func theSeatCycle() async throws {

            AppKitPump.prepare()
            try #require(Permissions.preflight(.accessibility), "Accessibility is not granted")

            let baselineOnline = Set(try DisplayList.online())
            let baselineMain   = CGMainDisplayID()

            // MARK: the target, on a physical display, where the person's is
            let physical = try #require(NSScreen.screens.first)
            let window   = NSWindow(
                contentRect: NSRect(
                    x     : physical.frame.minX + 120,
                    y     : physical.frame.minY + 120,
                    width : 420,
                    height: 320
                ),
                styleMask  : [.titled],
                backing    : .buffered,
                defer      : false,
                screen     : physical
            )
            window.title       = "AgentSeatKit host cycle"
            window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
            window.orderFrontRegardless()
            AppKitPump.run(for: 0.3)
            // `orderOut` and not `close`: closing the last window of a
            // process that never called `NSApplication.run()` takes the
            // process down while a later suite is pumping, which showed up as
            // the next display suite ending silently with exit code 0.
            defer { window.orderOut(nil) }

            let windowNumber  = Int(window.windowNumber)
            let originalFrame = try #require(
                WindowServerProbe.geometry(of: windowNumber)?.frame,
                "the window server does not know our own window"
            )

            // MARK: start, which is one atomic step
            // The tier already drives `nextEvent` in `AppKitPump`; the host
            // uses that same function rather than opening a second call site
            // of its own (ADR 0008).
            let host = SeatHost(configuration: SeatHostConfiguration(
                eventLoopPump: { AppKitPump.run(for: Double($0.components.attoseconds) / 1e18
                    + Double($0.components.seconds)) }
            ))
            var isUp = false
            defer {
                if isUp { _ = Task { await host.stop() } }
            }

            let seen = SeatEventLog()

            try await host.start()
            isUp = true

            #expect(host.state == .ready)
            let displayID = try #require(host.displayID)
            #expect(try DisplayList.online().contains(displayID))

            // The seat limit of v1, which is one line to change for `n`.
            let seat = try host.makeSeat()
            #expect(throws: SessionFailure.seatLimitReached) { _ = try host.makeSeat() }


            // MARK: adopt, confirmed by the window server and not by AX
            let observed = try #require(WindowServerProbe.geometry(of: windowNumber))
            #expect(observed.processID == ProcessInfo.processInfo.processIdentifier)
            let reference = observed.replacingFrame(originalFrame)
            let adopted = try await seat.adopt(
                reference,
                platform: AppKitPlatform(),
                title   : window.title
            )

            #expect(seat.state == .ready)
            #expect(
                CGDisplayBounds(displayID).contains(adopted.reference.frame),
                "the window is not inside the virtual display: \(adopted.reference.frame)"
            )
            #expect(seat.isStaged(adopted))

            // MARK: the hold, and what it refuses
            let turn = try await seat.acquire()
            #expect(turn.generation == 1)
            #expect(!turn.seatChangedSinceLastHold)

            let foreign = AdoptedWindow(
                reference    : WindowReference(processID: 1, windowNumber: 1, frame: .zero),
                originalFrame: .zero
            )
            let point = InputLocation(
                screenPoint       : CGPoint(
                    x: adopted.reference.frame.midX,
                    y: adopted.reference.frame.midY
                ),
                windowPointFromTop: CGPoint(x: 10, y: 10)
            )
            await #expect(throws: SessionFailure.windowNotAdopted(windowNumber: 1)) {
                try await seat.send(.click(point), to: foreign, turn: turn, platform: AppKitPlatform())
            }

            #expect(seat.unconfirmedCommandCount == 0)
            _ = await seat.concludeObservation()
            try seat.release(turn)
            #expect(seat.currentTurn == nil)

            // The seat's every wait pumps the event loop rather than suspending
            // (`EventLoopWait`), so nothing else on the main actor has run yet:
            // the stream's consumers need an explicit turn before what they
            // buffered can be asserted on.
            _ = seen

            // MARK: back to the User Seat
            let outcome = await seat.release(adopted, .returnToUserSeat)
            #expect(outcome == .returned, "the window did not go home: \(outcome)")

            let home = WindowServerProbe.geometry(of: windowNumber)?.frame
            #expect(
                home.map {
                    abs($0.minX - originalFrame.minX) <= 2 && abs($0.minY - originalFrame.minY) <= 2
                } == true,
                "the window came back to \(String(describing: home)) instead of \(originalFrame)"
            )

            // MARK: stop
            let report = await host.stop()
            isUp = false

            #expect(report.displayRemoved, "the virtual display was left online")
            #expect(report.fenceReleased, "the fence's tap was left installed")
            #expect(report.mainDisplayRestored)
            #expect(report.topologyRestoration != .topologyChangedByUser,
                    "the display set changed during the run")
            #expect(host.state == .off)

            print("""
                seat cycle: removal \(report.removalNanoseconds / 1_000_000) ms, \
                topology \(String(describing: report.topologyRestoration)), \
                \(seen.events.count) events
                """)

            #expect(Set(try DisplayList.online()) == baselineOnline)
            #expect(CGMainDisplayID() == baselineMain)
        }
    }
}
