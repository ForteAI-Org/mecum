//
//  LiveStage.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

import AppKit
import CoreGraphics
import CursorGuard
import Foundation
import PrivateSymbols
import SeatCore
import SeatInput
import SeatSession
import Testing
import VirtualScreens
import WindowPlacement

/// LiveStage is everything a Live suite needs standing up around it: the two
/// targets, the host, the seat, the fence, and the promise that all of it is
/// taken down again and the person's desktop left as it was found.
///
/// It exists as a scope and not as a value a caller builds, because the setup
/// is held together by `defer`: a helper that *returned* a stage would run every
/// one of those on the way out and hand the caller a torn down seat. So the
/// caller passes a body and the stage lives exactly as long as it.
///
/// Before this, the whole thing was written inline inside the input matrix.
/// That was fine while there was one Live suite and stopped being fine at two:
/// the shortcut isolation rows and the manual rows need the same hundred and
/// twenty lines, and three copies of a setup nobody can run from a laptop is
/// how a Live tier rots.
@MainActor
struct LiveStage {

    /// Nil when the consumer's instrumented binary is not on this machine. The
    /// kit ships no application, so a row that needs one says so and is skipped
    /// rather than inventing a target.
    let fixture      : FixtureTarget?
    let chrome       : ChromeTarget?
    let host         : SeatHost
    let seat         : AgentSeat
    let fence        : CursorFence
    let virtualBounds: CGRect
    let events       : SeatEventLog

    /// The User Seat as it was before anything was launched. Every suite
    /// compares against it, so it is taken once and handed down.
    let personBefore: UserSeatState

    /// Where each target's window was found, so it can be put back if the seat
    /// did not manage to.
    let fixtureHome: CGRect?
    let chromeHome : CGRect?

    /// Every target this stage brought up, for a suite that drives all of them.
    var targets: [any MatrixTarget] {
        (fixture.map { [$0 as any MatrixTarget] } ?? []) + (chrome.map { [$0] } ?? [])
    }

    /// Stands the whole thing up, runs `body`, and takes it down again.
    ///
    /// The teardown assertions are here and not in the body on purpose: every
    /// suite has to prove it left no display online, no tap installed and the
    /// person's topology untouched, and a suite that forgot to check would look
    /// exactly like a suite that passed.
    static func run(
        needsFixture : Bool = true,
        needsChrome  : Bool = true,
        configuration: SeatHostConfiguration = SeatHostConfiguration(),
        _ body       : (LiveStage) async throws -> Void
    ) async throws {

        LivePump.prepare()

        let build = BuildIdentity.current
        if (try? Ledger.bundled())?.entry(for: build) == nil {
            print("running on \(build.osVersion), which the Ledger does not describe: "
                + "every measurement below is marked unvalidated")
        }

        #expect(Permissions.preflight(.postEvent),     "Post Event is not granted to the test runner")
        #expect(Permissions.preflight(.accessibility), "Accessibility is not granted to the test runner")

        // A run that crashed left its display behind: its `defer` never ran,
        // because a dead process runs no `defer`. Starting a second one on top
        // would stack a second ghost screen onto the person's desktop, and the
        // cursor can wander into either. The vendor and product are the kit's
        // own, written by `VirtualDisplay`, so this is exact and not a guess.
        for id in try DisplayList.online() where
            CGDisplayVendorNumber(id) == VirtualDisplayConfiguration.vendorID
            && CGDisplayModelNumber(id) == VirtualDisplayConfiguration.productID {
            throw LiveFailure.unsupported(
                "display \(id) at \(CGDisplayBounds(id)) is a virtual display a previous run "
                    + "left behind, and no API removes another process's one. It usually goes "
                    + "away by itself once the last window leaves it; if it does not, log out "
                    + "and back in. Nothing is started on top of it."
            )
        }

        let baselineOnline = Set(try DisplayList.online())
        let baselineMain   = CGMainDisplayID()
        let personBefore   = UserSeatState.capture()

        if let settle = settleOverrideMilliseconds() {
            print("settle calibration run: \(settle) ms")
        }
        if let policy = modifierPolicyOverride() {
            print("modifier policy override: \(policy)")
        }

        // MARK: the targets, both left exactly where they were found

        let fixture = needsFixture ? try FixtureTarget.launched() : nil
        defer { fixture?.terminate() }
        if let firstReport = fixture?.latest {
            #expect(
                firstReport.controlsAreHitTestable,
                Comment(rawValue: "the instrumented target opened with an unreachable control at "
                    + "\(Int(firstReport.windowWidth)) by \(Int(firstReport.windowHeight)): "
                    + firstReport.controlHitTestReport)
            )

            // A fixture that came up in front of the person's own application
            // hands the focus straight back: every Live row is about a target
            // that is *not* the front application.
            if firstReport.applicationIsActive,
               let previous = NSRunningApplication(processIdentifier: personBefore.frontmostProcessID),
               previous.processIdentifier != firstReport.processID {
                previous.activate()
                LivePump.run(for: 0.5)
            }
        }

