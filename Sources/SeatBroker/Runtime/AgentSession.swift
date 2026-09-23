import AppKit
import EngineCore
import Foundation
import ModelTransports
import os
import Perception
import PerceptionCore
import SeatCapture
import SeatCore
import SeatDriving
import SeatSession

/// One background display and one seat, used by one application at a time.
/// `observe` perceives the current frame; `execute` runs one action against
/// the latest observation and returns the verified before/after report.
///
/// The seat outlives the application in it. `use` finishes with the
/// application the seat is holding and adopts the next one, and `close` takes
/// the display down. Applications are used in turn: the seat never holds two.
///
/// A session starts holding nothing at all: the person opens the chat before
/// there is anything to talk about, and which application to open is the
/// planner's first decision. `observe` and `execute` refuse until one is
/// adopted, which is what makes the empty session safe to hand out.
@MainActor
public final class AgentSession {

    private static let diagnosticLog = Logger(subsystem: "dev.forte.AgentSeatKit", category: "Lab")
    /// The application the session is working on, and the window of it that
    /// was asked for. They name the last application `use` was called with,
    /// which is not the same as the seat holding it: an adoption that fails
    /// leaves the seat empty and these still name what the person last saw.
    /// Both are nil until the first `use`, which is the empty session.
    public private(set) var app: TargetApp?
    public private(set) var target: TargetWindow?
    public private(set) var lastObservation: SceneObservation?
    public private(set) var isOpen = true

    /// True while the seat is holding a window of `app`. Public because it is
    /// the question the planner asks before observing: nothing adopted means
    /// there is no scene to decide on and the only legal decision is an open.
    public var isUsingApp: Bool { held != nil }

    private let driver: SeatDriver
    private let ledger: LaunchLedger
    /// The runtime that made this session. It is here for one reason: opening
    /// an application is launching one, and `SeatBroker.launch` is the
    /// only place in the kit that starts a process and writes its provenance.
    /// The environment does not hold its sessions, so this reference is not a
    /// cycle; it keeps the runtime alive for as long as a session uses it.
    private let environment: SeatBroker
    private let perception: ScenePipeline
    private let recorder: RunRecorder
    private var lastDelivery: SeatObservationDelivery?
    private var lastScene: SceneSnapshot?
    private var held: HeldApp?

    /// The application the session has to finish with: the process whose window
    /// was handed to the seat, and where that application came from. Provenance
    /// is taken once, when the window is handed over, so finishing with it never
    /// has to ask the question again. The name is carried rather than read back
    /// off `app`, which names the last application `use` was called with and is
    /// not always this one.
    private struct HeldApp {
        let pid: pid_t
        let name: String
        let provenance: AppProvenance
    }

    init(driver: SeatDriver, ledger: LaunchLedger, perception: ScenePipeline,
         recorder: RunRecorder, environment: SeatBroker) {
        self.driver = driver
        self.ledger = ledger
        self.perception = perception
        self.recorder = recorder
        self.environment = environment
    }

    /// Finishes with the application the seat is holding and adopts `window`
    /// of `app` in its place.
    ///
    /// The application is registered before the adoption is attempted, not
    /// after it returns. An application the agent opened is the agent's to quit
    /// whether or not its window ever reached the seat: registering afterwards
    /// left a failed adoption with nothing to finish with, and the application
    /// the agent had launched seconds earlier stayed running.
    ///
    /// Finishing is what makes room, so its refusal ends this call instead of
    /// being dropped: the seat still has the previous application assigned,
    /// this window would be moved onto the background display and then refused
    /// as no member of that assignment, and the sentence the person gets would
    /// name a Window ID rather than the application nobody gave back.
    public func use(_ window: TargetWindow, of app: TargetApp) async throws {
        guard isOpen else { throw SeatBrokerError.sessionClosed }
        if let refusal = await finishWithHeldApp() {
            throw SeatBrokerError.driver(refusal)
        }
        self.app = app
        self.target = window
        // Nothing perceived in the previous application survives into this one:
        // a scene's indices mean something only for the frame they were read from.
        lastObservation = nil
        lastDelivery = nil
        lastScene = nil
        held = HeldApp(pid: window.pid, name: app.name,
                       provenance: ledger.provenance(of: window.pid))
        do {
            try await driver.adopt(window)
        } catch {
            // A refusal to quit is added to the failure and never replaces it:
            // the adoption's own sentence is still the diagnosis.
            let refusal = await finishWithHeldApp()
            guard let refusal else { throw error }
            throw SeatBrokerError.driver(error.localizedDescription + " " + refusal)
        }
    }

