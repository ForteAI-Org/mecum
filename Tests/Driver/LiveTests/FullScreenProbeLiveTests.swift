//
//  FullScreenProbeLiveTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 15/09/2026.
//

import AppKit
import ApplicationServices
import CoreGraphics
import CursorGuard
import Foundation
import PrivateSymbols
import SeatCore
import SeatInput
import SeatSession
import Testing
import WindowPlacement

/// MW-03 on a real window and the real Virtual Display: a window in **native
/// macOS fullscreen** is handed to the seat, which leaves fullscreen itself,
/// moves it, keeps it usable, takes a second window with it, and gives it back.
///
/// Every accessibility write here belongs to the kit. The suite's own writes
/// are setup only: putting the window into fullscreen in the first place, and
/// handing the seat back to the person so that the measured half is the
/// background case the ticket calls unproven.
///
/// Nothing writes a system setting. Stage Manager is read and reported as
/// found, exactly as `MultiWindowLiveTests` does.
@Suite(.serialized)
@MainActor
struct FullScreenProbeLiveTests {

    /// The experiment, both halves of it, which is the whole point of the row:
    /// with the defaults this window would be refused.
    static let experimental = SeatHostConfiguration(
        followsNewWindows         : true,
        transfersFullScreenWindows: true
    )

    static var stageManagerIsEnabled: Bool {
        UserDefaults(suiteName: "com.apple.WindowManager")?
            .object(forKey: "GloballyEnabled") as? Bool ?? false
    }

    // MARK: Setup writes, and only setup