        let browser = needsChrome ? try openProbePage(handingFocusBackTo: personBefore) : nil
        let chrome = browser?.target
        defer { browser?.owner.terminate() }

        // MARK: the seat, whole, from the kit

        let host = SeatHost(configuration: configuration)
        var hostIsUp = false
        defer {
            if hostIsUp { Task { await host.stop() } }
        }
        try await host.start()
        hostIsUp = true
        #expect(host.state == .ready, "the host came up \(host.state.rawValue)")

        let seat   = try host.makeSeat()
        let events = SeatEventLog()
        let seatEventTask = Task { @MainActor in
            for await event in seat.events { events.record(event) }
        }
        let hostEventTask = Task { @MainActor in
            for await event in host.events { events.record(event) }
        }
        defer {
            seatEventTask.cancel()
            hostEventTask.cancel()
        }

        let displayID     = try #require(host.displayID)
        let virtualBounds = CGDisplayBounds(displayID)
        let fence         = try #require(host.fence, "the host started without a fence")
        print("virtual display \(displayID) at \(virtualBounds), fence \(fence.isActive)")

        let stage = LiveStage(
            fixture      : fixture,
            chrome       : chrome,
            host         : host,
            seat         : seat,
            fence        : fence,
            virtualBounds: virtualBounds,
            events       : events,
            personBefore : personBefore,
            fixtureHome  : fixture.flatMap {
                WindowServerProbe.geometry(of: $0.window.windowNumber)?.frame
            },
            chromeHome   : chrome.map(\.originalFrame)
        )

        var bodyFailure: (any Error)?
        do {
            try await body(stage)
        } catch {
            bodyFailure = error
        }

        // MARK: the teardown every suite owes

        for _ in 0..<40 { await Task.yield() }
        let teardown = await host.stop()
        hostIsUp = false
        LivePump.run(for: 0.4)

        print(
            "teardown: display removed \(teardown.displayRemoved), "
                + "fence released \(teardown.fenceReleased), "
                + "topology \(String(describing: teardown.topologyRestoration)), "
                + "\(events.events.count) events"
        )
        #expect(teardown.displayRemoved, "the virtual display was left online")
        #expect(teardown.fenceReleased, "the fence's tap was left installed")
        #expect(teardown.topologyRestoration != .topologyChangedByUser,
                "the display set changed during the run, the topology was left alone")
        #expect(
            events.events.contains { event in
                if case .hostStateChanged(_, let to, _) = event { return to == .ready }
                return false
            },
            "the host's transitions never reached the event stream"
        )
        #expect(Set(try DisplayList.online()) == baselineOnline, "a display was left behind")
        #expect(CGMainDisplayID() == baselineMain)
        if let bodyFailure { throw bodyFailure }
    }

    /// Gives a target's window back and puts it where it was found, when the
    /// seat's own return did not.
    func giveBack(_ adopted: AdoptedWindow, of target: any MatrixTarget, home: CGRect?) async {
        _ = await seat.release(adopted, .returnToUserSeat)
        if let home, WindowServerProbe.geometry(of: target.window.windowNumber)
            .map({ !rectanglesMatchLoosely($0.frame, home) }) == true {
            restore(target.window, to: home.origin)
        }
        LivePump.run(for: 1.0)
    }

    /// The home frame recorded for this target, whichever of the two it is.
    func home(of target: any MatrixTarget) -> CGRect? {
        target.window.windowNumber == fixture?.window.windowNumber ? fixtureHome : chromeHome
    }
}