    /// Resolves `name` to one installed application, opens it and seats it in
    /// place of whatever the seat was holding.
    ///
    /// The order is what makes a wrong name harmless: the name is resolved and
    /// the application launched before `use` is called, so nothing is given
    /// back until there is something to put in its place. A name that resolves
    /// to nothing is the one refusal a run carries on from; a launch that never
    /// shows a window ends it, with the seat still holding what it held. Once
    /// `use` is reached the previous application has been finished with, and a
    /// failure there leaves the seat empty on purpose: nothing is put back
    /// silently.
    ///
    /// `title` names the window to take instead of the application's main
    /// one, compared without case; a title that names no window of it, or
    /// several, refuses before anything is released. An application this call
    /// launched and could not hand to `use` is quit again before the refusal,
    /// and the refusal says so; one that was already running is left alone.
    @discardableResult
    public func open(applicationNamed name: String, windowTitled title: String? = nil) async throws -> TargetApp {
        guard isOpen else { throw SeatBrokerError.sessionClosed }
        let wanted = try ApplicationOpening.resolve(name, in: TargetEnumerator.targets())
        // Re-opening the held application would finish with it first, which
        // quits it when the agent opened it, and then adopt its dying window.
        guard !isUsingApp || wanted.pid != target?.pid else {
            throw SeatBrokerError.applicationNotResolved(
                "\(wanted.name) is the application this seat is already holding; "
                    + "act on the scene you were given instead of opening it again.")
        }
        let opened = try await environment.launch(wanted)
        let window: TargetWindow
        if let title {
            let named = opened.windows.filter { $0.title.caseInsensitiveCompare(title) == .orderedSame }
            guard named.count == 1, let only = named.first else {
                throw SeatBrokerError.driver("Expected one window of \(opened.name) named '\(title)'. Open: "
                    + opened.windows.map { $0.title.isEmpty ? "untitled" : $0.title }.joined(separator: ", ")
                    + ". " + unseated(opened, wasLaunched: wanted.pid == nil))
            }
            window = only
        } else {
            // The application's own window and not the first one listed: a sheet
            // is listed like any other window, and taking the first adopted one.
            guard let main = TargetEnumerator.mainWindow(among: TargetEnumerator.candidates(of: opened))
            else {
                throw SeatBrokerError.driver("\(opened.name) is open but has no window to adopt. "
                    + unseated(opened, wasLaunched: wanted.pid == nil))
            }
            window = main
        }
        do {
            try await use(window, of: opened)
        } catch {
            throw ApplicationOpening.notSeated(opened, cause: error)
        }
        return opened
    }

    /// Quits `app` when this open launched it, since no seat took a window of it, and says what
    /// became of it. An application found running is never quit here, whatever its provenance.
    private func unseated(_ app: TargetApp, wasLaunched: Bool) -> String {
        let wasQuit = wasLaunched && app.pid.map { ledger.quitUnseated($0) } == true
        return ApplicationOpening.unseated(app.name, wasLaunched: wasLaunched, wasQuit: wasQuit)
    }

    /// Records `pid` as the held application with the ledger's provenance, as `use` does before its
    /// adoption, but adopts nothing. Only for the controlled tests, which have no display to adopt on.
    func holdWithoutAdopting(_ pid: pid_t, name: String) {
        held = HeldApp(pid: pid, name: name, provenance: ledger.provenance(of: pid))
    }

