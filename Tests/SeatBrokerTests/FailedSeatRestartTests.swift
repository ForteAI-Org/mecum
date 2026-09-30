//
//  FailedSeatRestartTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/09/2026.
//

import AppKit
import Foundation
import SeatCore
import SeatDriving
import SeatSession
import Testing
@testable import SeatBroker

/// A seat that failed is not handed to the next session: the driver tears the host down and makes
/// a new seat on the next adoption, so the queue's warm session opens an application again.
///
/// Before this, every `open` in the process after a failure answered that the seat was failed, until
/// the app was restarted. There is no unit seam for it, since the driver builds its own host and
/// starting that host creates a real virtual display, so this is Live.
///
/// Gated by `AGENTSEAT_LIVE_TESTS=1` like the Driver's Live tier, and named apart from it so that
/// `make live-tests`, which filters on `LiveTests` and asserts a count, does not pick it up. It
/// needs Screen Recording, Accessibility and Post Event for the process running the tests, an awake
/// display and nobody driving the machine. It opens `MECUM_RESTART_APP`, TextEdit unless set, which
/// must not be running already: the broker quits only what it opened, and acts on nothing else.
@MainActor
@Suite(
    "Failed seat restart",
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["AGENTSEAT_LIVE_TESTS"] == "1",
        "AGENTSEAT_LIVE_TESTS=1 is required: this opens an application and drives it on a seat."
    )
)
struct FailedSeatRestartTests {

    @Test("a failed seat is replaced by a ready one on the next open of a warm session")
    func aFailedSeatIsReplacedOnTheNextOpen() async throws {

        let appName = ProcessInfo.processInfo.environment["MECUM_RESTART_APP"] ?? "TextEdit"
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mecum-restart-\(UUID().uuidString)", isDirectory: true)
        // A test process has no event loop of its own, and a virtual display appears only while one turns.
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()

        let broker = SeatBroker(configuration: SeatBrokerConfiguration(
            allowUnvalidatedBuild: true,
            recordingDirectory   : scratch.appendingPathComponent("Runs", isDirectory: true)
        ))
        let isRunning = broker.runningTargets().contains {
            $0.pid != nil && $0.name.caseInsensitiveCompare(appName) == .orderedSame
        }
        try #require(!isRunning, "\(appName) is already running: quit it, so the test acts only on what it opened")

        let first = try await broker.queue.acquire("failed seat restart, first")
        let firstSession = first.session
        var failure: (any Error)?
        var firstPID: pid_t?
        do {
            firstPID = try await firstSession.open(applicationNamed: appName).pid
            let failing = try firstSession.borrowedSeatTarget().agentSeat()
            // A seat-level critical Issue, which `SeatStateMachine` maps to `failed`.
            failing.report([.ambiguousEffect])
            #expect(failing.state == .failed, "the reported Issue did not fail the seat")
        } catch {
            failure = error
        }
        // The queue path of a worker closing: finish with the application, park the session warm.
        let firstFinish = await firstSession.finishUsingApp()
        print("RESTART first finish: \(firstFinish ?? "nil, everything went back")")
        first.giveBack()
        // The quit is asked for, not awaited: opening again before the process is gone would adopt
        // the dying instance's window instead of a new one.
        if let firstPID { await Self.waitForExit(of: firstPID, within: .seconds(5)) }

        var closing: String?
        if failure == nil {
            let second = try await broker.queue.acquire("failed seat restart, second")
            #expect(second.session === firstSession, "the queue did not hand the warm session back")
            do {
                try await second.session.open(applicationNamed: appName)
                let restarted = try second.session.borrowedSeatTarget().agentSeat()
                #expect(restarted.state == .ready, "the seat after the restart is \(restarted.state)")
            } catch {
                failure = error
            }
            closing = await second.session.close()
            print("RESTART close: \(closing ?? "nil, everything went back")")
            second.giveBack()
        }
        // Closes the warm session a failure above left parked, and nothing when it was closed already.
        await broker.queue.shutdown()

        let cleanup = Result { try Self.remove(scratch) }
        if let failure { throw failure }
        try cleanup.get()
        #expect(closing == nil, "the session closed with something left behind")
    }

    private static func waitForExit(of pid: pid_t, within limit: Duration) async {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while kill(pid, 0) == 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func remove(_ directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}
