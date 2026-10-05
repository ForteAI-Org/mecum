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
/// session's seat, so the scenes, the engine and the Brain are the command line's. Every call
/// records what it saw under the caller's `ActionContext`, through the owner's `MemoryService`
/// (the samples, the brain's learning), and leaves its report for the adapter that records the
/// call. `close` ends the borrow, finishes with the application as its provenance says and gives
/// the lease back, which parks the seat warm for the next entry; the memory is the owner's to close.
///
/// The seat is kept after a turn for `idleWindow` without another turn, then closed, so a quick
/// follow-up reuses the open session and the window comes back soon after. A new turn cancels
/// that pending close. An entry that starts waiting while this session holds the seat between
/// turns makes it close at once; one that arrives during a turn makes it close when `turn` ends,
/// never inside it. The next turn then finds no live session and opens one again, which waits in
/// the queue like any other entry.
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

    /// Reads the window of the application `pid` through `runtime`, with its capture quality. A seam
    /// for the controlled tests; the public init perceives through Ron's engine. What is read is
    /// recorded and enriched by the session, not by the seam.
    typealias Perceiving = @MainActor (EngineRuntime, _ pid: pid_t) async throws -> PerceivedWindow

    /// Returns once `window` has passed, or throws when cancelled. A seam for the controlled tests,
    /// which let the window elapse when they choose; the public init sleeps on the task's clock.
    typealias IdleWaiting = @MainActor (_ window: Duration) async throws -> Void

    /// How long a worker keeps the seat after its turn ends with no other turn, Eliomar's choice:
    /// a quick follow-up ("and what is the first one called?") still finds the session and its
    /// context, and the window comes back to the person's screen soon after the worker goes quiet.
    static let idleWindow: Duration = .seconds(30)

    /// A developer's record of each `select` of this session, the images the selector perceived and why
    /// it decided (`SelectionDiagnostics`); nil, the default, writes nothing. `mecum chat` sets it with
    /// `--diagnose-select <directory>`; the app never does. It changes no outcome and nothing recorded.
    public var selectionDiagnostics: SelectionDiagnostics?

    /// What an agent over this session is told beyond `AutomationTools.instructions`, whose text is
    /// written around `windows`: its `open_session` goes through `AgentSession.open`, which launches an
    /// installed application that is not running and records that it did, so the application is quit
    /// again when the session is finished with it. The app's worker and `mecum chat` both run with
    /// this line, after the base text, so the two entries declare the one capability in one wording.
    public static let openingInstructions = "open_session also opens an installed application that is "
        + "not running yet: find it with apps and pass its bundleID to open_session. When several match and "
        + "the conversation does not make clear which one the person means, ask them which one, naming the "
        + "candidates, before opening either."

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

    /// What the last call left for its record (`AutomationSessionOperating.lastReport`).
    @ObservationIgnored public private(set) var lastReport: CallRecorder.Report?

    @ObservationIgnored private let broker: SeatBroker
    @ObservationIgnored private let label: String
    @ObservationIgnored private let memory: MemoryService
    @ObservationIgnored private let allowsDestructive: Bool
    @ObservationIgnored private let missingGrant: @MainActor () -> PermissionKind?
    @ObservationIgnored private let requestGrants: @MainActor () -> Void
    @ObservationIgnored private let seating: Seating
    @ObservationIgnored private let perceiving: Perceiving
    @ObservationIgnored private let idleWindow: Duration
    @ObservationIgnored private let waitIdle: IdleWaiting

    @ObservationIgnored private var lease: SeatLease?
    @ObservationIgnored private var target: SeatTarget?
    @ObservationIgnored private var runtime: EngineRuntime?
    @ObservationIgnored private var openApplication: NSRunningApplication?
    @ObservationIgnored private var closing: Task<Void, Never>?
    @ObservationIgnored private var isInTurn = false
    @ObservationIgnored private var idleRelease: Task<Void, Never>?
    @ObservationIgnored private var revision: Int64 = 0

    /// `workerID` labels this session's entry in `SeatQueue.entries` as its `uuidString`, so two
    /// workers with one name still read their own position; no view shows that label.
    /// `memory` is the owner's living memory of the Knowledge directory, the command line's own, so
    /// what either learns applies to both. The broker is retained for the life of this session.
    public convenience init(
        broker            : SeatBroker,
        workerID          : UUID,
        memory            : MemoryService,
        allowsDestructive : Bool = false
    ) {
        self.init(
            broker            : broker,
            workerID          : workerID,
            memory            : memory,
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

    /// Ron's scene provider over the borrowed target.
    static let perceivedThroughTheEngine: Perceiving = { runtime, pid in
        try await runtime.scenes.currentScene(of: pid)
    }

    init(
        broker            : SeatBroker,
        workerID          : UUID,
        memory            : MemoryService,
        allowsDestructive : Bool,
        missingGrant      : @escaping @MainActor () -> PermissionKind?,
        requestGrants     : @escaping @MainActor () -> Void,
        seating           : @escaping Seating,
        perceiving        : @escaping Perceiving,
        idleWindow        : Duration = idleWindow,
        waitIdle          : @escaping IdleWaiting = { try await Task.sleep(for: $0) }
    ) {
        self.broker             = broker
        self.label              = workerID.uuidString
        self.memory             = memory
        self.allowsDestructive  = allowsDestructive
        self.missingGrant       = missingGrant
        self.requestGrants      = requestGrants
        self.seating            = seating
        self.perceiving         = perceiving
        self.idleWindow         = idleWindow
        self.waitIdle           = waitIdle
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

    /// True while there is a window to watch: the seat is held and an application is open on it.
    public var hasScreen: Bool {
        if case .holding(.some) = phase { true } else { false }
    }

    /// A live view of the window this session drives, or nil while there is none to watch.
    /// Mount it only while `hasScreen`: a seat given back goes warm to the next entry, and a view
    /// left attached would show that worker's window.
    public func makeScreenView(contentsScale: CGFloat) -> NSView? {
        guard hasScreen, let lease else { return nil }
        return lease.session.makePreviewView(contentsScale: contentsScale)
    }

    /// The driven window's frame, for the view's proportions; zero while there is none to watch.
    public var screenFrame: CGRect {
        guard hasScreen, let lease else { return .zero }
        return lease.session.windowFrame
    }

    /// "Waiting for the computer", with how many entries are ahead when exactly one waiting entry
    /// carries `label`. Entries list the acting ones first and the waiting ones in arrival order,
    /// so an entry's index is the number ahead of it.
    static func waiting(label: String, in entries: [SeatQueue.Entry]) -> String {
        let mine = entries.indices.filter { entries[$0].label == label && entries[$0].state == .waiting }
        guard mine.count == 1, let index = mine.first else { return "Waiting for the computer" }
        return "Waiting for the computer (\(index) ahead)"
    }

    /// The application this session drives, as the memory names it; nil while none is open.
    public var application: AppContextIdentity? {
        openApplication.map(AppContextIdentity.init)
    }

    /// Checks the grants, waits for a seat, opens the application on it and returns the first
    /// scene, recorded and observed under `context` as an observation is. A missing grant is asked
    /// for through the broker and refused at once, before the queue. Any failure after the seat was
    /// granted closes, so the seat is given back before this throws; a cancellation is thrown as it came.
    public func open(application word: String, window title: String?, context: ActionContext) async throws -> SceneSnapshot {
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
            runtime = EngineRuntime(memory: memory, seat: seated.target)
            guard let pid = seated.opened.pid, let running = NSRunningApplication(processIdentifier: pid) else {
                throw AutomationFailure("\(seated.opened.name) opened and then could not be found running.")
            }
            openApplication = running
            phase = .holding(application: seated.opened.name)
            id = UUID()
            // The call's event was planned before the application was known, so the first scene is the
            // session's own observation: another event of the same producer, trace and session, with the app.
            let scene = try await observe(context: context.another(sessionID: id?.uuidString), asOwnObservation: true)
            watchQueue(for: lease)
            return scene
        } catch {
            await close()
            throw Self.refusal(for: error)
        }
    }

    /// The installed and running applications `query` names, ranked as `open` resolves a name, so
    /// what the worker is offered and what it may open cannot disagree. Needs no seat and no grant.
    public func applications(matching query: String?) async throws -> [ApplicationCandidate] {
        Self.candidates(ApplicationOpening.ranked(query, in: TargetEnumerator.targets()))
    }

    /// `apps` as the worker reads them, in their order, each one's folder added only where two
    /// of them share a name, since the name alone would not say which is which.
    static func candidates(_ apps: [TargetApp]) -> [ApplicationCandidate] {
        let shared = Set(Dictionary(grouping: apps, by: \.name).filter { $0.value.count > 1 }.keys)
        return apps.map { app in
            let folder = app.bundleURL.map {
                ($0.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            }
            return ApplicationCandidate(
                name     : app.name,
                bundleID : app.bundleID,
                version  : app.version,
                isRunning: app.isRunning,
                location : shared.contains(app.name) ? folder : nil
            )
        }
    }

    /// Perceives the window and records it as the call's `current` sample, which the Brain observes;
    /// the scene answered is the enriched one.
    public func observe(context: ActionContext) async throws -> SceneSnapshot {
        try await observe(context: context, asOwnObservation: false)
    }

    private func observe(context: ActionContext, asOwnObservation: Bool) async throws -> SceneSnapshot {
        let (application, runtime, _) = try current()
        let perceived: PerceivedWindow
        do {
            perceived = try await perceiving(runtime, application.processIdentifier)
        } catch {
            throw Self.refusal(for: error)
        }
        revision += 1
        let recorder = runtime.recorder(for: context, sessionRevision: revision)
        let scene = asOwnObservation
            ? await recorder.observe(perceived, recordingObservationOf: AppContextIdentity(application))
            : await recorder.observe(perceived)
        lastReport = await recorder.report()
        return scene
    }

    public func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?,
                    context: ActionContext) async throws -> ActOutcome {
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
        let recorder = runtime.recorder(for: context, sessionRevision: revision)
        let outcome  = try await runtime.engine(allowsDestructive: allowsDestructive, observer: recorder).act(request)
        lastReport   = await recorder.report()
        return outcome
    }

    public func deliver(_ input: InputRequest.Input, section: String?, context: ActionContext) async throws -> ActOutcome {
        let (application, runtime, seat) = try current()
        guard try seat.agentSeat().state == .ready else {
            throw AutomationFailure("The Seat is not ready for input. Observe, then close and reopen if "
                                    + "recovery is needed.")
        }
        let request = InputRequest(
            processID: application.processIdentifier,
            bundleID : application.bundleIdentifier ?? "pid.\(application.processIdentifier)",
            appName  : application.localizedName ?? "application",
            input    : input,
            section  : section
        )
        let recorder = runtime.recorder(for: context, sessionRevision: revision)
        let outcome  = try await runtime.engine(allowsDestructive: allowsDestructive, observer: recorder).deliver(request)
        lastReport   = await recorder.report()
        return outcome
    }

    public func select(control: String, item: String, context: ActionContext) async throws -> ActOutcome {
        let (application, runtime, target) = try current()
        let selector = SeatDropdownSelector(target: target, pipeline: ScenePipeline(text: VisionTextRecognizer()))
        let recorder = runtime.recorder(for: context, sessionRevision: revision)
        let probe = selectionDiagnostics?.probe(callID: context.eventID, control: control, item: item,
                                                windowNumber: try? target.currentWindow().id)
        let result: SelectionResult
        do {
            result = try await selector.select(
                control: control, item: item,
                identity: SeatDriving.ApplicationIdentity(
                    bundleID: application.bundleIdentifier ?? "pid.\(application.processIdentifier)",
                    name: application.localizedName ?? "application"
                ),
                permissions: ActionPermissions(allowsDestructive: allowsDestructive),
                dryRun: false,
                onMenu: { probe?.menuObserved($0) },
                onCapture: { probe?.capture($0, $1) }
            )
        } catch {
            probe?.finish(error)
            throw error
        }
        probe?.finish(result)
        await recorder.record(before: result.before, menu: result.menu, after: result.after)
        lastReport = await recorder.report()
        return result.outcome
    }

    /// Ends the borrow, finishes with the application and gives the seat back.
    ///
    /// The cleanup runs in a task of its own, so a cancelled caller still gives the seat back and a
    /// second call waits for the first. What finishing leaves the person to do (an application the
    /// seat could not confirm home, so left running) has no channel in this role, so it is logged.
    public func close() async {
        idleRelease?.cancel()
        idleRelease = nil
        if let closing { await closing.value; return }
        let target  = self.target
        let lease   = self.lease
        self.runtime = nil
        self.target  = nil
        self.lease   = nil
        openApplication = nil
        id           = nil
        let cleanup = Task {
            if let target { await target.stop() }
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
    /// the queue, which gives the seat back; otherwise it closes once `idleWindow` passes with no
    /// new turn. Starting a turn cancels that pending close, and nothing is released while `body`
    /// runs, since the agent may be between an observation and an act.
    public func turn(_ body: () async throws -> Void) async throws {
        idleRelease?.cancel()
        idleRelease = nil
        isInTurn = true
        do {
            try await body()
        } catch {
            await endTurn()
            throw error
        }
        await endTurn()
    }

    private func endTurn() async {
        isInTurn = false
        await releaseIfSomeoneWaits()
        releaseWhenIdle()
    }

    /// Closes once an open session has gone `idleWindow` without a turn. The wait is tied to the
    /// lease held now, so one that outlives a close, or returns under a later lease, closes nothing.
    private func releaseWhenIdle() {
        guard let lease, id != nil, closing == nil else { return }
        idleRelease?.cancel()
        idleRelease = Task { [weak self, waitIdle, idleWindow] in
            do {
                try await waitIdle(idleWindow)
            } catch {
                // The wait ends early only when cancelled: a turn started or the session closed.
                return
            }
            guard let self, !Task.isCancelled, self.lease === lease, !isInTurn, closing == nil else { return }
            await close()
        }
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
        guard let application = openApplication, !application.isTerminated, let runtime, let target else {
            throw AutomationFailure("No live application session. Use windows and open_session, then observe.")
        }
        return (application, runtime, target)
    }

    /// The refusal for a missing grant: which one, that nothing was opened, and what to do.
    static func refusal(missing kind: PermissionKind) -> String {
        let (name, pane) = switch kind {
            case .screenRecording: ("Screen Recording", "Screen & System Audio Recording")
            case .accessibility  : ("Accessibility", "Accessibility")
            case .postEvent      : ("Keyboard and Mouse Control", "Accessibility")
        }
        return "Mecum is missing the macOS \(name) permission, so this worker cannot use the computer, "
            + "and nothing was opened. macOS was asked to show its prompt; if none appears, allow Mecum in "
            + "System Settings > Privacy & Security > \(pane)"
            + (kind == .screenRecording ? ", then quit and reopen Mecum" : "")
            + ". Do not retry until it is granted."
    }

    /// The worker's sentence for an application that showed no window or a seat that could not
    /// observe, and every other error as it came, so a cancellation stays a cancellation.
    static func refusal(for error: any Error) -> any Error {
        // The seat's own reason reaches the agent as the router prints it, which for an enum is its
        // case and payload: the sentence is the one the seat's mapper writes for a person.
        if error is ObservationUnavailable {
            return AutomationFailure(SeatErrorMapper.message(for: error))
        }
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