    /// Finishes with the held application as its provenance says and keeps
    /// the seat and its display, so a session given back to the queue is
    /// parked warm for the next entry. The sentence is `finishWithHeldApp`'s.
    func finishUsingApp() async -> String? {
        guard isOpen else { return nil }
        return await finishWithHeldApp()
    }

    /// Gives the held window back and, when the agent opened the application
    /// itself, quits it. The sentence it returns names the one application that
    /// was left running against the rule, and nil says finishing was complete.
    ///
    /// The order is the safety rule and not a preference: the window goes home
    /// through the seat first, and the process is terminated only after that.
    /// Terminating the owner of a window the seat still holds leaves the seat's
    /// restitution ledger with an obligation it can never discharge, which
    /// `hasPendingWindowRestorations` reports and which blocks every later
    /// adoption. `driver.release` returning is not enough on its own: it
    /// answers with an outcome, and two of the four say the window is still on
    /// the background display, so `hasUnrestoredWindow` is what is read here.
    /// It is the only place that terminates an application a seat held; one
    /// that never reached a seat is quit by `LaunchLedger.quitUnseated`.
    ///
    /// Between the two comes the handback of the assigned application, which is
    /// the same rule one step out: the kit binds the assignment to the first
    /// instance it is handed, `release` of a window never ends it, and without
    /// this the next application's window is refused as
    /// `surfaceIsNotAMember`. It has to follow the release, because the kit
    /// refuses a handback while the seat still holds windows of the instance,
    /// and it has to precede the termination, because an assignment bound to a
    /// process nobody can quit is one nothing can end.
    private func finishWithHeldApp() async -> String? {
        guard let held else { return nil }
        self.held = nil
        await driver.release()
        let handback = driver.releaseAssignedApplication()
        let finish = Self.finishing(held.provenance.finish(windowRestored: !driver.hasUnrestoredWindow),
                                    handback: handback, app: held.name)
        if finish.quits {
            ledger.terminate(held.pid)
            ledger.forget(held.pid)
        }
        return finish.sentence
    }

    /// Whether the held application's process may be terminated now, and what
    /// finishing with it leaves the person to do.
    ///
    /// A refused handback stops the quit and is always reported. It stops the
    /// quit because the assignment is still bound to that instance and killing
    /// the process underneath a live assignment leaves the seat holding one
    /// nothing can end; it is reported because it means the next application
    /// cannot be adopted, and a person who is told nothing about it reads the
    /// run as the agent having simply stopped.
    static func finishing(_ outcome: FinishOutcome, handback: String?,
                          app: String) -> (quits: Bool, sentence: String?) {
        var sentences: [String] = []
        if let handback {
            sentences.append("The seat has not finished with \(app), so nothing else can be "
                + "adopted until that clears: \(handback)"
                + (outcome == .quit
                    ? " \(app) was left running for the same reason: quitting it while the seat "
                        + "still has it assigned is what would leave the seat unable to take "
                        + "anything else."
                    : ""))
        }
        if outcome == .cannotQuitYet {
            sentences.append("\(app) is still running: the seat could not confirm its window went "
                + "back to your display, and quitting it while the window is still out there is "
                + "what would leave the seat unable to take anything else. Quit it yourself once "
                + "the window is where you want it.")
        }
        return (quits: outcome == .quit && handback == nil,
                sentence: sentences.isEmpty ? nil : sentences.joined(separator: " "))
    }

    /// A `SeatTarget` over this session's seat, so the Engine's roles perceive and act on the
    /// window adopted here while this session stays its owner.
    ///
    /// The target borrows: it never starts or stops the display and never releases a window, so
    /// `use`, `open` and `close` stay this session's. It is valid until the next `use`, `open` or
    /// `close`: the driver revokes it before releasing or adopting anything, and a revoked target
    /// refuses as `notAdopted` instead of observing the next window. Observations are not shared: one taken
    /// by `observe` or `execute` supersedes the target's, and the reverse holds too, so each side
    /// observes again before acting. Throws `sessionClosed` or `noAdoptedApplication`.
    package func borrowedSeatTarget() throws -> SeatTarget {
        guard isOpen else { throw SeatBrokerError.sessionClosed }
        guard isUsingApp else { throw SeatBrokerError.noAdoptedApplication }
        return try driver.borrowedTarget()
    }

