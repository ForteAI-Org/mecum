//
//  BrokeredAutomationSession.swift
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
import Observation
import os
import Perception
import PerceptionCore
import PrivateSymbols
import SeatCore
import SeatDriving
import SeatSession
import VisionText

/// BrokeredAutomationSession is one worker's application session over the seat SeatBroker's queue
/// grants, so a worker's tools reach the desktop only through the broker (§22.3).
///
/// It is made for one worker and owns at most one lease at a time. `open` checks the grants,
/// waits in the queue under the worker's id, opens the application through the granted
/// session and perceives and acts through Ron's `EngineRuntime` over a target borrowed from that
/// session's seat, so the scenes, the engine and the Brain are the command line's. `close` flushes
/// the Brain, ends the borrow, finishes with the application as its provenance says and gives the
/// lease back, which parks the seat warm for the next entry.
///
/// The seat is kept across the worker's turns only while nobody else waits for it. An entry that
/// starts waiting while this session holds the seat between turns makes it close at once; one that
/// arrives during a turn makes it close when `turn` ends, never inside it. The next turn then finds
/// no live session and opens one again, which waits in the queue like any other entry.
///
/// Calls are serialized by the owner, as `AutomationSessionOperating` requires. Cancelling an
/// `open` that waits in the queue takes the worker out of it; one cancelled after the seat was
/// granted gives the seat back before it throws. A failed `open` leaves nothing held, and `close`
/// is safe at any point and twice.
@MainActor
@Observable
public final class BrokeredAutomationSession: AutomationSessionOperating {

    /// Opens `application`, or its window titled `window`, on the granted session and lends a
    /// target over its seat. A seam for the controlled tests; the public init supplies the broker's.
    typealias Seating = @MainActor (AgentSession, _ application: String, _ window: String?) async throws
        -> (opened: TargetApp, target: SeatTarget)

    /// Reads the scene of the application `pid` through `runtime`. A seam for the controlled tests;
    /// the public init perceives through Ron's engine.
    typealias Perceiving = @MainActor (EngineRuntime, _ pid: pid_t) async throws -> SceneSnapshot

    /// Where the session is with the computer, which is what the worker's row reads.
    enum Phase: Equatable {
        case idle
        case waiting
        /// The seat is this session's; the application is named once it is open.
        case holding(application: String?)
    }

    private static let log = Logger(subsystem: "dev.forte.AgentSeatKit", category: "Lab")

    public private(set) var id: UUID?
    private(set) var phase = Phase.idle

    @ObservationIgnored private let broker: SeatBroker
    @ObservationIgnored private let label: String
    @ObservationIgnored private let knowledgeDirectory: URL
    @ObservationIgnored private let allowsDestructive: Bool
    @ObservationIgnored private let missingGrant: @MainActor () -> PermissionKind?
    @ObservationIgnored private let requestGrants: @MainActor () -> Void
    @ObservationIgnored private let seating: Seating
    @ObservationIgnored private let perceiving: Perceiving

    @ObservationIgnored private var lease: SeatLease?
    @ObservationIgnored private var target: SeatTarget?
    @ObservationIgnored private var runtime: EngineRuntime?
    @ObservationIgnored private var application: NSRunningApplication?
    @ObservationIgnored private var closing: Task<Void, Never>?
    @ObservationIgnored private var isInTurn = false

    /// `workerID` labels this session's entry in `SeatQueue.entries` as its `uuidString`, so two
    /// workers with one name still read their own position; no view shows that label.
    /// `knowledgeDirectory` is the Brain's, the command line's own, so what either learns applies
    /// to both. The broker is retained for the life of this session.
    public convenience init(
        broker            : SeatBroker,
        workerID          : UUID,
        knowledgeDirectory: URL,
        allowsDestructive : Bool = false
    ) {
        self.init(
            broker            : broker,
            workerID          : workerID,
            knowledgeDirectory: knowledgeDirectory,
            allowsDestructive : allowsDestructive,
            missingGrant      : { Permissions.firstMissing(of: [.screenRecording, .accessibility, .postEvent]) },
            requestGrants     : { _ = broker.requestMissingPermissions() },
            seating           : Self.seatedByTheBroker,
            perceiving        : Self.perceivedThroughTheEngine
        )
    }

    /// The broker's own path: `open(applicationNamed:windowTitled:)` launches an application that
    /// is not running and records its provenance, then the session lends a target over its seat.
    static let seatedByTheBroker: Seating = { session, application, window in
        let opened = try await session.open(applicationNamed: application, windowTitled: window)
        return (opened, try session.borrowedSeatTarget())
    }

    /// Ron's scene provider over the borrowed target, observed and enriched by the Brain.
    static let perceivedThroughTheEngine: Perceiving = { runtime, pid in
        let perceived = try await runtime.scenes.currentScene(of: pid)
        _ = try await runtime.memory.observe(perceived.scene)
        return await runtime.memory.enrich(perceived.scene)
    }