/// Hands a window to the seat and makes sure it is on stage at full size
/// before anything is posted to it.
///
/// The move, the two agreeing window server readings and the raise are all
/// the seat's now (`adopt`, `stage`). What is still the harness's is the
/// decision that a stashed window has to be staged at all, because Stage
/// Manager stashes whatever was on stage when a second window arrives and
/// only the caller knows which of its targets it wants to act on next.
@MainActor
func adopt(
    _ target: any MatrixTarget,
    onto seat: AgentSeat,
    bounds   : CGRect
) async throws -> AdoptedWindow {

    var adopted = try await seat.adopt(
        target.fullSizeReference,
        platform: target.platform,
        title   : target.name
    )
    LivePump.run(for: 0.4)
    target.refresh()

    if !seat.isStaged(adopted) || !target.isStaged(within: bounds) {
        // Stage Manager stashed it on arrival. `stage` is `kAXRaiseAction`
        // plus two agreeing readings from the window server, and it is the
        // reason a Command is never posted at a thumbnail's coordinates.
        //
        // Timed here and not only in the benchmark: this is the one place a
        // window the person's own Stage Manager really stashed goes through
        // `stage`, and the budget of spec section 8 is written about
        // exactly that window (1 s p95, against 532 ms measured on
        // Chrome). The benchmark cannot manufacture the stash without
        // activating an application, which the kit must never do.
        let stashed = WindowServerProbe.geometry(of: target.window.windowNumber)?.frame
        let start   = DispatchTime.now().uptimeNanoseconds
        adopted = try await seat.stage(adopted)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        print(String(
            format: "stage: %@ came on stage in %.0f ms, from %@",
            target.name, Double(elapsed) / 1e6,
            String(describing: stashed ?? .null)
        ))
        #expect(
            elapsed <= 1_000_000_000,
            Comment(rawValue: "stage took \(elapsed / 1_000_000) ms, budget 1000 ms")
        )
        LivePump.run(for: 0.4)
    }
    target.refresh()

    let staged = WindowServerProbe.geometry(of: target.window.windowNumber)?.frame ?? .null
    #expect(
        target.isStaged(within: bounds),
        "\(target.name) never came on stage at full size: \(staged)"
    )
    return adopted
}

/// Two frames that agree within a couple of points, for deciding whether a
/// window the seat already returned still needs putting back by hand.
@MainActor
func rectanglesMatchLoosely(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    abs(lhs.minX - rhs.minX) <= 2 && abs(lhs.minY - rhs.minY) <= 2
}

@MainActor
func restore(_ window: WindowReference, to origin: CGPoint) {
    do {
        try WindowRelocator.move(window, to: origin)
        LivePump.run(for: 0.5)
    } catch {
        Issue.record("could not put window \(window.windowNumber) back: \(error)")
    }
}


@MainActor
func openProbePage(
    handingFocusBackTo person: UserSeatState
) throws -> (target: ChromeTarget, owner: OwnBrowserTarget)? {
    guard let page = Bundle.module.url(forResource: "probe-page", withExtension: "html") else {
        Issue.record("probe-page.html is not in the test bundle")
        return nil
    }
    let owner = try OwnBrowserTarget.launched(
        pageHTML: String(contentsOf: page, encoding: .utf8)
    )
    let reference = owner.reference
    let target = ChromeTarget(window: ChromeWindow(
        processID   : reference.processID,
        windowNumber: reference.windowNumber,
        frame       : reference.frame,
        title       : ""
    ))
    do {
        try handBackLiveFocus(
            to      : person,
            avoiding: target.processID
        )
    } catch {
        owner.terminate()
        throw error
    }
    print("chrome window \(target.windowNumber) of pid \(target.processID), \(target.diagnostics)")
    return (target, owner)
}

/// A launched browser may activate after its first NSRunningApplication read.
/// Setup hands focus back regardless of that transient flag and requires
/// three agreeing foreground reads before any test Command is attempted.
@MainActor
func handBackLiveFocus(
    to person: UserSeatState,
    avoiding target: Int32
) throws {
    guard person.frontmostProcessID != target,
          let previous = NSRunningApplication(processIdentifier: person.frontmostProcessID),
          !previous.isTerminated
    else { throw LiveFailure.unsupported("The live setup lost its original foreground application") }
    previous.activate()
    var agreements = 0
    let restored = LivePump.run(
        until: {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == person.frontmostProcessID {
                agreements += 1
            } else {
                agreements = 0
            }
            return agreements >= 3
        },
        timeout: 3
    )
    guard restored else {
        throw LiveFailure.unsupported("The live setup did not restore a stable foreground application")
    }
}


/// What the event stream carried during the run, which is the channel a
/// consumer reads its Issues and its recovery progress from.
@MainActor
final class SeatEventLog {
private(set) var events: [SeatEvent] = []
func record(_ event: SeatEvent) { events.append(event) }
}