    /// The adopted window's frame on the background display, and the empty
    /// rectangle while nothing is adopted. It is not `target.frame`: the window
    /// server publishes a window Stage Manager stashed as a thumbnail, so the
    /// frame the enumerator listed is the wrong shape.
    public var windowFrame: CGRect { driver.windowFrame ?? target?.frame ?? .zero }

    /// A view that shows the adopted window live.
    public func makePreviewView(contentsScale: CGFloat) -> NSView {
        LivePreviewView(driver: driver, contentsScale: contentsScale)
    }

    /// True while the monitor shows the whole background display instead of
    /// the adopted window. The agent is unaffected: a decision is still taken
    /// on its own capture of the window, whatever the person is watching.
    public var previewShowsDisplay: Bool { driver.previewShowsDisplay }

    /// Switches the monitor between the whole background display and the
    /// adopted window, and answers which of the two it now shows, which is
    /// what was asked for unless there is no display yet to watch.
    public func setPreviewShowsDisplay(_ showsDisplay: Bool) -> Bool {
        driver.setPreviewShowsDisplay(showsDisplay)
    }

    /// Why the live picture is not live, and nil while it is or while nothing
    /// asked for one. Adoption and preview availability are separate states:
    /// the seat is holding the window in every case this sentence describes,
    /// and a failure of the preview alone is never a lost application.
    public var previewSuspension: String? { driver.previewSuspension }

    /// The latest observation when it is younger than `maxAge`, otherwise a
    /// fresh one. The planner uses it so the after-frame of an action doubles
    /// as the scene of the next decision instead of perceiving twice.
    public func observe(reusingWithin maxAge: Duration) async throws -> SceneObservation {
        if let last = lastObservation, Date.now.timeIntervalSince(last.capturedAt) < Double(maxAge.components.seconds)
            + Double(maxAge.components.attoseconds) / 1e18 {
            return last
        }
        return try await observe()
    }

    public func observe() async throws -> SceneObservation {
        guard isOpen else { throw SeatBrokerError.sessionClosed }
        guard isUsingApp, let app, let target else { throw SeatBrokerError.noAdoptedApplication }
        let captureStart = ContinuousClock.now
        let delivery = try await driver.observe()
        // DIAGNOSTICO, TEMPORANEO: la geometria del fotogramma che l'agente
        // percepisce davvero, una riga per osservazione. L'anteprima ritaglia
        // con contentsRect, questa immagine e' l'intero buffer: se il nero sta
        // dentro il rettangolo dichiarato pieno, non e' il ritaglio a doverlo
        // togliere. Via appena la banda nera ha un nome.
        let geometry = delivery.frame.geometry
        Self.diagnosticLog.info("""
            observed frame: pixel \(Int(geometry.pixelSize.width), privacy: .public)x\
            \(Int(geometry.pixelSize.height), privacy: .public) scale \(geometry.scaleFactor, privacy: .public), \
            content \(String(describing: geometry.contentRectInSurface), privacy: .public), \
            screen \(String(describing: geometry.screenRect), privacy: .public), \
            full window \(geometry.capturesFullWindow, privacy: .public), \
            uniform \(geometry.hasUniformWindowMapping, privacy: .public)
            """)
        guard let image = delivery.frame.makeCGImage() else {
            throw SeatBrokerError.frameUnavailable
        }
        var timing = PerceptionTiming()
        timing.capture = captureStart.duration(to: .now)
        // The frame the accessibility stage is judged against is the seat's own
        // window geometry, which the window server answered for: an accessibility
        // frame is trusted only where it intersects that rectangle, and after a
        // move an application's child frames still name the old place.
        let window = ScenePipeline.Window(
            bundleID : app.bundleID,
            appName  : app.name,
            title    : driver.windowTitle(for: delivery.reference.recipient),
            processID: target.pid,
            frame    : delivery.geometry.window.frame
        )
        let perceiveStart = ContinuousClock.now
        let scene = try await perception.perceive(image, of: window)
        timing.detection = perceiveStart.duration(to: .now)
        let observation = SceneMapper.observation(from: scene, image: image, timing: timing)
        lastDelivery = delivery
        lastScene = scene
        lastObservation = observation
        return observation
    }