    init(
        broker            : SeatBroker,
        workerID          : UUID,
        knowledgeDirectory: URL,
        allowsDestructive : Bool,
        missingGrant      : @escaping @MainActor () -> PermissionKind?,
        requestGrants     : @escaping @MainActor () -> Void,
        seating           : @escaping Seating,
        perceiving        : @escaping Perceiving
    ) {
        self.broker             = broker
        self.label              = workerID.uuidString
        self.knowledgeDirectory = knowledgeDirectory
        self.allowsDestructive  = allowsDestructive
        self.missingGrant       = missingGrant
        self.requestGrants      = requestGrants
        self.seating            = seating
        self.perceiving         = perceiving
    }

    /// What the worker's row says about the computer, and nil while this session neither waits
    /// for a seat nor holds one. The position is read from `SeatQueue.entries`, never inferred.
    public var activity: String? {
        switch phase {
            case .idle                    : nil
            case .waiting                 : Self.waiting(label: label, in: broker.queue.entries)
            case .holding(let application): "Using \(application ?? "the computer")"
        }
    }

    /// True from the queue's grant until `close` has given the lease back, which is when the
    /// person can be offered to release the computer (§3.4). Waiting is not holding.
    public var holdsComputer: Bool {
        if case .holding = phase { true } else { false }
    }

    /// "Waiting for the computer", with how many entries are ahead when exactly one waiting entry
    /// carries `label`. Entries list the acting ones first and the waiting ones in arrival order,
    /// so an entry's index is the number ahead of it.
    static func waiting(label: String, in entries: [SeatQueue.Entry]) -> String {
        let mine = entries.indices.filter { entries[$0].label == label && entries[$0].state == .waiting }
        guard mine.count == 1, let index = mine.first else { return "Waiting for the computer" }
        return "Waiting for the computer (\(index) ahead)"
    }

    /// Checks the grants, waits for a seat, opens the application on it and returns the first
    /// scene, which the Brain observes. A missing grant is asked for through the broker and
    /// refused at once, before the queue. Any failure after the seat was granted closes, so the
    /// seat is given back before this throws; a cancellation is thrown as it came.
    public func open(application word: String, window title: String?) async throws -> SceneSnapshot {
        // A release between turns may still be finishing; this open comes after it.
        await closing?.value
        guard phase == .idle, closing == nil else {
            throw AutomationFailure("A Seat is already open. Observe it or close_session before opening another app.")
        }
        if let missing = missingGrant() {
            requestGrants()
            throw AutomationFailure(Self.refusal(missing: missing))
        }
        phase = .waiting
        let lease: SeatLease
        do {
            lease = try await broker.queue.acquire(label)
        } catch {
            phase = .idle
            throw error
        }
        self.lease = lease
        phase = .holding(application: nil)
        do {
            // The queue can admit an entry in the same turn its wait was cancelled.
            try Task.checkCancellation()
            let seated = try await seating(lease.session, word, title)
            target  = seated.target
            runtime = EngineRuntime(knowledgeDirectory: knowledgeDirectory, seat: seated.target)
            guard let pid = seated.opened.pid, let running = NSRunningApplication(processIdentifier: pid) else {
                throw AutomationFailure("\(seated.opened.name) opened and then could not be found running.")
            }
            application = running
            phase = .holding(application: seated.opened.name)
            id = UUID()
            let scene = try await observe()
            watchQueue(for: lease)
            return scene
        } catch {
            await close()
            throw Self.refusal(for: error)
        }
    }

    public func observe() async throws -> SceneSnapshot {
        let (application, runtime, _) = try current()
        return try await perceiving(runtime, application.processIdentifier)
    }

    public func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws
        -> ActOutcome {
        let (application, runtime, seat) = try current()
        guard try seat.agentSeat().state == .ready else {
            throw AutomationFailure("The Seat is not ready for input. Observe, then close and reopen if "
                                    + "recovery is needed.")
        }
        if verb == .setToggle, desiredState != .on && desiredState != .off {
            throw AutomationFailure("set_toggle requires value on or off.")
        }
        let request = ActionRequest(
            processID: application.processIdentifier,
            bundleID: application.bundleIdentifier ?? "pid.\(application.processIdentifier)",
            appName: application.localizedName ?? "application",
            target: target, verb: verb, section: section, desiredState: desiredState
        )
        return await runtime.engine(allowsDestructive: allowsDestructive).act(request)
    }

