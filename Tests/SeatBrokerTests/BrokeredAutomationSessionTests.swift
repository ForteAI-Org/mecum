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

    /// Stands in for the idle window's clock: each wait is recorded and returns only when the test
    /// lets the oldest one elapse, so no test sleeps for the window. A cancelled wait is not woken,
    /// so the session's own check after the wait is what a late elapse exercises.
    @MainActor
    private final class IdleClock {
        private(set) var waits: [Duration] = []
        private var pending: [CheckedContinuation<Void, Never>] = []

        var pendingCount: Int { pending.count }

        func wait(_ window: Duration) async {
            waits.append(window)
            await withCheckedContinuation { pending.append($0) }
        }

        /// Wakes the oldest wait, once the session's release task has begun it.
        func elapseOldest() async {
            await BrokeredAutomationSessionTests.until { !self.pending.isEmpty }
            guard !pending.isEmpty else {
                Issue.record("no idle wait began")
                return
            }
            pending.removeFirst().resume()
        }
    }

    private static func session(
        _ broker  : SeatBroker,
        workerID  : UUID = workerID,
        missing   : PermissionKind? = nil,
        requests  : @escaping @MainActor () -> Void = {},
        perceiving: @escaping BrokeredAutomationSession.Perceiving = BrokeredAutomationSession
            .perceivedThroughTheEngine,
        idleWindow: Duration = BrokeredAutomationSession.idleWindow,
        waitIdle  : @escaping BrokeredAutomationSession.IdleWaiting = { try await Task.sleep(for: $0) },
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
            perceiving        : perceiving,
            idleWindow        : idleWindow,
            waitIdle          : waitIdle
        )
    }

    /// A session whose open succeeds without a display. The seating names the Dock as the running
    /// application, which nothing adopts or quits, and the scene is supplied in place of perception.
    /// `idle` supplies the idle window's clock, and `holding` a pid the granted session holds as if
    /// adopted, so closing finishes with it as the broker's ledger says.
    private static func seated(
        _ broker  : SeatBroker,
        idleWindow: Duration = BrokeredAutomationSession.idleWindow,
        idle      : IdleClock? = nil,
        holding   : pid_t? = nil,
        opens     : @escaping @MainActor () -> Void = {}
    ) throws -> BrokeredAutomationSession {
        let dock = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier)
        let scene = SceneSnapshot(bundleID: "test.process", appName: "Test", windowTitle: "Test",
                                  viewportPixelSize: ViewportPixelSize(width: 10, height: 10), elements: [])
        let waitIdle: BrokeredAutomationSession.IdleWaiting = if let idle {
            { await idle.wait($0) }
        } else {
            { try await Task.sleep(for: $0) }
        }
        return session(broker, perceiving: { _, _ in scene }, idleWindow: idleWindow, waitIdle: waitIdle) {
            session, _, _ in
            opens()
            if let holding { session.holdWithoutAdopting(holding, name: "Test") }
            return (TargetApp(pid: dock, bundleID: "test.process", name: "Test", bundleURL: nil, windows: []),
                    SeatTarget())
        }
    }

    /// Waits, a few milliseconds at a time and for at most two seconds, until `condition` holds.
    private static func until(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
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

    @Test("a seat that cannot observe is worded for the agent, not printed as its case")
    func aSeatThatCannotObserveIsWorded() {
        let refusal = BrokeredAutomationSession.refusal(for: ObservationUnavailable.suspended([.noEligibleTarget]))
        #expect(refusal is AutomationFailure)
        #expect(String(describing: refusal) == "The seat cannot observe while suspended: "
            + "no window of the assigned application is eligible to act in.")
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

    @Test("the computer can be released only while the session holds it, not while it waits",
          .timeLimit(.minutes(1)))
    func releasingIsOfferedOnlyWhileTheSeatIsHeld() async throws {
        let broker  = SeatBroker()
        let desktop = try Self.seated(broker)
        #expect(!desktop.holdsComputer)

        let holder = try await broker.queue.acquire("holder")
        let open   = Task { try await desktop.open(application: "Test", window: nil) }
        await Self.letTheWaitBegin()
        #expect(desktop.activity == "Waiting for the computer (1 ahead)")
        #expect(!desktop.holdsComputer)

        holder.giveBack()
        _ = try await open.value
        #expect(desktop.holdsComputer)

        // What the toolbar's Release the computer calls: the lease goes back, the session stays usable.
        await desktop.close()
        #expect(!desktop.holdsComputer)
        #expect(desktop.activity == nil)
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("the screen can be watched only while an application is open on the held seat",
          .timeLimit(.minutes(1)))
    func theScreenIsThereOnlyWhileTheSeatIsHeld() async throws {
        let broker  = SeatBroker()
        let desktop = try Self.seated(broker)
        #expect(!desktop.hasScreen && desktop.makeScreenView(contentsScale: 2) == nil)

        let holder = try await broker.queue.acquire("holder")
        let open   = Task { try await desktop.open(application: "Test", window: nil) }
        await Self.letTheWaitBegin()
        #expect(!desktop.hasScreen && desktop.makeScreenView(contentsScale: 2) == nil, "waiting is not watching")

        holder.giveBack()
        _ = try await open.value
        #expect(desktop.hasScreen && desktop.makeScreenView(contentsScale: 2) != nil)

        // Given back, the seat goes warm to the next entry, so no new view may reach it.
        await desktop.close()
        #expect(!desktop.hasScreen && desktop.makeScreenView(contentsScale: 2) == nil)
        #expect(desktop.screenFrame == .zero)
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

    @Test("a holder idle after its turn gives the computer back once the idle window elapses",
          .timeLimit(.minutes(1)))
    func anIdleHolderReleasesWhenTheIdleWindowElapses() async throws {
        let broker  = SeatBroker()
        let desktop = try Self.seated(broker, idleWindow: .milliseconds(50))
        try await desktop.turn { _ = try await desktop.open(application: "Test", window: nil) }
        #expect(desktop.activity == "Using Test")

        await Self.until { !desktop.holdsComputer }

        #expect(!desktop.holdsComputer)
        #expect(desktop.activity == nil)
        #expect(desktop.id == nil)
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("a follow-up inside the idle window cancels the release and reuses the open session",
          .timeLimit(.minutes(1)))
    func aFollowUpInsideTheIdleWindowReusesTheSession() async throws {
        let broker  = SeatBroker()
        let idle    = IdleClock()
        var opens   = 0
        let desktop = try Self.seated(broker, idleWindow: .milliseconds(50), idle: idle, opens: { opens += 1 })
        try await desktop.turn { _ = try await desktop.open(application: "Test", window: nil) }
        let session = desktop.id
        await Self.until { idle.pendingCount == 1 }
        #expect(idle.waits == [.milliseconds(50)])

        try await desktop.turn {
            // The first window elapses inside the follow-up, which cancelled it: nothing is released.
            await idle.elapseOldest()
            await Self.letTheWaitBegin()
            #expect(desktop.holdsComputer)
            let scene = try await desktop.observe()
            #expect(scene.appName == "Test")
        }
        #expect(opens == 1)
        #expect(desktop.id == session)
        #expect(desktop.activity == "Using Test")
        await Self.until { idle.waits.count == 2 }
        #expect(idle.pendingCount == 1)

        await idle.elapseOldest()
        await Self.until { !desktop.holdsComputer }
        #expect(desktop.activity == nil)
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("an entry that starts waiting during the idle window is given the computer at once",
          .timeLimit(.minutes(1)))
    func aWaiterDuringTheIdleWindowReleasesAtOnce() async throws {
        let broker  = SeatBroker()
        let idle    = IdleClock()
        let desktop = try Self.seated(broker, idle: idle)
        try await desktop.turn { _ = try await desktop.open(application: "Test", window: nil) }

        let lease = try await Task { try await broker.queue.acquire("Mecum") }.value

        #expect(!desktop.holdsComputer)
        await Self.until { idle.pendingCount == 1 }
        #expect(idle.pendingCount == 1)
        #expect(broker.queue.entries.map(\.label) == ["Mecum"])

        // The window elapsing after the queue's release closes nothing: the other entry keeps the seat.
        await idle.elapseOldest()
        await Self.letTheWaitBegin()
        #expect(broker.queue.entries.map(\.label) == ["Mecum"])
        #expect(broker.queue.entries.map(\.state) == [.acting])
        #expect(lease.session.isOpen)
        lease.giveBack()
    }

    @Test("a turn that runs longer than the idle window keeps the computer until it ends",
          .timeLimit(.minutes(1)))
    func aTurnLongerThanTheIdleWindowIsNeverReleasedInside() async throws {
        let broker  = SeatBroker()
        let desktop = try Self.seated(broker, idleWindow: .milliseconds(30))
        try await desktop.turn { _ = try await desktop.open(application: "Test", window: nil) }
        let session = desktop.id

        try await desktop.turn {
            try await Task.sleep(for: .milliseconds(200))
            #expect(desktop.holdsComputer)
            #expect(desktop.id == session)
            #expect(try await desktop.observe().appName == "Test")
        }
        #expect(desktop.id == session)

        await Self.until { !desktop.holdsComputer }
        #expect(desktop.activity == nil)
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("after Release the computer, the pending idle release does nothing, even under a later lease",
          .timeLimit(.minutes(1)))
    func aStaleIdleReleaseAfterAManualReleaseDoesNothing() async throws {
        let broker  = SeatBroker()
        let idle    = IdleClock()
        var opens   = 0
        let desktop = try Self.seated(broker, idle: idle, opens: { opens += 1 })
        try await desktop.turn { _ = try await desktop.open(application: "Test", window: nil) }

        await desktop.close()
        #expect(!desktop.holdsComputer)
        try await desktop.turn { _ = try await desktop.open(application: "Test", window: nil) }
        #expect(opens == 2)
        await Self.until { idle.pendingCount == 2 }
        #expect(idle.pendingCount == 2)

        // The first wait belonged to the lease given back by hand.
        await idle.elapseOldest()
        await Self.letTheWaitBegin()
        #expect(desktop.holdsComputer)
        #expect(broker.queue.entries.map(\.label) == [Self.label])

        await idle.elapseOldest()
        await Self.until { !desktop.holdsComputer }
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("the idle release quits an application the agent launched and leaves one already running",
          .timeLimit(.minutes(1)))
    func theIdleReleaseFinishesWithTheApplicationAsItsProvenanceSays() async throws {
        let launched: pid_t = 900_001
        let found   : pid_t = 900_002
        var asked: [pid_t] = []
        let ledger = LaunchLedger { asked.append($0) }
        ledger.record(.openedByAgent, for: launched)
        let broker = SeatBroker(configuration: .init(), ledger: ledger)

        for pid in [launched, found] {
            let idle    = IdleClock()
            let desktop = try Self.seated(broker, idle: idle, holding: pid)
            try await desktop.turn { _ = try await desktop.open(application: "Test", window: nil) }
            // Nothing is finished with while the window has not elapsed.
            #expect(asked == (pid == launched ? [] : [launched]))
            await idle.elapseOldest()
            await Self.until { !desktop.holdsComputer }
            #expect(!desktop.holdsComputer)
        }

        #expect(asked == [launched])
        #expect(ledger.provenance(of: launched) == .alreadyRunning)
        #expect(broker.queue.entries.isEmpty)
    }
}
