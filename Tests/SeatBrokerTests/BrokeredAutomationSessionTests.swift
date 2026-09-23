//
//  BrokeredAutomationSessionTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import AutomationMCP
import AutomationRuntime
import Foundation
import LocalMCP
import PerceptionCore
import SeatCore
import SeatDriving
import Testing
@testable import SeatBroker

/// A worker's desktop session over the broker's queue, driven with the queue's own seats: a
/// session costs one allocation and raises no display until something is adopted, so the lease
/// is real and nothing here reaches the desktop. The grants and the opening are supplied in
/// place of macOS, keeping their order: the grants before the queue, the opening on the seat
/// the queue granted. What the real opening and the borrowed engine do on a display is the live
/// row in `WorkerAgentsTests`.
@MainActor
@Suite("A worker's desktop session through the broker")
struct BrokeredAutomationSessionTests {

    private static let workerID = UUID()
    private static let label    = workerID.uuidString

    private struct Opened: Error {}

    private static func session(
        _ broker  : SeatBroker,
        workerID  : UUID = workerID,
        missing   : PermissionKind? = nil,
        requests  : @escaping @MainActor () -> Void = {},
        perceiving: @escaping BrokeredAutomationSession.Perceiving = BrokeredAutomationSession
            .perceivedThroughTheEngine,
        seating   : @escaping BrokeredAutomationSession.Seating
    ) -> BrokeredAutomationSession {
        BrokeredAutomationSession(
            broker            : broker,
            workerID          : workerID,
            knowledgeDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("mecum-brokered-\(UUID().uuidString)", isDirectory: true),
            allowsDestructive : false,
            missingGrant      : { missing },
            requestGrants     : requests,
            seating           : seating,
            perceiving        : perceiving
        )
    }

