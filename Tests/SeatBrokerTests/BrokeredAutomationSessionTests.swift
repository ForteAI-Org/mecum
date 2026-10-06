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
import SeatSession
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

    @Test("a lost assignment closes the worker session and gives its lease back")
    func aLostAssignmentEndsTheWorkerSession() async throws {
        let broker = SeatBroker()
        let dock = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier)
        let target = SeatTarget()
        var observations = 0
        let scene = SceneSnapshot(bundleID: "test.process", appName: "Test", windowTitle: "Test",
                                  viewportPixelSize: ViewportPixelSize(width: 10, height: 10), elements: [])
        let desktop = Self.session(broker, perceiving: { _, _ in
            observations += 1
            guard observations == 1 else { throw ObservationUnavailable.notAssigned }
            return scene
        }) { _, _, _ in
            (TargetApp(pid: dock, bundleID: "test.process", name: "Test", bundleURL: nil, windows: []), target)
        }
        _ = try await desktop.open(application: "Test", window: nil)
        #expect(desktop.id != nil)

        do {
            _ = try await desktop.observe()
            Issue.record("An absent assignment cannot return a scene")
        } catch {
            #expect(error is AutomationFailure)
            let message = String(describing: error)
            #expect(message.contains("session ended"))
            #expect(message.contains("Use status"))
            #expect(message.contains("current windows"))
        }

        #expect(desktop.id == nil)
        #expect(desktop.activity == nil)
        #expect(!desktop.holdsComputer)
        #expect(!desktop.hasScreen)
        #expect(broker.queue.entries.isEmpty)
        #expect(throws: SeatDrivingFailure.notAdopted) { try target.agentSeat() }
        await desktop.close()
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("an open over a seat that stopped for good ends that session and opens the requested one")
    func anOpenReplacesAStoppedSeat() async throws {
        let broker = SeatBroker()
        let dock = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier)
        let scene = SceneSnapshot(bundleID: "test.process", appName: "Test", windowTitle: "Test",
                                  viewportPixelSize: ViewportPixelSize(width: 10, height: 10), elements: [])
        var seatings = 0
        var stopped  = false
        let desktop = BrokeredAutomationSession(
            broker            : broker,
            workerID          : UUID(),
            knowledgeDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("mecum-brokered-\(UUID().uuidString)", isDirectory: true),
            allowsDestructive : false,
            missingGrant      : { nil },
            requestGrants     : {},
            seating           : { _, _, _ in
                seatings += 1
                return (TargetApp(pid: dock, bundleID: "test.process", name: "Test", bundleURL: nil, windows: []),
                        SeatTarget())
            },
            perceiving        : { _, _ in scene },
            stoppedForGood    : { _ in stopped }
        )
        _ = try await desktop.open(application: "Test", window: nil)
        let first = try #require(desktop.id)

        // A live seat still refuses a second open.
        await #expect(throws: AutomationFailure.self) { try await desktop.open(application: "Test", window: nil) }
        #expect(desktop.id == first)

        stopped = true
        _ = try await desktop.open(application: "Test", window: nil)
        #expect(seatings == 2, "the dead session was closed and the requested one opened")
        #expect(desktop.id != nil && desktop.id != first)
        stopped = false
        await desktop.close()
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("a recoverable observation refusal preserves the current worker session", arguments: [
        ObservationUnavailable.noSelectedTarget,
        .suspended([.noEligibleTarget]),
        .captureDeadlineExpired(attemptsSpent: 1),
        .captureFailed(reason: "controlled transient capture failure")
    ])
    func anObservationRefusalKeepsTheWorkerSession(_ failure: ObservationUnavailable) async throws {
        let broker = SeatBroker()
        let dock = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier)
        var observations = 0
        let scene = SceneSnapshot(bundleID: "test.process", appName: "Test", windowTitle: "Test",
                                  viewportPixelSize: ViewportPixelSize(width: 10, height: 10), elements: [])
        let desktop = Self.session(broker, perceiving: { _, _ in
            observations += 1
            guard observations != 2 else { throw failure }
            return scene
        }) { _, _, _ in
            (TargetApp(pid: dock, bundleID: "test.process", name: "Test", bundleURL: nil, windows: []), SeatTarget())
        }
        _ = try await desktop.open(application: "Test", window: nil)
        let identity = try #require(desktop.id)

        await #expect(throws: AutomationFailure.self) { try await desktop.observe() }

        #expect(desktop.id == identity)
        #expect(desktop.holdsComputer)
        #expect(broker.queue.entries.count == 1)
        _ = try await desktop.observe()
        await desktop.close()
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("an idempotent close preserves cleanup warnings without retrying the quit request")
    func aSecondCloseKeepsTheCleanupWarning() async throws {
        let owned: pid_t = 900_003
        var asked: [pid_t] = []
        let ledger = LaunchLedger(terminate: { asked.append($0) }, isTerminated: { _ in false })
        ledger.record(.openedByAgent, for: owned)
        let broker = SeatBroker(configuration: .init(), ledger: ledger)
        let desktop = try Self.seated(broker, holding: owned)
        _ = try await desktop.open(application: "Test", window: nil)

        await desktop.close()
        let warning = try #require(desktop.closeWarning)
        #expect(warning.contains("still running after the quit request"))
        await desktop.close()

        #expect(desktop.closeWarning == warning)
        #expect(asked == [owned])
        #expect(desktop.id == nil)
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("a late observation cannot affect a newer worker session", arguments: [true, false])
    func anOldObservationCannotAffectTheNewSession(_ losesAssignment: Bool) async throws {
        let broker = SeatBroker()
        let dock = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier)
        var observations = 0
        var resumeOldObservation: CheckedContinuation<Void, Never>?
        let scene = SceneSnapshot(bundleID: "test.process", appName: "Test", windowTitle: "Test",
                                  viewportPixelSize: ViewportPixelSize(width: 10, height: 10), elements: [])
        let desktop = Self.session(broker, perceiving: { _, _ in
            observations += 1
            if observations == 2 {
                await withCheckedContinuation { resumeOldObservation = $0 }
                if losesAssignment { throw ObservationUnavailable.notAssigned }
            }
            return scene
        }) { _, _, _ in
            (TargetApp(pid: dock, bundleID: "test.process", name: "Test", bundleURL: nil, windows: []), SeatTarget())
        }
        _ = try await desktop.open(application: "Test", window: nil)
        let oldObservation = Task { try await desktop.observe() }
        await Self.until { resumeOldObservation != nil }
        let continuation = try #require(resumeOldObservation)
        await desktop.close()
        _ = try await desktop.open(application: "Test", window: nil)
        let newIdentity = try #require(desktop.id)

        continuation.resume()
        await #expect(throws: AutomationFailure.self) { try await oldObservation.value }

        #expect(desktop.id == newIdentity)
        #expect(desktop.holdsComputer)
        #expect(broker.queue.entries.count == 1)
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
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !broker.queue.entries.contains(where: { $0.label == Self.label }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
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
            .screenRecording: "Screen Recording", .accessibility: "Accessibility",
            .postEvent: "Keyboard and Mouse Control"
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

    @Test("a different opening window is refused with its numbers and without exposing its scene")
    func anOpeningIdentityMismatchIsWorded() {
        let process = ProcessIdentity(processID: 4242, serialNumberHigh: 1, serialNumberLow: 4242)
        let expected = WindowIdentity(process: process, windowNumber: 777, ownerConnectionID: 5242)
        let observed = WindowIdentity(process: process, windowNumber: 778, ownerConnectionID: 5242)
        let refusal = BrokeredAutomationSession.refusal(for: SeatDrivingFailure.initialWindowChanged(
            expected: expected,
            observed: observed
        ))
        #expect(refusal is AutomationFailure)
        #expect(String(describing: refusal).contains("adopted identity of window 777"))
        #expect(String(describing: refusal).contains("reported window: 778"))
        #expect(String(describing: refusal).contains("No scene from that window was returned and no input was sent"))
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

    @Test("a turn's seat line names the live session, and once it is released the application it had",
          .timeLimit(.minutes(1)))
    func theTurnStatusNamesTheLiveSessionOrTheLastApplication() async throws {
        let broker  = SeatBroker()
        let idle    = IdleClock()
        let desktop = try Self.seated(broker, idle: idle)
        #expect(desktop.turnStatus == "Mecum seat: no session is open.")

        try await desktop.turn { _ = try await desktop.open(application: "Test", window: nil) }
        let id   = try #require(desktop.id)
        var live = ""
        try await desktop.turn { live = desktop.turnStatus }
        #expect(live == "Mecum seat: session \(id.uuidString) is open on Test (test.process), window \"Test\". "
            + "Observe it with this session ID before acting.")

        // The first turn's wait was cancelled by the second, whose wait then releases the seat.
        await idle.elapseOldest()
        await idle.elapseOldest()
        await Self.until { !desktop.holdsComputer }
        #expect(desktop.id == nil)
        #expect(desktop.turnStatus == "Mecum seat: no session is open. "
            + "The last one was on Test (test.process), window \"Test\".")
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

    @Test("a moment in front is read again only when the item read enabled, and a refusal says why")
    func menuRefreshReadsTheSeatsAnswer() {
        #expect(BrokeredAutomationSession.refresh(after: .ready(afterMilliseconds: 1050)) == .readAgain)
        #expect(BrokeredAutomationSession.refresh(after: .notReady(afterMilliseconds: 2000))
            == .stillDisabled(reason: nil), "the disabled refusal stands as it is")
        #expect(BrokeredAutomationSession.refresh(after: .refused(.noUserWindow)) == .stillDisabled(
            reason: "It could not be brought forward for a moment, because no window of the person's own "
                + "is in front to come back to."
        ))
        #expect(BrokeredAutomationSession.refresh(after: .refused(.dialogOpen)) == .blockedByDialog,
                "an open dialog gets its own refusal, not the stale-menu one")
        guard case .stillDisabled(.some) = BrokeredAutomationSession.refresh(after: .handbackNotVerified) else {
            Issue.record("an unverified handback was not explained"); return
        }
    }

    @Test("apps keeps the ranking's order and names the folder only where two share a name")
    func appsNameTheFolderOnlyWhereTwoShareAName() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let apps = [
            TargetApp(pid: 7, bundleID: "com.avid.ProTools", name: "Pro Tools",
                      bundleURL: URL(fileURLWithPath: "/Applications/Pro Tools.app"), windows: [],
                      version: "26.4.1.179"),
            TargetApp(pid: nil, bundleID: "com.example.ProTools", name: "Pro Tools",
                      bundleURL: home.appending(path: "Applications/Pro Tools.app"), windows: []),
            TargetApp(pid: nil, bundleID: "com.avid.ProToolsDeveloper", name: "Pro Tools Developer",
                      bundleURL: URL(fileURLWithPath: "/Applications/Pro Tools Developer.app"), windows: []),
        ]
        #expect(BrokeredAutomationSession.candidates(apps, defaultBrowser: nil) == [
            ApplicationCandidate(name: "Pro Tools", bundleID: "com.avid.ProTools", version: "26.4.1.179",
                                 isRunning: true, location: "/Applications"),
            ApplicationCandidate(name: "Pro Tools", bundleID: "com.example.ProTools", version: nil,
                                 isRunning: false, location: "~/Applications"),
            ApplicationCandidate(name: "Pro Tools Developer", bundleID: "com.avid.ProToolsDeveloper", version: nil,
                                 isRunning: false),
        ])
    }

    @Test("apps marks the application that opens web links by default, and no other")
    func appsMarksOnlyTheDefaultBrowser() {
        let apps = [
            TargetApp(pid: 7, bundleID: "com.example.Browser", name: "Browser", bundleURL: nil, windows: []),
            TargetApp(pid: nil, bundleID: "com.example.Other", name: "Other Browser", bundleURL: nil, windows: []),
            TargetApp(pid: 9, bundleID: "", name: "Helper", bundleURL: nil, windows: []),
        ]
        let marked = BrokeredAutomationSession.candidates(apps, defaultBrowser: "com.example.Browser")
        #expect(marked.map(\.isDefaultBrowser) == [true, false, false])
        #expect(BrokeredAutomationSession.candidates(apps, defaultBrowser: nil).allSatisfy { !$0.isDefaultBrowser })
        #expect(BrokeredAutomationSession.candidates(apps, defaultBrowser: "").allSatisfy { !$0.isDefaultBrowser },
                "an application with no bundle ID is nobody's browser")
    }
}
