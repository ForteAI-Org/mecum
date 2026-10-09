//
//  WindowOnAnotherDesktopTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/10/2026.
//

import AppKit
import AutomationRuntime
import CoreGraphics
import Foundation
import SeatCore
import SeatSession
import Testing
@testable import SeatBroker

/// A window on a desktop no display shows is a window the application has, and
/// the open says so at once instead of waiting for it (ADR 0037). The window
/// list, the layout and the desktop reading are supplied: nothing here reads a
/// real desktop or switches one.
@MainActor
@Suite("A window on another desktop")
struct WindowOnAnotherDesktopTests {

    static let pid: pid_t = 4_321

    /// Built-in display with Desktop 1 (2419) hidden and Desktop 2 (1) shown.
    static let layout = DesktopLayout(displays: [
        .init(displayID: 1, spaces: [2419, 1], current: 1),
    ])

    static func row(
        _ number: Int,
        pid     : pid_t = pid,
        layer   : Int = 0,
        size    : CGSize = CGSize(width: 230, height: 408)
    ) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: pid,
            kCGWindowNumber as String  : number,
            kCGWindowLayer as String   : layer,
            kCGWindowBounds as String  : CGRect(origin: CGPoint(x: 701, y: 314), size: size)
                .dictionaryRepresentation,
        ]
    }

    static func found(
        _ list : [[String: Any]],
        layout : DesktopLayout? = layout,
        spaces : [Int: [Int]]
    ) -> Bool {
        TargetEnumerator.hasWindowOnAnotherDesktop(
            in         : list,
            of         : pid,
            minimumSize: 120,
            layout     : layout,
            spaces     : { spaces[$0] }
        )
    }

    // MARK: The decision

    @Test("a window of the application on a hidden desktop is found")
    func hiddenDesktopIsFound() {
        #expect(Self.found([Self.row(88_298)], spaces: [88_298: [2419]]))
    }

    @Test("a window on the desktop that is shown is not")
    func shownDesktopIsNot() {
        #expect(!Self.found([Self.row(88_298)], spaces: [88_298: [1]]))
    }

    @Test("a window another process owns, a helper layer or a sliver is not the application's window")
    func onlyTheApplicationsOwnWindowsCount() {
        let spaces = [88_298: [2419]]
        #expect(!Self.found([Self.row(88_298, pid: 999)], spaces: spaces))
        #expect(!Self.found([Self.row(88_298, layer: 25)], spaces: spaces))
        #expect(!Self.found([Self.row(88_298, size: CGSize(width: 40, height: 20))], spaces: spaces))
    }

    @Test("no claim is made when the desktops cannot be read")
    func unreadableDesktopsClaimNothing() {
        #expect(!Self.found([Self.row(88_298)], layout: nil, spaces: [88_298: [2419]]))
        #expect(!Self.found([Self.row(88_298)], spaces: [:]))
        #expect(!Self.found([], spaces: [:]))
    }

    // MARK: The answer

    @Test("the sentence names the application and what to do")
    func sentence() {
        #expect(
            SeatBrokerError.windowOnAnotherDesktop(application: "Calculator").localizedDescription
                == "Calculator's window is on another desktop: bring it to the current desktop and ask again."
        )
    }

    @Test("the worker reads that sentence and not the case")
    func workerSentence() {
        let error = BrokeredAutomationSession.refusal(
            for: SeatBrokerError.windowOnAnotherDesktop(application: "Calculator")
        )
        #expect(error is AutomationFailure)
        #expect(String(describing: error).hasPrefix("Calculator's window is on another desktop"))
    }

    @Test("an open that finds it refuses at once and gives the seat back")
    func openRefusesAtOnce() async throws {
        let broker  = SeatBroker()
        let desktop = BrokeredAutomationSession(
            broker            : broker,
            workerID          : UUID(),
            knowledgeDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("mecum-desktop-\(UUID().uuidString)", isDirectory: true),
            allowsDestructive : false,
            missingGrant      : { nil },
            requestGrants     : {},
            seating           : { _, _, _ in
                throw SeatBrokerError.windowOnAnotherDesktop(application: "Calculator")
            },
            perceiving        : BrokeredAutomationSession.perceivedThroughTheEngine,
            idleWindow        : BrokeredAutomationSession.idleWindow,
            waitIdle          : { try await Task.sleep(for: $0) }
        )
        let started = ContinuousClock.now
        let refusal = await #expect(throws: AutomationFailure.self) {
            try await desktop.open(application: "Calculator", window: nil)
        }
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(refusal?.description.contains("another desktop") == true)
        #expect(!refusal!.description.contains("showed no window"))
        #expect(broker.queue.entries.isEmpty)
    }

    // MARK: What the person is told after a release

    @Test("a window back on another desktop is home for the seat and named for the person")
    func returnedToOtherSpace() {
        #expect(SeatDriver.isHome(.returnedToOtherSpace))
        #expect(!SeatDriver.leavesWindowUnrestored([.returned, .returnedToOtherSpace]))
        #expect(SeatErrorMapper.otherDesktop([]) == nil)
        let one = SeatErrorMapper.otherDesktop([83_151]) ?? ""
        #expect(one.hasPrefix("Window 83151 is back on your display but on another desktop"))
        #expect(one.contains("does not move windows between desktops"))
        let several = SeatErrorMapper.otherDesktop([1, 2]) ?? ""
        #expect(several.hasPrefix("Windows 1, 2 are back"))
    }

    @Test("the teardown report names a window left on another desktop and no other")
    func teardownNamesIt() {
        func report(_ windows: [Int: WindowReleaseOutcome]) -> TeardownReport {
            TeardownReport(
                displayRemoved     : true,
                fenceReleased      : true,
                mainDisplayRestored: true,
                topologyRestoration: nil,
                windows            : windows,
                removalNanoseconds : 0
            )
        }
        #expect(SeatErrorMapper.teardown(report([5: .returned])) == nil)
        #expect(SeatErrorMapper.teardown(report([5: .returnedToOtherSpace]))?.contains("Window 5 is back") == true)
        let both = SeatErrorMapper.teardown(report([5: .returnedToOtherSpace, 6: .refused])) ?? ""
        #expect(both.contains("window 6 did not go back to your display"))
        #expect(both.contains("Window 5 is back"))
        #expect(
            SeatErrorMapper.line(for: .windowReleased(windowNumber: 5, outcome: .returnedToOtherSpace))
                == "window 5 was put back where it was, but on another desktop than its own"
        )
    }
}