    /// A session whose open succeeds without a display. The seating names the Dock as the running
    /// application, which nothing adopts or quits, and the scene is supplied in place of perception.
    private static func seated(_ broker: SeatBroker) throws -> BrokeredAutomationSession {
        let dock = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier)
        let scene = SceneSnapshot(bundleID: "test.process", appName: "Test", windowTitle: "Test",
                                  viewportPixelSize: ViewportPixelSize(width: 10, height: 10), elements: [])
        return session(broker, perceiving: { _, _ in scene }) { _, _, _ in
            (TargetApp(pid: dock, bundleID: "test.process", name: "Test", bundleURL: nil, windows: []),
             SeatTarget())
        }
    }

    /// Long enough for a task about to suspend on the queue to get there.
    private static func letTheWaitBegin() async {
        try? await Task.sleep(for: .milliseconds(60))
    }

    @Test("the open holds the seat while it runs, a failed open gives it back, and a double close is nothing")
    func theSeatIsHeldForTheOpenAndGivenBackWhenItFails() async throws {
        let broker = SeatBroker()
        var during: [SeatQueue.Entry] = []
        var granted: AgentSession?
        let desktop = Self.session(broker) { session, _, _ in
            during  = broker.queue.entries
            granted = session
            throw Opened()
        }

        await #expect(throws: Opened.self) { try await desktop.open(application: "Calculator", window: nil) }

        #expect(during.map(\.label) == [Self.label])
        #expect(during.map(\.state) == [.acting])
        #expect(broker.queue.entries.isEmpty)
        #expect(desktop.id == nil)
        #expect(desktop.activity == nil)
        await desktop.close()
        await desktop.close()
        #expect(broker.queue.entries.isEmpty)

        // Given back open, so the queue parks it warm and hands the same seat to the next entry.
        let next = try await broker.queue.acquire("next")
        #expect(next.session === granted)
        #expect(next.session.isOpen)
        next.giveBack()
    }

    @Test("the broker's own opening refuses an unknown name, and the seat goes back")
    func theBrokersOpeningRefusesAnUnknownNameAndGivesTheSeatBack() async throws {
        let broker  = SeatBroker()
        let desktop = Self.session(broker, seating: BrokeredAutomationSession.seatedByTheBroker)

        let refusal = await #expect(throws: SeatBrokerError.self) {
            try await desktop.open(application: "No Such Application 5f0c", window: nil)
        }
        guard case .applicationNotResolved? = refusal else {
            Issue.record("expected applicationNotResolved, got \(String(describing: refusal))")
            return
        }
        #expect(broker.queue.entries.isEmpty)
        await desktop.close()
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("a first scene that fails after the borrow closes it, and the seat goes back")
    func aFirstSceneThatFailsClosesAndGivesTheSeatBack() async throws {
        let broker = SeatBroker()
        let target = SeatTarget()
        let desktop = Self.session(broker) { _, _, _ in
            (TargetApp(pid: getpid(), bundleID: "test.process", name: "Test", bundleURL: nil, windows: []), target)
        }

        // The target has no seat, so perception refuses; the Brain is flushed and the target stopped.
        await #expect(throws: (any Error).self) { try await desktop.open(application: "Test", window: nil) }

        #expect(broker.queue.entries.isEmpty)
        #expect(desktop.id == nil)
        #expect(throws: SeatDrivingFailure.notAdopted) { try target.agentSeat() }
        await desktop.close()
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("a turn stopped while its open waits for the computer leaves the queue")
    func aStoppedTurnWaitingForTheComputerLeavesTheQueue() async throws {
        let broker = SeatBroker()
        let holder = try await broker.queue.acquire("holder")
        var wasSeated = false
        let desktop = Self.session(broker) { _, _, _ in
            wasSeated = true
            throw Opened()
        }
        // The host's stop is `MCPRouter.pause`, which cancels the tool call in flight.
        let tools  = AutomationTools(session: desktop)
        let router = MCPRouter(tools: AutomationTools.definitions) { name, arguments in
            try await tools.call(name, arguments)
        }
        let call = Task {
            await router.handle(.object([
                "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
                "params" : .object(["name": .string("open_session"),
                                    "arguments": .object(["app": .string("Calculator")])])
            ]))
        }
        await Self.letTheWaitBegin()
        #expect(broker.queue.entries.map(\.label) == ["holder", Self.label])
        #expect(desktop.activity == "Waiting for the computer (1 ahead)")

        router.pause()
        let reply = await call.value
        await router.drain()

        #expect(reply?["result"]["isError"] == .bool(true))
        #expect(broker.queue.entries.map(\.label) == ["holder"])
        #expect(desktop.activity == nil)
        #expect(!wasSeated)
        await desktop.close()
        holder.giveBack()
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("a missing grant is asked for and refused by name, before the queue")
    func aMissingGrantRefusesByNameBeforeTheQueue() async throws {
        let names: [PermissionKind: String] = [
            .screenRecording: "Screen Recording", .accessibility: "Accessibility", .postEvent: "Post Event"
        ]
        for (kind, name) in names {
            let broker = SeatBroker()
            var requests = 0
            var wasSeated = false
            let desktop = Self.session(broker, missing: kind, requests: { requests += 1 }) { _, _, _ in
                wasSeated = true
                throw Opened()
            }
            let refusal = await #expect(throws: AutomationFailure.self) {
                try await desktop.open(application: "Calculator", window: nil)
            }
            #expect(refusal?.description.contains("macOS \(name) permission") == true)
            #expect(refusal?.description.contains("System Settings > Privacy & Security") == true)
            #expect(requests == 1)
            #expect(!wasSeated)
            #expect(broker.queue.entries.isEmpty)
        }
    }

    @Test("a launch that shows no window refuses with the reason, and the seat goes back")
    func aLaunchThatShowsNoWindowRefusesWithTheReason() async throws {
        let broker  = SeatBroker()
        let desktop = Self.session(broker) { _, _, _ in
            throw SeatBrokerError.noWindowShown(application: "TextEdit", seconds: 20, wasLaunched: true,
                                                wasQuit: true)
        }

        let refusal = await #expect(throws: AutomationFailure.self) {
            try await desktop.open(application: "TextEdit", window: nil)
        }

        let sentence = refusal?.description ?? ""
        #expect(sentence.hasPrefix("TextEdit was launched in the background and showed no window within 20 s."))
        #expect(sentence.contains("the seat never brings an application to the front"))
        #expect(sentence.contains("the computer was given back"))
        #expect(sentence.contains("TextEdit was closed again, since this open had launched it."))
        #expect(!sentence.contains("still running"))
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("an application that was never seated says whether it was closed again or left running")
    func anUnseatedApplicationSaysWhatBecameOfIt() {
        func sentence(_ wasLaunched: Bool, _ wasQuit: Bool) -> String {
            let error = SeatBrokerError.noWindowShown(application: "Notes", seconds: 20, wasLaunched: wasLaunched,
                                                      wasQuit: wasQuit)
            return String(describing: BrokeredAutomationSession.refusal(for: error))
        }
        #expect(sentence(false, false).hasPrefix("Notes is running and showed no window within 20 s."))
        #expect(sentence(false, false).contains("Notes was left running, since it was already open."))
        #expect(sentence(true, false).contains("Notes could not be closed again and is still running"))
        #expect(SeatBrokerError.noWindowShown(application: "Notes", seconds: 20, wasLaunched: true, wasQuit: true)
            .localizedDescription == "Notes launched but showed no window within 20 s. "
                + "Notes was closed again, since this open had launched it.")
    }

    @Test("a holder idle between turns gives the seat back as soon as another entry waits",
          .timeLimit(.minutes(1)))
    func anIdleHolderReleasesWhenAnEntryStartsWaiting() async throws {
        let broker  = SeatBroker()
        let desktop = try Self.seated(broker)
        try await desktop.turn { _ = try await desktop.open(application: "Test", window: nil) }
        #expect(desktop.activity == "Using Test")

        let waiter = Task { try await broker.queue.acquire("Mecum") }
        let lease  = try await waiter.value

        #expect(desktop.activity == nil)
        #expect(desktop.id == nil)
        #expect(broker.queue.entries.map(\.label) == ["Mecum"])
        // The next turn's tools find no session, and the sentence leads the agent to open_session again.
        let refusal = await #expect(throws: AutomationFailure.self) { try await desktop.observe() }
        #expect(refusal?.description == "No live application session. Use windows and open_session, then observe.")
        lease.giveBack()
    }

    @Test("a holder in a turn keeps the seat while the turn runs and gives it back as the turn ends",
          .timeLimit(.minutes(1)))
    func aHolderInATurnReleasesAtTheTurnsEndAndNotBefore() async throws {
        let broker  = SeatBroker()
        let desktop = try Self.seated(broker)
        var waiter: Task<SeatLease, any Error>?
        try await desktop.turn {
            _ = try await desktop.open(application: "Test", window: nil)
            waiter = Task { try await broker.queue.acquire("Mecum") }
            await Self.letTheWaitBegin()
            #expect(broker.queue.entries.map(\.state) == [.acting, .waiting])
            #expect(desktop.activity == "Using Test")
            #expect(try await desktop.observe().appName == "Test")
        }
        #expect(desktop.activity == nil)
        let lease = try #require(try await waiter?.value)
        #expect(broker.queue.entries.map(\.label) == ["Mecum"])
        lease.giveBack()
    }

    @Test("a worker alone keeps the seat across its turns")
    func aLoneHolderKeepsTheSeatAcrossTurns() async throws {
        let broker  = SeatBroker()
        let desktop = try Self.seated(broker)
        try await desktop.turn { _ = try await desktop.open(application: "Test", window: nil) }
        await Self.letTheWaitBegin()
        try await desktop.turn { _ = try await desktop.observe() }
        await Self.letTheWaitBegin()

        #expect(desktop.activity == "Using Test")
        #expect(desktop.id != nil)
        #expect(broker.queue.entries.map(\.label) == [Self.label])
        await desktop.close()
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("the queue entry carries the worker's id, so two workers with one name each read their own place")
    func theQueueLabelIsTheWorkersIDAndTheRowReadsItsOwnPosition() async throws {
        let broker = SeatBroker()
        let holder = try await broker.queue.acquire("Mecum")
        let first  = UUID()
        let second = UUID()
        let one = Self.session(broker, workerID: first) { _, _, _ in throw Opened() }
        let two = Self.session(broker, workerID: second) { _, _, _ in throw Opened() }
        let early = Task { try await one.open(application: "Calculator", window: nil) }
        await Self.letTheWaitBegin()
        let later = Task { try await two.open(application: "Calculator", window: nil) }
        await Self.letTheWaitBegin()

        #expect(broker.queue.entries.map(\.label) == ["Mecum", first.uuidString, second.uuidString])
        #expect(one.activity == "Waiting for the computer (1 ahead)")
        #expect(two.activity == "Waiting for the computer (2 ahead)")

        early.cancel()
        later.cancel()
        _ = await (early.result, later.result)
        holder.giveBack()
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("the waiting line's position is the entry's own index in the queue, and never a guess")
    func theWaitingLineIsReadFromTheQueueEntries() {
        func entry(_ label: String, _ state: SeatQueue.State) -> SeatQueue.Entry {
            SeatQueue.Entry(id: UUID(), label: label, state: state, since: Date())
        }
        let line = BrokeredAutomationSession.waiting

        #expect(line(Self.label, [entry("holder", .acting), entry("Rizzo", .waiting), entry(Self.label, .waiting)])
            == "Waiting for the computer (2 ahead)")
        #expect(line(Self.label, [entry("holder", .acting), entry(Self.label, .waiting)])
            == "Waiting for the computer (1 ahead)")
        // Two waiting entries under one label, or none, cannot say which is this worker's.
        #expect(line(Self.label, [entry("holder", .acting), entry(Self.label, .waiting), entry(Self.label, .waiting)])
            == "Waiting for the computer")
        #expect(line(Self.label, [entry("holder", .acting)]) == "Waiting for the computer")
        #expect(line(Self.label, [entry(Self.label, .acting)]) == "Waiting for the computer")
    }
}
