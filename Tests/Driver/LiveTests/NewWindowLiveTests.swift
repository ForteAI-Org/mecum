//
//  NewWindowLiveTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 15/09/2026.
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
import WindowPlacement

/// The window watch on real windows: an application the seat is already driving
/// opens another window of its own, and that window is found, moved onto the
/// Virtual Display and then actually used.
///
/// The two rows are deliberately separate evidence and the report keeps them
/// apart. The fixture row drives the whole path end to end, and it is a
/// cooperative target: it publishes where to click and counts what arrived, so
/// what it proves is the kit's own logic and not that any application behaves
/// this way. The second row drives a real third-party application named by the
/// environment, which proves nothing about the fixture's cooperation and
/// everything about whether the window server enumeration and `AXPosition`
/// reach that application's windows at all.
@Suite(.serialized)
@MainActor
struct NewWindowLiveTests {

    /// A host that follows the windows of the applications its seat drives.
    /// Everything else is the configuration the kit was benchmarked with.
    static let following = SeatHostConfiguration(followsNewWindows: true)

    /// The bundle identifier of a third-party application to run the second row
    /// against, or nil. It is an environment variable and not a name in this
    /// repository on purpose: the kit has no recipe for any particular
    /// application, and a suite that hard-coded one would be the first half of
    /// writing one.
    nonisolated static var followedBundleIdentifier: String? {
        ProcessInfo.processInfo.environment["AGENTSEAT_FOLLOW_APP"]
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    nonisolated static var followedApplicationReason: String? {
        guard let followedBundleIdentifier else {
            return "AGENTSEAT_FOLLOW_APP=<bundle identifier> names the running third-party "
                + "application this row follows. The kit ships no recipe for one."
        }
        return runningApplication(followedBundleIdentifier) == nil
            ? "no running application has bundle identifier \(followedBundleIdentifier)."
            : nil
    }

    nonisolated static func runningApplication(_ bundleIdentifier: String) -> NSRunningApplication? {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }

    /// The two frames of reference for a point inside a window that is not the
    /// harness's own target: the secondary window has no `MatrixTarget` and its
    /// geometry has to be read for itself.
    static func location(of point: CGPoint, in windowNumber: Int) throws -> InputLocation {
        guard let reference = WindowServerProbe.geometry(of: windowNumber),
              let geometry  = WindowGeometryProbe.observation(of: reference),
              let location  = InputLocation(screenPoint: point, observedIn: geometry)
        else { throw LiveFailure.windowGeometryUnavailable(windowNumber) }
        return location
    }

    static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start) / 1e6
    }

    /// Every on-screen surface of a process, as the watch itself reads them.
    /// Printed rather than asserted: which levels an application draws at is
    /// the compatibility matrix, and a row that asserted a level would be
    /// writing a recipe for one application.
    static func printSurfaces(of processID: Int32, label: String) {
        guard let surfaces = WindowServerProbe.surfaces(ownedBy: [processID]) else {
            print("MW02 \(label): the window server did not answer")
            return
        }
        print("MW02 \(label): \(surfaces.count) on-screen surfaces")
        for surface in surfaces {
            print(String(
                format: "     window %d level %d visible %@ frame %@",
                surface.reference.windowNumber, surface.level,
                surface.isVisible ? "yes" : "no",
                String(describing: surface.reference.frame)
            ))
        }
    }

    static func refusals(_ events: SeatEventLog) -> [(Int, WindowTransferRefusal)] {
        events.events.compactMap {
            guard case .windowTransferRefused(let windowNumber, _, let reason) = $0 else { return nil }
            return (windowNumber, reason)
        }
    }

    // MARK: The cooperative target, whole path

    @Test("a second window the agent's own click opened is found, moved and used",
          .enabled(if: liveSkipReason(needsFixture: true) == nil,
                   Comment(rawValue: liveSkipReason(needsFixture: true) ?? "")))
    func aSecondWindowOfTheSameProcess() async throws {

        try await LiveStage.run(
            needsFixture : true,
            needsChrome  : false,
            configuration: Self.following
        ) { stage in

            let fixture = try #require(stage.fixture)
            let seat    = stage.seat
            let person  = stage.personBefore
            let hand    = stage.fence.snapshot().observedEventCount

            print("MW02 macOS \(BuildIdentity.current.osVersion), fixture pid "
                + "\(fixture.latest.processID), person in \(person.frontmostName)")

            let main = try await adopt(fixture, onto: seat, bounds: stage.virtualBounds)
            Self.printSurfaces(of: fixture.latest.processID, label: "fixture before the click")

            fixture.refresh()
            let openPoint = try #require(
                fixture.latest.openWindowQuartzX.map { x in
                    CGPoint(x: x, y: fixture.latest.openWindowQuartzY ?? 0)
                },
                "the fixture binary does not publish openWindowQuartzX/Y: it is older than MW-02"
            )
            let mainPressesBefore = fixture.latest.buttonPressCount

            // MARK: the Command that opens the window

            let location = try fixture.location(of: openPoint)
            let turn     = try await seat.acquire()
            let posted   = DispatchTime.now().uptimeNanoseconds
            let receipt  = try await seat.send(
                .click(location),
                observation: try await liveObservation(seat),
                turn       : turn,
                platform   : fixture.platform
            )
            let opened = LivePump.run(
                until  : { fixture.refresh(); return !(fixture.latest.secondaryWindows ?? []).isEmpty },
                timeout: 5
            )
            try seat.confirm(receipt, opened ? .observed : .absent)
            _ = await seat.concludeObservation()
            try seat.release(turn)
            #expect(opened, "the click never opened a second window")

            let openedAfter = Self.milliseconds(since: posted)
            let secondary   = try #require(fixture.latest.secondaryWindows?.first)
            print(String(
                format: "MW02 second window %d opened %.0f ms after the click, at %@",
                secondary.windowNumber, openedAfter, String(describing: secondary.frame)
            ))

            // MARK: the watch, which nothing here asked to run

            let transferred = await LivePump.settle(
                until  : { seat.adoptedWindows.count == 2 },
                timeout: 10
            )
            let transferredAfter = Self.milliseconds(since: posted)
            Self.printSurfaces(of: fixture.latest.processID, label: "fixture after the transfer")
            print(String(
                format: "MW02 transfer: %@ after %.0f ms, %d scans, adopted %@",
                transferred ? "done" : "never happened", transferredAfter,
                seat.windowFollowScanCount, String(describing: seat.adoptedWindows.map(\.id))
            ))
            #expect(transferred, Comment(rawValue: "the second window was never brought in. "
                + "Refusals: \(Self.refusals(stage.events))"))

            let follower = try #require(seat.adoptedWindows.first { $0.id != main.id })
            let placed   = try #require(WindowServerProbe.geometry(of: follower.id)?.frame)
            print("MW02 the second window sits at \(placed), display \(stage.virtualBounds)")
            #expect(stage.virtualBounds.contains(placed),
                    "the window was adopted without being inside the virtual display")
            #expect(seat.currentTarget?.id == follower.id, "the window found last is the target")

            for _ in 0..<40 { await Task.yield() }
            let detected = stage.events.events.contains { event in
                guard case .targetChanged(_, let to, let reason) = event else { return false }
                return reason == .detected && to.windowNumber == follower.id
            }
            #expect(detected, "the transfer was not published as a detection")
            #expect(Self.refusals(stage.events).isEmpty,
                    Comment(rawValue: "refusals: \(Self.refusals(stage.events))"))

            // MARK: and it works where it was put

            fixture.refresh()
            let followerBefore = try #require(
                fixture.latest.secondaryWindow(follower.id)
            )
            let buttonPoint = CGPoint(
                x: followerBefore.buttonQuartzX,
                y: followerBefore.buttonQuartzY
            )
            let secondTurn = try await seat.acquire()
            let secondSend = try await seat.send(
                .click(try Self.location(of: buttonPoint, in: follower.id)),
                observation: try await liveObservation(seat),
                turn       : secondTurn,
                platform   : fixture.platform
            )
            let landed = LivePump.run(
                until  : {
                    fixture.refresh()
                    return (fixture.latest.secondaryWindow(follower.id)?.pressCount ?? 0)
                        > followerBefore.pressCount
                },
                timeout: 5
            )
            try seat.confirm(secondSend, landed ? .observed : .absent)
            _ = await seat.concludeObservation()
            try seat.release(secondTurn)

            fixture.refresh()
            let followerAfter = try #require(fixture.latest.secondaryWindow(follower.id))
            print("MW02 click in the second window: presses \(followerBefore.pressCount) -> "
                + "\(followerAfter.pressCount), mouse downs \(followerAfter.mouseDownCount), "
                + "first window presses \(mainPressesBefore) -> \(fixture.latest.buttonPressCount), "
                + "routed to \(secondSend.route.windowNumber)")

            #expect(secondSend.route.windowNumber == follower.id)
            #expect(landed, "the second window was moved and is not usable where it was put")
            #expect(fixture.latest.buttonPressCount == mainPressesBefore,
                    "the click reached the window the second one was opened from")

            // MARK: give everything back

            _ = await seat.release(follower)
            await stage.giveBack(main, of: fixture, home: stage.fixtureHome)

            let after    = UserSeatState.capture()
            let physical = stage.fence.snapshot().observedEventCount &- hand
            print("MW02 person after: \(after.frontmostName) (\(after.frontmostProcessID)) "
                + "cursor \(after.cursor), \(physical) physical events during the run")

            #expect(after.frontmostProcessID == person.frontmostProcessID,
                    "the person's frontmost application changed to \(after.frontmostName)")
            if physical == 0 {
                #expect(after.cursor == person.cursor,
                        "the physical cursor moved with no physical input to explain it")
            } else if after.cursor != person.cursor {
                Issue.record(Comment(rawValue: "inconclusive: the cursor moved with \(physical) "
                    + "physical events during the run. Rerun without touching the machine."))
            }
        }
    }

    // MARK: A third-party application, detection and transfer

    @Test("a third-party application's window is enumerated, adopted, and followed back",
          .enabled(if: liveSkipReason() == nil && followedApplicationReason == nil,
                   Comment(rawValue: liveSkipReason() ?? followedApplicationReason ?? "")))
    func aThirdPartyApplicationIsFollowed() async throws {

        let bundleIdentifier = try #require(Self.followedBundleIdentifier)
        let application      = try #require(Self.runningApplication(bundleIdentifier))
        let processID        = application.processIdentifier

        try await LiveStage.run(
            needsFixture : false,
            needsChrome  : false,
            configuration: Self.following
        ) { stage in

            let seat   = stage.seat
            let person = stage.personBefore
            let hand   = stage.fence.snapshot().observedEventCount

            print("MW02 macOS \(BuildIdentity.current.osVersion), following "
                + "\(application.localizedName ?? bundleIdentifier) "
                + "\(application.bundleURL?.lastPathComponent ?? "") pid \(processID)")
            Self.printSurfaces(of: processID, label: "third-party before adoption")

            // The largest visible surface with an accessibility body: largest
            // and not named, because the suite has no recipe for this app.
            let surfaces = try #require(
                WindowServerProbe.surfaces(ownedBy: [processID]),
                "the window server did not answer for this process"
            )
            let movable = surfaces
                .filter(\.isVisible)
                .filter { $0.level != WindowServerProbe.popUpMenuLevel }
                .compactMap { surface -> (WindowSurface, CGRect)? in
                    guard let body = try? WindowRelocator.frame(of: surface.reference),
                          body.width > 0, body.height > 0 else { return nil }
                    return (surface, body)
                }
                .sorted { $0.1.width * $0.1.height > $1.1.width * $1.1.height }

            print("MW02 third-party: \(movable.count) of \(surfaces.count) surfaces have an "
                + "accessibility body and could take AXPosition")
            let chosen = try #require(
                movable.first,
                "no on-screen window of this application has an accessibility body to move"
            )
            guard chosen.1.width <= stage.virtualBounds.width,
                  chosen.1.height <= stage.virtualBounds.height else {
                Issue.record(Comment(rawValue: "inconclusive: the application's largest window is "
                    + "\(chosen.1.size), which does not fit the virtual display "
                    + "\(stage.virtualBounds.size). Nothing was moved."))
                return
            }

            // MARK: the transfer, which is the AXPosition question for this family

            let started  = DispatchTime.now().uptimeNanoseconds
            let adopted  = try await seat.adopt(
                chosen.0.reference.replacingFrame(chosen.1),
                platform: ChromiumPlatform()
            )
            let adoptedAfter = Self.milliseconds(since: started)
            let home         = adopted.originalFrame
            LivePump.run(for: 0.5)

            let placed = try #require(WindowServerProbe.geometry(of: adopted.id)?.frame)
            print(String(
                format: "MW02 third-party window %d adopted in %.0f ms, from %@ to %@",
                adopted.id, adoptedAfter, String(describing: home), String(describing: placed)
            ))
            #expect(stage.virtualBounds.contains(placed))

            // MARK: the application puts its own window back, and the watch answers

            let commandsBefore = seat.unconfirmedCommandCount
            let scansBefore    = seat.windowFollowScanCount
            let leftAt         = DispatchTime.now().uptimeNanoseconds
            try WindowRelocator.move(adopted.reference, to: home.origin)
            LivePump.run(for: 0.3)

            let returned = await LivePump.settle(
                until  : {
                    guard let frame = WindowServerProbe.geometry(of: adopted.id)?.frame
                    else { return false }
                    return stage.virtualBounds.contains(frame)
                },
                timeout: 12
            )
            let returnedAfter = Self.milliseconds(since: leftAt)
            print(String(
                format: "MW02 third-party window left the display and came back: %@ after %.0f ms, "
                    + "%d passes, seat %@",
                returned ? "yes" : "no", returnedAfter,
                seat.windowFollowScanCount - scansBefore, seat.state.rawValue
            ))
            Self.printSurfaces(of: processID, label: "third-party after the return")

            #expect(returned, Comment(rawValue: "the window stayed on the physical display. "
                + "Refusals: \(Self.refusals(stage.events)), seat \(seat.state.rawValue)"))
            #expect(seat.unconfirmedCommandCount == commandsBefore,
                    "the watch posted input, which it must never do")

            await stage.giveBack(adopted, of: ThirdPartyWindow(reference: adopted.reference),
                                 home: home)
            let back = WindowServerProbe.geometry(of: adopted.id)?.frame
            print("MW02 third-party window is back at \(String(describing: back)), home \(home)")

            let after    = UserSeatState.capture()
            let physical = stage.fence.snapshot().observedEventCount &- hand
            print("MW02 person after: \(after.frontmostName) (\(after.frontmostProcessID)) "
                + "cursor \(after.cursor), \(physical) physical events during the run")
            #expect(after.frontmostProcessID == person.frontmostProcessID,
                    "the person's frontmost application changed to \(after.frontmostName)")
        }
    }
}

/// The least a window of somebody else's application has to be for `giveBack`
/// to put it back where it was found. It drives nothing and reads no counter:
/// a third-party application publishes no report, which is exactly why the
/// row above asserts geometry and never an effect.
@MainActor
final class ThirdPartyWindow: MatrixTarget {

    let name     = "third-party window"
    let family   = TargetFamily.chromium
    let platform: any InputPlatform = ChromiumPlatform()

    private let reference: WindowReference

    init(reference: WindowReference) { self.reference = reference }

    var window: WindowReference {
        WindowServerProbe.geometry(of: reference.windowNumber) ?? reference
    }

    var expectedSize       : CGSize { reference.frame.size }
    var isInternallyActive : Bool   { false }
    var diagnostics        : String { "window \(reference.windowNumber)" }

    func refresh() {}
    func state() -> [String: Double] { [:] }
    func clickPoint() -> CGPoint? { nil }
    func scrollPoint() -> CGPoint? { nil }
    func dragEndpoints() -> (start: CGPoint, end: CGPoint)? { nil }
}
