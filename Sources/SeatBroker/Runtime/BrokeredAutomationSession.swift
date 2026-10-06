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

    /// Reads the scene of the application `pid` through `runtime`. A seam for the controlled tests;
    /// the public init perceives through Ron's engine.
    typealias Perceiving = @MainActor (EngineRuntime, _ pid: pid_t) async throws -> SceneSnapshot

    /// Returns once `window` has passed, or throws when cancelled. A seam for the controlled tests,
    /// which let the window elapse when they choose; the public init sleeps on the task's clock.
    typealias IdleWaiting = @MainActor (_ window: Duration) async throws -> Void

    /// How long a worker keeps the seat after its turn ends with no other turn, Eliomar's choice:
    /// a quick follow-up ("and what is the first one called?") still finds the session and its
    /// context, and the window comes back to the person's screen soon after the worker goes quiet.
    static let idleWindow: Duration = .seconds(30)

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
    @ObservationIgnored private let idleWindow: Duration
    @ObservationIgnored private let waitIdle: IdleWaiting

    /// Whether the seat a held target borrows stopped for good, which ends this session.
    @ObservationIgnored private let stoppedForGood: @MainActor (SeatTarget) -> Bool

    @ObservationIgnored private var lease: SeatLease?
    @ObservationIgnored private var target: SeatTarget?
    @ObservationIgnored private var runtime: EngineRuntime?
    @ObservationIgnored private var application: NSRunningApplication?
    @ObservationIgnored private var closing: Task<Void, Never>?
    public private(set) var closeWarning: String?
    @ObservationIgnored private var isInTurn = false
    @ObservationIgnored private var idleRelease: Task<Void, Never>?

    /// The application the last successful `open` seated, with its window's title in the first scene,
    /// empty when the scene had none. Kept across `close`, so a later turn can name it.
    @ObservationIgnored private var lastOpened: (name: String, bundleID: String, window: String)?

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
        perceiving        : @escaping Perceiving,
        idleWindow        : Duration = idleWindow,
        waitIdle          : @escaping IdleWaiting = { try await Task.sleep(for: $0) },
        stoppedForGood    : @escaping @MainActor (SeatTarget) -> Bool = {
            SeatAdmission.stoppedForGood(try? $0.agentSeat())
        }
    ) {
        self.broker             = broker
        self.label              = workerID.uuidString
        self.knowledgeDirectory = knowledgeDirectory
        self.allowsDestructive  = allowsDestructive
        self.missingGrant       = missingGrant
        self.requestGrants      = requestGrants
        self.seating            = seating
        self.perceiving         = perceiving
        self.idleWindow         = idleWindow
        self.waitIdle           = waitIdle
        self.stoppedForGood     = stoppedForGood
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

    /// The seat as a worker's turn begins, which Mecum puts ahead of the turn's prompt so the agent
    /// needs no status call: the live session to observe by its ID, or the application the last one had.
    ///
    /// Read inside `turn`, so no idle release is pending and a close already under way reads as no
    /// session. Nothing waits in the queue then: an `open` waits only inside a turn's tool call.
    public var turnStatus: String {
        let last = lastOpened.map { app in
            "\(app.name) (\(app.bundleID))" + (app.window.isEmpty ? "" : ", window \"\(app.window)\"")
        }
        guard let id else {
            return "Mecum seat: no session is open." + (last.map { " The last one was on \($0)." } ?? "")
        }
        return "Mecum seat: session \(id.uuidString) is open" + (last.map { " on \($0)" } ?? "")
            + ". Observe it with this session ID before acting."
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
        // A seat that stopped for good ends its session: this open replaces it, as close_session would.
        if case .holding = phase, let target, stoppedForGood(target) { await close() }
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
            lastOpened = (seated.opened.name, seated.opened.bundleID, scene.windowTitle)
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

    public func windowCandidates(ownedBy processID: pid_t) throws -> [WindowRow] {
        TargetEnumerator.windows(of: processID).map {
            WindowRow(layer: 0, frame: $0.frame, title: $0.title, number: $0.windowNumber)
        }
    }

    /// `apps` as the worker reads them, in their order, each one's folder added only where two
    /// of them share a name, since the name alone would not say which is which. The application
    /// whose bundle ID is `defaultBrowser` is marked as the default browser.
    static func candidates(
        _ apps        : [TargetApp],
        defaultBrowser: String? = WebBrowsers.defaultBundleID()
    ) -> [ApplicationCandidate] {
        let shared = Set(Dictionary(grouping: apps, by: \.name).filter { $0.value.count > 1 }.keys)
        return apps.map { app in
            let folder = app.bundleURL.map {
                ($0.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            }
            return ApplicationCandidate(
                name            : app.name,
                bundleID        : app.bundleID,
                version         : app.version,
                isRunning       : app.isRunning,
                location        : shared.contains(app.name) ? folder : nil,
                isDefaultBrowser: !app.bundleID.isEmpty && app.bundleID == defaultBrowser
            )
        }
    }

    public func observe() async throws -> SceneSnapshot {
        let (application, runtime, _) = try current()
        let observingSession = id
        do {
            let scene = try await perceiving(runtime, application.processIdentifier)
            guard id == observingSession else {
                throw AutomationFailure("The session changed while observing. Use status and observe the current session.")
            }
            return scene
        } catch {
            if error as? ObservationUnavailable == .notAssigned, id == observingSession {
                await close()
                let message = "The observed session ended because it has no assigned application. "
                    + "Use status and list current windows; open the intended window explicitly before continuing. "
                    + "Earlier effects may remain. Do not replay input automatically."
                throw AutomationFailure(message + (closeWarning.map { " " + $0 } ?? ""))
            }
            throw Self.refusal(for: error)
        }
    }

    /// A fresh scene with the pixels it was read from, for a person who asks to see what the agent sees.
    public func observeWithImage() async throws -> (scene: SceneSnapshot, image: CGImage?) {
        let scene = try await observe()
        return (scene, target?.lastSceneImage)
    }

    public func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws
        -> ActOutcome {
        let (application, runtime, seat) = try current()
        if case .refuse(let sentence) = try await SeatAdmission.awaited(
            seat.agentSeat(),
            application: application.localizedName ?? "the application"
        ) {
            throw AutomationFailure(sentence)
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
        let remotePanel = try seat.agentSeat().holdsRemoteFilePanel
        return await enriched(runtime.engine(
            allowsDestructive           : allowsDestructive,
            contextMenusOnTextFieldsOnly: Self.drawsMenusUnderThePointer(application),
            selectsFieldsByTripleClick  : remotePanel,
            refusesMenuOpeningClicks    : remotePanel
        ).act(request), by: runtime)
    }

    public func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        let (application, runtime, seat) = try current()
        if case .refuse(let sentence) = try await SeatAdmission.awaited(
            seat.agentSeat(),
            application: application.localizedName ?? "the application"
        ) {
            throw AutomationFailure(sentence)
        }
        if case .contextMenu(let control, let item) = input {
            let selector = SeatContextMenuSelector(target: seat, pipeline: ProductionPerception.pipeline())
            let chosen = try await selector.select(
                item: item, on: control,
                identity: SeatDriving.ApplicationIdentity(
                    bundleID: application.bundleIdentifier ?? "pid.\(application.processIdentifier)",
                    name: application.localizedName ?? "application"
                ),
                section: section,
                permissions: ActionPermissions(
                    allowsDestructive: allowsDestructive,
                    contextMenusOnTextFieldsOnly: Self.drawsMenusUnderThePointer(application)
                )
            )
            return await enriched(chosen, by: runtime)
        }
        let request = InputRequest(
            processID: application.processIdentifier,
            bundleID : application.bundleIdentifier ?? "pid.\(application.processIdentifier)",
            appName  : application.localizedName ?? "application",
            input    : input,
            section  : section
        )
        return await enriched(runtime.engine(
            allowsDestructive           : allowsDestructive,
            contextMenusOnTextFieldsOnly: Self.drawsMenusUnderThePointer(application),
            selectsFieldsByTripleClick  : try seat.agentSeat().holdsRemoteFilePanel
        ).deliver(request), by: runtime)
    }

    public func menu(path: String) async throws -> ActOutcome {
        let (application, _, seat) = try current()
        let agentSeat = try seat.agentSeat()
        if case .refuse(let sentence) = await SeatAdmission.awaited(
            agentSeat,
            application: application.localizedName ?? "the application"
        ) {
            throw AutomationFailure(sentence)
        }
        let processID = application.processIdentifier
        let platform = TargetPlatform.chosen(
            bundleURL       : application.bundleURL,
            bundleIdentifier: application.bundleIdentifier
        )
        // TextEdit leaves its editing menu disabled while its text view accepts
        // background input. Read and dispatch its menu during verified activation,
        // just as for Adobe; other native hosts remain separately qualified.
        let preparesMenu = platform == .adobeUXP || application.bundleIdentifier == "com.apple.TextEdit"
        if preparesMenu {
            return try await MenuBarCommand.performInFront(
                path,
                processID: processID,
                allowsDestructive: allowsDestructive,
                withFront: { command in
                    let outcome = await agentSeat.performMenuCommandBrieflyInFront(
                        when: { MenuBarCommand.isEnabled(path, processID: processID) },
                        performOnce: command
                    )
                    if case .ready = outcome { return nil }
                    return Self.briefMenuFailure(outcome)
                },
                observe: { try await self.observe() }
            )
        }
        return try await MenuBarCommand.perform(
            path,
            processID        : processID,
            allowsDestructive: allowsDestructive,
            observe          : { try await self.observe() }
        )
    }

    private static func briefMenuFailure(_ outcome: BriefActivationOutcome) -> String {
        switch refresh(after: outcome) {
            case .stillDisabled(let reason): return reason ?? "The admitted menu command was not dispatched."
            case .blockedByDialog: return "A dialog is open; answer it before another menu command."
            case .readAgain: return "The admitted menu command was not dispatched."
        }
    }

    /// What a moment in front answered, as the menu command reads it: the item is read again only
    /// when it read enabled in front, a dialog open in the seat gets the dialog's own refusal, and
    /// any other refusal says why in one sentence a worker can repeat, with none of the seat's
    /// internals.
    static func refresh(after outcome: BriefActivationOutcome) -> MenuBarCommand.Refresh {
        switch outcome {
            case .ready:
                return .readAgain
            case .notReady:
                return .stillDisabled(reason: nil)
            case .handbackNotVerified:
                return .stillDisabled(reason: "It was brought forward for a moment, but the return to "
                    + "the person's own window was not verified. Observe before more input.")
            case .refused(let refusal):
                let because: String
                switch refusal {
                    case .dialogOpen         : return .blockedByDialog
                    case .noFocusRecovery    : because = "this seat cannot give the person's focus back"
                    case .seatNotReady       : because = "the seat is busy"
                    case .noUserWindow       : because = "no window of the person's own is in front to come back to"
                    case .targetNotPrepared  : because = "its window could not be identified"
                    case .frontRequestRefused: because = "macOS refused to bring it forward"
                }
                return .stillDisabled(reason: "It could not be brought forward for a moment, because \(because).")
        }
    }

    public func press(button: String) async throws -> ActOutcome {
        let (application, _, seat) = try current()
        let agentSeat = try seat.agentSeat()
        if case .refuse(let sentence) = await SeatAdmission.awaited(
            agentSeat,
            application: application.localizedName ?? "the application"
        ) {
            throw AutomationFailure(sentence)
        }
        return try await DialogButtonPress.perform(
            button,
            processID        : application.processIdentifier,
            dialogs          : agentSeat.openDialogs.map(\.windowNumber),
            allowsDestructive: allowsDestructive,
            observe          : { try await self.observe() }
        )
    }

    public func select(control: String, item: String) async throws -> ActOutcome {
        let (application, runtime, target) = try current()
        let selector = SeatDropdownSelector(target: target, pipeline: ProductionPerception.pipeline())
        let result = try await selector.select(
            control: control, item: item,
            identity: SeatDriving.ApplicationIdentity(
                bundleID: application.bundleIdentifier ?? "pid.\(application.processIdentifier)",
                name: application.localizedName ?? "application"
            ),
            permissions: ActionPermissions(allowsDestructive: allowsDestructive),
            dryRun: false
        )
        return await enriched(result.outcome, by: runtime)
    }

    /// Flushes the Brain, ends the borrow, finishes with the application and gives the seat back.
    ///
    /// The cleanup runs in a task of its own, so a cancelled caller still gives the seat back and a
    /// second call waits for the first. What finishing leaves the person to do (an application the
    /// seat could not confirm home, so left running) has no channel in this role, so it is logged.
    public func close() async {
        idleRelease?.cancel()
        idleRelease = nil
        if let closing { await closing.value; return }
        guard phase != .idle else { return }
        closeWarning = nil
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
                closeWarning = await lease.session.finishUsingApp()
                if let left = closeWarning {
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

    /// Whether a custom widget of `application` opens its contextual menu under the person's pointer
    /// rather than at the click: measured on DaVinci Resolve's media pool, a Qt application, whose menu
    /// opened on the person's screen and left the seat suspended until it was closed there.
    static func drawsMenusUnderThePointer(_ application: NSRunningApplication) -> Bool {
        let choice = TargetPlatform.chosen(
            bundleURL       : application.bundleURL,
            bundleIdentifier: application.bundleIdentifier
        )
        if case .qtToolkit = choice { return true }
        return false
    }

    /// `outcome` with its scene enriched by the Brain, so an action's scene reads like an observed one.
    /// The engine already recorded the transition, so the scene is not observed again.
    private func enriched(_ outcome: ActOutcome, by runtime: EngineRuntime) async -> ActOutcome {
        guard let scene = outcome.scene else { return outcome }
        return ActOutcome(outcome.kind, outcome.message, scene: await runtime.memory.enrich(scene))
    }

    private func current() throws -> (NSRunningApplication, EngineRuntime, SeatTarget) {
        guard let application, !application.isTerminated, let runtime, let target else {
            throw AutomationFailure("No live application session. Use windows and open_session, then observe.")
        }
        return (application, runtime, target)
    }

    /// The window the seat's latest observation captured: the latest scene's, or the one under its pop-up.
    public var observedWindowNumber: Int? { target?.lastCapturedWindow?.id }

    /// The windows of the application the latest scene saw on the person's screen, outside the seat,
    /// each named by its window server title and the kind the seat read, in the worker's sentence.
    public var seatNotice: String? {
        guard let target, let application else { return nil }
        let seat = try? target.agentSeat()
        return SeatErrorMapper.notice(
            for        : target.lastShownOutsideSeat.map(\.windowNumber),
            application: application.localizedName ?? "the application"
        ) { number in
            Self.windowName(number, role: seat?.surfaceRole(ofWindow: number))
        }
    }

    /// "window 7631 "Change Clip Speed" (dialog)", leaving out what nothing could read.
    static func windowName(
        _ number: Int,
        role    : SurfaceRole?
    ) -> String {
        let row = CGWindowID(exactly: number).flatMap {
            (CGWindowListCopyWindowInfo(.optionIncludingWindow, $0) as? [[String: Any]])?.first
        }
        let title = row?[kCGWindowName as String] as? String ?? ""
        let kind: String? = switch role {
            case .document?        : "window"
            case .dialog?          : "dialog"
            case .interactivePanel?: "panel"
            case .contextualMenu?  : "menu"
            case .tooltip?         : "tooltip"
            case .decoration?      : "decoration"
            case nil               : nil
        }
        return "window \(number)" + (title.isEmpty ? "" : " \"\(title)\"") + (kind.map { " (\($0))" } ?? "")
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
        if case .initialWindowChanged(let expected, let observed)? = error as? SeatDrivingFailure {
            let actual = observed.map { String($0.windowNumber) } ?? "an unattested window"
            return AutomationFailure(
                "The first observation did not match the adopted identity of window \(expected.windowNumber) "
                    + "(reported window: \(actual)). "
                    + "No scene from that window was returned and no input was sent. "
                    + "List the current windows and open the intended one again.")
        }
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
