//
//  BorrowedSeatSpikeTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import AutomationRuntime
import Engine
import EngineCore
import Foundation
import Memory
import PerceptionCore
import SeatBroker
import SeatDriving
import Testing

/// The live half of spike T5.0: Ron's engine perceives and acts through a `SeatTarget` borrowed
/// from a session the broker's queue handed out, and the broker observes and closes normally after.
///
/// Gated by `AGENTSEAT_LIVE_TESTS=1` like the Driver's Live tier, and named apart from it so that
/// `make live-tests`, which filters on `LiveTests` and asserts a count, does not pick it up. It
/// needs Screen Recording, Accessibility and Post Event for the process running the tests, an awake
/// display and nobody driving the machine. It opens `MECUM_BORROW_APP`, TextEdit unless set, which
/// must not be running already: the broker quits only what it opened, and acts on nothing else.
///
/// Its lines are tagged so two failures stay apart. `BORROW` is the seat refusing what the borrow
/// asked of it; `BROKER` is the broker's own session failing after the borrow ended; `PERCEPTION` is
/// a scene with no control labelled by accessibility, which says nothing about the borrow on a Mac
/// whose Vision text models do not load.
@MainActor
@Suite(
    "Borrowed seat spike",
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["AGENTSEAT_LIVE_TESTS"] == "1",
        "AGENTSEAT_LIVE_TESTS=1 is required: this opens an application and drives it on a seat."
    )
)
struct BorrowedSeatSpikeTests {

    /// Roles whose label the augmenter takes from accessibility and whose click reaches the seat:
    /// `SeatControls` presses pop-up buttons and combo boxes itself, so those never do.
    private static let clickableRoles: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton"]

    /// Labels that close or replace the adopted window, which would fail the broker's observation
    /// afterwards for a reason that is not the borrow. `MECUM_BORROW_CONTROL` overrides the pick.
    private static let dismissing: Set<String> = ["cancel", "close", "done", "ok", "open", "new document", "save"]

    @Test("the engine sees and acts through the broker's seat, and the broker observes afterwards")
    func theEngineDrivesTheBrokersSeat() async throws {

        let environment = ProcessInfo.processInfo.environment
        let appName = environment["MECUM_BORROW_APP"] ?? "TextEdit"
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mecum-borrow-\(UUID().uuidString)", isDirectory: true)
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
        try #require(!isRunning, "\(appName) is already running: quit it, so the spike acts only on what it opened")

        let lease = try await broker.queue.acquire("borrowed seat spike")
        var failure: (any Error)?
        do {
            try await Self.drive(
                lease.session,
                appName  : appName,
                knowledge: scratch.appendingPathComponent("Knowledge", isDirectory: true)
            )
        } catch {
            failure = error
        }
        let closing = await lease.session.close()
        print("SPIKE close: \(closing ?? "nil, everything went back")")
        lease.giveBack()
        let cleanup = Result { try Self.remove(scratch) }
        if let failure { throw failure }
        try cleanup.get()
        #expect(closing == nil, "BROKER: the session closed with something left behind")
    }

    /// Steps 2 to 6 of the spike, on a lease the caller gives back whatever happens here.
    private static func drive(_ session: AgentSession, appName: String, knowledge: URL) async throws {

        let opened = try await session.open(applicationNamed: appName)
        let pid = try #require(opened.pid)
        print("SPIKE opened \(opened.name) pid \(pid), window '\(session.target?.title ?? "")'")

        let borrowed = try session.borrowedSeatTarget()
        let runtime  = EngineRuntime(knowledgeDirectory: knowledge, seat: borrowed)

        let perceived: PerceivedWindow
        do { perceived = try await runtime.scenes.currentScene(of: pid) }
        catch { throw SpikeFailure("BORROW: the scene provider could not see the broker's window: \(error)") }
        #expect(!perceived.scene.elements.isEmpty, "BORROW: the scene read through the borrow is empty")
        let controls = perceived.scene.elements.filter { clickableRoles.contains($0.role ?? "") }
        print("SPIKE scene: \(perceived.scene.elements.count) elements in \(perceived.frame)")
        print("SPIKE labelled by accessibility: "
            + controls.map { "\($0.role ?? "") '\($0.label)' #\($0.id)" }.joined(separator: ", "))

        let requested = ProcessInfo.processInfo.environment["MECUM_BORROW_CONTROL"]
        let control = controls.first { element in
            if let requested { return element.label == requested || element.id == requested }
            return element.isEnabled != false
                && !ActionPolicy.isDestructive(label: element.label)
                && !dismissing.contains(element.label.lowercased())
        }
        if let control {
            print("SPIKE act: click \(control.role ?? "") '\(control.label)' #\(control.id)")
            let recorder = runtime.recorder(ActionContext(source: .system, streamID: "borrowed-seat-spike"))
            let outcome = await runtime.engine(recorder: recorder, allowsDestructive: false).act(ActionRequest(
                processID: pid,
                bundleID : opened.bundleID,
                appName  : opened.name,
                target   : control.id,
                verb     : .click
            ))
            print("SPIKE ActOutcome kind: \(outcome.kind)")
            print("SPIKE ActOutcome message: \(outcome.message)")
            // `delivery failed` is the seat refusing the gesture, which is the borrow's question;
            // every other outcome is perception's verdict on what the click did.
            #expect(!outcome.message.contains("delivery failed"), "BORROW: the seat refused the gesture")
        } else {
            Issue.record("PERCEPTION: no control labelled by accessibility to click, so no act was tried")
        }

        await runtime.finish()
        await borrowed.stop()
        do {
            let observation = try await session.observe()
            print("SPIKE broker observed \(observation.elements.count) elements, seat \(session.seatActivity)")
        } catch {
            throw SpikeFailure("BROKER: the broker's own observation failed after the borrow ended: \(error)")
        }
        #expect(session.isUsingApp, "BROKER: the session no longer holds the application")
    }

    private static func remove(_ directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}

/// SpikeFailure carries a tagged sentence out of the spike, so the report says which side failed.
private struct SpikeFailure: Error, CustomStringConvertible {

    let description: String

    init(_ description: String) { self.description = description }
}