    public func execute(_ action: SemanticAction) async throws -> ActionReport {
        guard isOpen else { throw SeatBrokerError.sessionClosed }
        guard isUsingApp else { throw SeatBrokerError.noAdoptedApplication }
        guard let before = lastObservation, let delivery = lastDelivery, let beforeScene = lastScene else {
            throw SeatBrokerError.noObservation
        }
        // A menu action is one scoped interaction and never a succession of
        // Commands, so it is routed rather than decomposed into inputs.
        let menuItem: String? = if case .menu(_, let item) = action { item } else { nil }
        let inputs = menuItem == nil
            ? try ActionExecutor.inputs(for: action, in: before, frame: delivery.frame.geometry)
            : []
        // The menu opens where an ordinary click would land, aimed before the
        // Turn like every other action: a stale index refuses having taken none.
        let menuOpening = try menuItem.map { _ in
            try ActionExecutor.location(ofElement: action.element ?? 0, in: before,
                                        frame: delivery.frame.geometry)
        }
        let targetElement = before.elements.first { $0.index == action.element }
        // An action with no element is named by its own verb, so the history
        // says which act it was and not only what it was aimed at.
        let targetLabel = targetElement?.label
            ?? (action.element == nil ? "\(action.verb) \(action.targetDescription)" : "?")
        // What would prove this action did what it is for, settled before it
        // goes out, from the action and from the surface it is aimed at.
        let surface = delivery.reference.role.attachedSheet ?? delivery.reference.recipient
        driver.notePublicSurface(surface)
        let oracle = ActOracle.of(action, target: targetElement, surface: surface)
        let started = ContinuousClock.now

        let turn = try await driver.acquireTurn()
        var receipts: [InputReceipt] = []
        // A menu interaction's Commands are the kit's own and it witnessed both
        // of them, so none is left here to confirm and receipts stays empty.
        var menu: SeatDriver.MenuChoice?
        let result: (after: SceneObservation?, verification: VerificationResult)
        do {
            if let menuItem, let menuOpening {
                menu = try await driver.chooseFromContextMenu(menuItem, openedAt: menuOpening,
                                                              observation: delivery.reference, turn: turn)
            }
            var reference = delivery.reference
            for (index, input) in inputs.enumerated() {
                receipts.append(try await driver.send(input, observation: reference, turn: turn))
                if index < inputs.index(before: inputs.endIndex) {
                    reference = try await driver.observe().reference
                }
            }

            // Let the target repaint before the after-frame is taken.
            try await Task.sleep(for: .milliseconds(450))
            let after = try await observe()
            guard let afterScene = lastScene else { throw SeatBrokerError.frameUnavailable }

            let verification = OutcomeVerifier.verify(before: beforeScene, beforeImage: before.image,
                                                      after: afterScene, afterImage: after.image,
                                                      targetID: targetElement?.identity,
                                                      oracle: oracle,
                                                      surfaceIsGone: driver.surfaceIsGone(surface))
            result = (after, verification)
        } catch {
            lastObservation = nil
            lastDelivery = nil
            lastScene = nil
            // Nothing went out, so this is the seat's refusal and not an
            // action: it never becomes a report of something executed.
            guard !receipts.isEmpty else {
                try? driver.endTurn(turn, receipts: [], confirmation: .absent)
                throw error
            }
            // It went out and nobody could take the reading that settles it.
            // The surface's own identity still answers, so a dismissal whose
            // after-frame was refused keeps its verified effect rather than
            // being lost and clicked again; anything else closes as unknown.
            let verification = OutcomeVerifier.interrupted(oracle: oracle,
                                                           surfaceIsGone: driver.surfaceIsGone(surface))
            try? driver.endTurn(
                turn,
                receipts: receipts,
                confirmation: verification.outcome == .expectedEffectVerified ? .observed : .unknown
            )
            // A cancelled run is still a cancelled run: the Turn above told
            // the kit what it needs, and the caller is owed its cancellation.
            if error is CancellationError { throw error }
            return ActionReport(action: action, targetLabel: targetLabel, before: before, after: nil,
                                verification: verification,
                                eventCount: receipts.reduce(0) { $0 + $1.eventCount },
                                duration: started.duration(to: .now),
                                note: SeatErrorMapper.message(for: error))
        }

        try driver.endTurn(
            turn,
            receipts: receipts,
            confirmation: Self.confirmation(of: result.verification.outcome)
        )
        return ActionReport(action: action, targetLabel: targetLabel,
                            before: before, after: result.after, verification: result.verification,
                            eventCount: menu?.eventCount ?? receipts.reduce(0) { $0 + $1.eventCount },
                            duration: started.duration(to: .now), note: menu?.note)
    }