    public func select(control: String, item: String) async throws -> ActOutcome {
        let (application, _, target) = try current()
        let selector = SeatDropdownSelector(target: target, pipeline: ScenePipeline(text: VisionTextRecognizer()))
        let result = try await selector.select(
            control: control, item: item,
            identity: SeatDriving.ApplicationIdentity(
                bundleID: application.bundleIdentifier ?? "pid.\(application.processIdentifier)",
                name: application.localizedName ?? "application"
            ),
            permissions: ActionPermissions(allowsDestructive: allowsDestructive),
            dryRun: false
        )
        return result.outcome
    }

    /// Flushes the Brain, ends the borrow, finishes with the application and gives the seat back.
    ///
    /// The cleanup runs in a task of its own, so a cancelled caller still gives the seat back and a
    /// second call waits for the first. What finishing leaves the person to do (an application the
    /// seat could not confirm home, so left running) has no channel in this role, so it is logged.
    public func close() async {
        if let closing { await closing.value; return }
        let runtime = self.runtime
        let target  = self.target
        let lease   = self.lease
        self.runtime = nil
        self.target  = nil
        self.lease   = nil
        application  = nil
        id           = nil
        let cleanup = Task {
            await runtime?.finish()
            await target?.stop()
            if let lease {
                if let left = await lease.session.finishUsingApp() {
                    Self.log.error("A worker's session closed with this left to do: \(left, privacy: .public)")
                }
                lease.giveBack()
            }
            // Reset here, so every caller awaiting this task finds the session idle when it resumes.
            closing = nil
            phase   = .idle
        }
        closing = cleanup
        await cleanup.value
    }

    /// Runs one turn of the worker's agent, and closes afterwards when another entry is waiting in
    /// the queue, which gives the seat back. Nothing is released while `body` runs, since the agent
    /// may be between an observation and an act. A worker alone keeps the seat across turns.
    public func turn(_ body: () async throws -> Void) async throws {
        isInTurn = true
        do {
            try await body()
        } catch {
            isInTurn = false
            await releaseIfSomeoneWaits()
            throw error
        }
        isInTurn = false
        await releaseIfSomeoneWaits()
    }

    /// Closes when an open session is idle between turns and an entry is waiting for the seat.
    private func releaseIfSomeoneWaits() async {
        guard !isInTurn, id != nil, closing == nil,
              broker.queue.entries.contains(where: { $0.state == .waiting })
        else { return }
        await close()
    }

    /// Reads the queue while `lease` is held and again on every change of its entries, so a holder
    /// idle between turns learns of a new waiting entry without a turn to end.
    private func watchQueue(for lease: SeatLease) {
        guard self.lease === lease else { return }
        let isSomeoneWaiting = withObservationTracking {
            broker.queue.entries.contains { $0.state == .waiting }
        } onChange: { [weak self] in
            // Called before the change lands, so the queue is read again once it has.
            Task { @MainActor in self?.watchQueue(for: lease) }
        }
        if isSomeoneWaiting { Task { await releaseIfSomeoneWaits() } }
    }

    private func current() throws -> (NSRunningApplication, EngineRuntime, SeatTarget) {
        guard let application, !application.isTerminated, let runtime, let target else {
            throw AutomationFailure("No live application session. Use windows and open_session, then observe.")
        }
        return (application, runtime, target)
    }

    /// The refusal for a missing grant: which one, that nothing was opened, and what to do.
    static func refusal(missing kind: PermissionKind) -> String {
        let (name, pane) = switch kind {
            case .screenRecording: ("Screen Recording", "Screen & System Audio Recording")
            case .accessibility  : ("Accessibility", "Accessibility")
            case .postEvent      : ("Post Event", "Accessibility")
        }
        return "Mecum is missing the macOS \(name) permission, so this worker cannot use the computer, "
            + "and nothing was opened. macOS was asked to show its prompt; if none appears, allow Mecum in "
            + "System Settings > Privacy & Security > \(pane)"
            + (kind == .screenRecording ? ", then quit and reopen Mecum" : "")
            + ". Do not retry until it is granted."
    }

    /// The worker's sentence for an application that showed no window, and every other error as it
    /// came, so a cancellation stays a cancellation.
    static func refusal(for error: any Error) -> any Error {
        guard case .noWindowShown(let name, let seconds, let wasLaunched, let wasQuit)? = error as? SeatBrokerError
        else { return error }
        let fact = wasLaunched
            ? "\(name) was launched in the background and showed no window within \(seconds) s."
            : "\(name) is running and showed no window within \(seconds) s."
        return AutomationFailure(fact
            + " Some applications show their first window only once they are brought to the front "
            + "(TextEdit's iCloud Open panel waits for that), and the seat never brings an application "
            + "to the front. Nothing was adopted and the computer was given back. "
            + ApplicationOpening.unseated(name, wasLaunched: wasLaunched, wasQuit: wasQuit)
            + " Open \(name) with a window yourself and ask again, or use another application.")
    }
}