    static func windowElement(of window: WindowReference) -> AXUIElement? {
        let application = AXUIElementCreateApplication(window.processID)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application, kAXWindowsAttribute as CFString, &raw
        ) == .success, let listed = raw as? [AXUIElement] else { return nil }
        return listed.first { WindowRelocator.windowNumber(of: $0) == window.windowNumber }
    }

    @discardableResult
    static func enterFullScreen(_ window: WindowReference) -> Bool {
        guard let element = windowElement(of: window) else { return false }
        return AXUIElementSetAttributeValue(
            element, "AXFullScreen" as CFString, true as CFBoolean
        ) == .success
    }

    /// Waits for the observable end of a transition, pumping. It is the suite's
    /// own copy because setup must not depend on the thing under test.
    static func awaitFullScreen(_ wanted: Bool, of window: WindowReference) -> Bool {
        var previous: CGRect?
        return LivePump.run(
            until: {
                guard (try? WindowRelocator.fullScreen(of: window))?.value == wanted,
                      let frame = WindowServerProbe.geometry(of: window.windowNumber)?.frame
                else { previous = nil; return false }
                defer { previous = frame }
                return previous.map { rectanglesMatchLoosely($0, frame) } ?? false
            },
            timeout: 8
        )
    }

    // MARK: The row

    @Test("MW03: the seat takes a window out of native fullscreen, onto the virtual display, and gives it back",
          .enabled(if: liveSkipReason(optIn: "AGENTSEAT_FULLSCREEN_PROBE", needsFixture: true) == nil,
                   Comment(rawValue: liveSkipReason(optIn: "AGENTSEAT_FULLSCREEN_PROBE",
                                                    needsFixture: true) ?? "")))
    func fullScreenWindowRoundTrip() async throws {

        try await LiveStage.run(
            needsFixture : true,
            needsChrome  : false,
            configuration: Self.experimental
        ) { stage in

            let fixture = try #require(stage.fixture)
            let seat    = stage.seat
            let person  = stage.personBefore
            let hand    = stage.fence.snapshot().observedEventCount

            print("MW03 macOS \(BuildIdentity.current.osVersion), stage manager "
                + "\(Self.stageManagerIsEnabled ? "ON" : "OFF") (read, never written), "
                + "person in \(person.frontmostName) (\(person.frontmostProcessID))")

            // MARK: setup: into fullscreen, then the seat back to the person

            #expect(Self.enterFullScreen(fixture.window),
                    "this fixture cannot be put into native fullscreen, so nothing below is measured")
            try #require(Self.awaitFullScreen(true, of: fixture.window),
                         "the window never reached native fullscreen")
            let fullScreenFrame = WindowServerProbe.geometry(of: fixture.window.windowNumber)?.frame
            print("MW03 in native fullscreen at \(String(describing: fullScreenFrame ?? .null))")

            if let previous = NSRunningApplication(processIdentifier: person.frontmostProcessID) {
                previous.activate()
                _ = LivePump.run(
                    until  : { NSWorkspace.shared.frontmostApplication?.processIdentifier
                                == person.frontmostProcessID },
                    timeout: 3
                )
            }
            let spaceLeft = LivePump.run(
                until  : { !WindowRelocator.spaceIsOnScreen(for: fixture.window) },
                timeout: 8
            )
            print("MW03 the fullscreen Space left the screen: \(spaceLeft)")
            try #require(spaceLeft, "the Space gate never cleared, so the seat would rightly refuse")

            // MARK: what the kit sees before it writes anything

            let reading = try WindowRelocator.fullScreen(of: fixture.window)
            print("MW03 AXFullScreen reads \(reading); relocator move while fullscreen accepted "
                + "\((try? WindowRelocator.move(fixture.window, to: CGPoint(x: 40, y: 40))) != nil)")
            #expect(reading == .writable(true),
                    "the attribute is not writable on this window, which is the not-supported case")

            let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier

            // MARK: the seat's own path, with no activation added anywhere in it

            let start   = DispatchTime.now().uptimeNanoseconds
            let adopted = try await adopt(fixture, onto: seat, bounds: stage.virtualBounds)
            let cost    = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1e6

            let frontAfter = NSWorkspace.shared.frontmostApplication?.processIdentifier
            print(String(
                format: "MW03 adopted in %.0f ms onto %@; front %@ -> %@",
                cost, String(describing: WindowServerProbe.geometry(of: adopted.id)?.frame ?? .null),
                String(describing: frontBefore), String(describing: frontAfter)
            ))
            #expect(frontAfter == frontBefore,
                    "taking the window out of fullscreen changed the frontmost application")

            // The three facts the return leg needs, on the handle the seat gave back.
            print("MW03 the handle carries: wasFullScreen \(adopted.wasFullScreen), "
                + "normal frame \(adopted.originalFrame), "
                + "original display \(String(describing: adopted.originalDisplayID))")
            #expect(adopted.wasFullScreen, "the handle forgot the window was in fullscreen")
            #expect(adopted.originalFrame.size != (fullScreenFrame?.size ?? .zero),
                    "the normal frame is the fullscreen rectangle, so it was not read after the exit")
            #expect(adopted.originalDisplayID != nil)

            let placed = try #require(WindowServerProbe.geometry(of: adopted.id)?.frame)
            #expect(stage.virtualBounds.contains(CGPoint(x: placed.midX, y: placed.midY)),
                    "the window that came out of fullscreen is not on the virtual display")

            // MARK: it is usable where it was put, and opens a second window there

            fixture.refresh()
            let openPoint = try #require(
                fixture.latest.openWindowQuartzX.map {
                    CGPoint(x: $0, y: fixture.latest.openWindowQuartzY ?? 0)
                },
                "the fixture binary does not publish openWindowQuartzX/Y"
            )
            let turn    = try await seat.acquire()
            let receipt = try await seat.send(
                .click(try fixture.location(of: openPoint)),
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
            #expect(opened, "the window that came out of fullscreen did not react on the virtual display")

            let transferred = await LivePump.settle(
                until  : { seat.adoptedWindows.count == 2 },
                timeout: 10
            )
            print("MW03 second window: opened \(opened), transferred \(transferred), "
                + "adopted \(seat.adoptedWindows.map(\.id))")
            #expect(transferred, "the second window opened after the transfer was never brought in")
            if let follower = seat.adoptedWindows.first(where: { $0.id != adopted.id }),
               let frame = WindowServerProbe.geometry(of: follower.id)?.frame {
                print("MW03 second window at \(frame)")
                #expect(stage.virtualBounds.contains(CGPoint(x: frame.midX, y: frame.midY)),
                        "the second window was adopted without landing on the virtual display")
                #expect(follower.wasFullScreen == false,
                        "a window that was never in fullscreen was recorded as having been")
            }

            // MARK: the return leg, with the second switch off, which is the default

            for follower in seat.adoptedWindows where follower.id != adopted.id {
                _ = await seat.release(follower)
            }
            let frontBeforeRelease = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let outcome = await seat.release(adopted)
            let frontAfterRelease = NSWorkspace.shared.frontmostApplication?.processIdentifier

            fixture.refresh()
            let returned  = WindowServerProbe.geometry(of: fixture.window.windowNumber)?.frame
            let stillFull = (try? WindowRelocator.fullScreen(of: fixture.window))?.value
            let onARealDisplay = returned.map { frame in
                NSScreen.screens.contains { screen in
                    let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                        as? NSNumber)?.uint32Value ?? 0
                    return CGDisplayBounds(CGDirectDisplayID(number))
                        .contains(CGPoint(x: frame.midX, y: frame.midY))
                }
            } ?? false

            print("MW03 release: \(outcome), at \(String(describing: returned ?? .null)), "
                + "on a real display \(onARealDisplay), AXFullScreen \(String(describing: stillFull)), "
                + "front \(String(describing: frontBeforeRelease)) -> "
                + "\(String(describing: frontAfterRelease))")

            #expect(outcome == .returned)
            #expect(onARealDisplay, "the window was not given back to a real display")
            #expect(stillFull == false,
                    "the default release put the window back into fullscreen, which takes the focus")
            #expect(frontAfterRelease == frontBeforeRelease,
                    "the default release changed the frontmost application")

            // MARK: leave the person's machine as it was found

            let after    = UserSeatState.capture()
            let physical = stage.fence.snapshot().observedEventCount &- hand
            print("MW03 person after: \(after.frontmostName) (\(after.frontmostProcessID)), "
                + "\(physical) physical events during the run")
            #expect(after.frontmostProcessID == person.frontmostProcessID,
                    "the person's frontmost application changed to \(after.frontmostName)")
        }
    }

    // MARK: The second switch, on its own

    @Test("MW03: the separate switch puts the window back into fullscreen, and takes the focus doing it",
          .enabled(if: liveSkipReason(optIn: "AGENTSEAT_FULLSCREEN_PROBE", needsFixture: true) == nil,
                   Comment(rawValue: liveSkipReason(optIn: "AGENTSEAT_FULLSCREEN_PROBE",
                                                    needsFixture: true) ?? "")))
    func restoringFullScreenTakesTheSeat() async throws {

        try await LiveStage.run(
            needsFixture : true,
            needsChrome  : false,
            configuration: SeatHostConfiguration(
                transfersFullScreenWindows : true,
                restoresFullScreenOnRelease: true
            )
        ) { stage in

            let fixture = try #require(stage.fixture)
            let seat    = stage.seat
            let person  = stage.personBefore

            #expect(Self.enterFullScreen(fixture.window))
            try #require(Self.awaitFullScreen(true, of: fixture.window))

            if let previous = NSRunningApplication(processIdentifier: person.frontmostProcessID) {
                previous.activate()
                _ = LivePump.run(
                    until  : { NSWorkspace.shared.frontmostApplication?.processIdentifier
                                == person.frontmostProcessID },
                    timeout: 3
                )
            }
            try #require(LivePump.run(
                until  : { !WindowRelocator.spaceIsOnScreen(for: fixture.window) },
                timeout: 8
            ))

            let adopted = try await adopt(fixture, onto: seat, bounds: stage.virtualBounds)
            try #require(adopted.wasFullScreen)

            let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let outcome     = await seat.release(adopted)
            LivePump.run(for: 1.0)
            let frontAfter  = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let restored    = (try? WindowRelocator.fullScreen(of: fixture.window))?.value

            print("MW03 restore switch: outcome \(outcome), AXFullScreen \(String(describing: restored)), "
                + "front \(String(describing: frontBefore)) -> \(String(describing: frontAfter))")

            #expect(outcome == .returned)
            #expect(restored == true, "the window did not go back into the state it was found in")

            // The measured price of this switch, asserted so that it cannot
            // quietly stop being true: the restore takes the seat every time,
            // which is exactly why it is not the default.
            #expect(frontAfter != frontBefore,
                    Comment(rawValue: "re-entering fullscreen left the frontmost application "
                        + "alone, which every measurement so far says it does not: recheck "
                        + "the report before relaxing this"))

            // Put the person's machine back: this row is the one that takes the
            // seat, so this row is the one that gives it back.
            if let element = Self.windowElement(of: fixture.window) {
                AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString, false as CFBoolean)
                _ = Self.awaitFullScreen(false, of: fixture.window)
            }
            if let previous = NSRunningApplication(processIdentifier: person.frontmostProcessID) {
                previous.activate()
                _ = LivePump.run(
                    until  : { NSWorkspace.shared.frontmostApplication?.processIdentifier
                                == person.frontmostProcessID },
                    timeout: 3
                )
            }
        }
    }
}