    /// What the seat answers for one outcome when the Turn is closed.
    ///
    /// `absent` is the kit's "verified that nothing happened", which permits
    /// the Command to be sent again, so only an outcome that did look and find
    /// nothing may use it. A Command nobody could settle is `unknown`, which
    /// the kit never promotes and never replays.
    static func confirmation(of outcome: ActionOutcome) -> EffectConfirmation {
        switch outcome {
        case .expectedEffectVerified, .sceneChanged: .observed
        case .posted, .notObserved:                  .absent
        case .interruptedAfterPost:                  .unknown
        }
    }

    /// What the seat is doing, as the kit answers it. The lab shows this and
    /// never a state of its own: a badge built from local flags said "Seat
    /// ready" through a wait the seat was in for 107 seconds.
    public var seatActivity: SeatActivity { driver.activity }

    /// Why the seat is holding input back, and nil while it is not. It is the
    /// gate's own causes and never an inference from the activity above.
    public var inputHold: String? { driver.inputHold }

    /// Waits out a focus recovery that is still in flight, and answers whether
    /// input is admissible again, what the seat reads as at that moment, and
    /// the recovery's own timing as one sentence. The caller perceives and
    /// decides again; this waits and replays nothing.
    public func waitWhileRecoveringFocus(within limit: Duration)
        async -> (admitted: Bool, cause: SeatActivity, detail: String?) {
        await driver.waitWhileRecoveringFocus(within: limit)
    }

    /// Plans and executes a free-form goal with the selected model. Events
    /// arrive as the loop goes; the stream ends with `.finished` or an error.
    /// Terminating the stream cancels the run.
    public func run(goal: String, model selection: ModelSelection,
                    settings: ProviderSettings = ProviderSettings()) -> AsyncThrowingStream<AgentRunEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                let startedAt = Date.now
                var reports: [ActionReport] = []
                var decisions = 0
                var outcome = RunRecord.Outcome.failed
                var reason = ""
                var usage = RunUsage()
                do {
                    let transport = selection.transport(settings: settings)
                    try await AgentPlanner(session: self, provider: selection.provider,
                                           transport: transport).run(goal: goal) { event in
                        switch event {
                        case .thinking(let decision, _): decisions = decision
                        case .executed(let report): reports.append(report)
                        case .finished(let status, let finishReason, _, _):
                            outcome = status == .completed ? .completed : .blocked
                            reason = finishReason
                        case .planned(_, let modelUsage): usage.add(modelUsage)
                        // A measurement the person is shown and the record does
                        // not need: what it measured is already in the step.
                        case .notice: break
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    outcome = error is CancellationError ? .cancelled : .failed
                    reason = error.localizedDescription
                    continuation.finish(throwing: error)
                }
                record(goal: goal, selection: selection, startedAt: startedAt, outcome: outcome, reason: reason,
                       decisions: decisions, reports: reports, usage: usage)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Token and time totals over a run's model calls.
    private struct RunUsage {
        var input: Int?
        var output: Int?
        var seconds: Double = 0

        mutating func add(_ usage: ModelUsage?) {
            guard let usage else { return }
            if let tokens = usage.inputTokens { input = (input ?? 0) + tokens }
            if let tokens = usage.outputTokens { output = (output ?? 0) + tokens }
            seconds += Double(usage.duration.components.seconds) + Double(usage.duration.components.attoseconds) / 1e18
        }
    }

    private func record(goal: String, selection: ModelSelection, startedAt: Date, outcome: RunRecord.Outcome,
                        reason: String, decisions: Int, reports: [ActionReport], usage: RunUsage) {
        let id = UUID()
        let steps = reports.enumerated().map { index, report in
            RunStepRecord(index: index + 1, verb: report.action.verb, element: report.action.element ?? 0,
                          targetLabel: report.targetLabel, outcome: report.verification.outcome,
                          sceneChanged: report.verification.sceneChanged,
                          effect: report.verification.effect, pixelDifference: report.verification.pixelDifference,
                          eventCount: report.eventCount,
                          milliseconds: Int(report.duration.components.seconds * 1000
                                            + report.duration.components.attoseconds / 1_000_000_000_000_000),
                          count: report.action.clickCount)
        }
        let frame = lastObservation.flatMap { recorder.saveFrame($0.image, runID: id) }
        // What the seat itself did while the run went on, which the planner's
        // own last sentence says nothing about.
        let seatNotes = driver.takeNotes()
        let fullReason = seatNotes.isEmpty
            ? reason
            : reason + " The seat: " + seatNotes.joined(separator: "; ") + "."
        // A run that never got anything onto the seat is still worth recording:
        // its reason says why the open never happened.
        var record = RunRecord(id: id, startedAt: startedAt, finishedAt: .now,
                               app: app?.name ?? "no application", bundleID: app?.bundleID ?? "",
                               windowTitle: target?.title ?? "", goal: goal, provider: selection.provider,
                               model: selection.model, effort: selection.effort, outcome: outcome,
                               reason: fullReason,
                               decisions: decisions, steps: steps, finalFrameFile: frame)
        record.inputTokens = usage.input
        record.outputTokens = usage.output
        record.modelSeconds = usage.seconds > 0 ? usage.seconds : nil
        recorder.append(record)
    }

    /// Closes the seat's input gate at once, which is the first thing a panic
    /// owes the person: it stops the next Command without waiting for a run to
    /// unwind or for the display to come down. It returns no window, quits
    /// nothing and takes nothing down, and a Command already posting keeps its
    /// release. Nothing reopens the gate afterwards.
    public func stopAdmittingCommands() {
        driver.stopAdmittingCommands()
    }

    /// Finishes with the application the seat is holding and takes the
    /// background display down. The sentence it returns names an application
    /// that was left running because its window could not be confirmed back,
    /// or a window the teardown could not put back: the two cases where
    /// "everything went back to you" is not true.
    ///
    /// It tolerates being called while a run is still unwinding, which is what
    /// the panic control does. `isOpen` is dropped first, so whatever the run
    /// tries next is refused as a closed session rather than racing the
    /// teardown, and a second call answers nothing instead of tearing the same
    /// host down twice.
    @discardableResult
    public func close() async -> String? {
        guard isOpen else { return nil }
        isOpen = false
        // Before anything is given back or taken down: the gate is what stops
        // the next Command, and it costs nothing to close first.
        stopAdmittingCommands()
        let refusal = await finishWithHeldApp()
        let teardown = await driver.stop()
        let sentences = [refusal, teardown].compactMap { $0 }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }
}
