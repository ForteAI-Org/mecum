import ModelTransports
import SeatBroker
import AppKit
import Foundation
import Observation

/// Presentation state for the lab. It turns runtime results into chat
/// messages and never touches Seat or Perception modules directly.
@Observable
@MainActor
final class AppModel {
    // The lab runs on whatever macOS build is installed; the driver flags
    // unvalidated builds on every receipt and the capability card shows it.
    let broker = SeatBroker(configuration: .init(allowUnvalidatedBuild: true))

    var capabilities: CapabilityReport
    /// The seat. It exists from the first message on and holds nothing until a
    /// decision opens something, so nil means "no seat", never "no application".
    var session: AgentSession?
    /// The queue's lease on that seat. The seat is not this app's to keep: with
    /// more than one worker the next entry waits on this being given back, so it
    /// is held for exactly as long as `session` is and released with it.
    private var lease: SeatLease?
    var messages: [ChatMessage] = []
    var isBusy = false
    var draft = ""
    let settings: ModelSettingsStore
    /// Shown when a goal is typed and no provider is usable yet.
    var needsModel = false
    var selection: ModelSelection {
        get { settings.lastSelection }
        set { settings.lastSelection = newValue }
    }
    /// Shown as an alert over the chat when something the seat needed failed
    /// while a facility was not granted.
    var openError: String?
    var relaunchPending = false
    var showsHistory = false

    /// What the seat is doing, read from the kit and never assembled from what
    /// this model hoped its last call did. The badge used to say "Seat ready"
    /// on the strength of the permissions being granted, which it went on
    /// saying through a wait the seat was in for 107 seconds.
    private(set) var seatActivity: SeatActivity = .noSeat

    /// Why input is held back, as the gate itself names it, nil while it is
    /// not held.
    private(set) var inputHold: String?

    /// Why the live picture is not live. It is kept apart from the activity
    /// above because it is a different loss: the seat is holding the window
    /// through every sentence this one can carry, and no failure of the
    /// preview is a lost application.
    private(set) var previewSuspension: String?

    private var runTask: Task<Void, Never>?

    /// True while a close is in flight. The panic control is enabled during a
    /// run, so a second click arrives while the first close is still unwinding.
    private var isClosing = false

    /// True once `startDesktopSurface()` has run. Reopening the lab window
    /// must not start a second pair of watchers against the same broker.
    private var isWatchingDesktop = false

    /// Constructing this model asks for nothing.
    ///
    /// `capabilities()` reads the grants the process already has and raises no
    /// prompt, so the badge can report before anything is requested. The
    /// request itself and the two watchers start in `startDesktopSurface()`.
    init() {
        settings     = ModelSettingsStore()
        capabilities = broker.capabilities()
    }

    /// Asks for the desktop grants and starts watching them, once.
    ///
    /// This is the lab window's call, not the app's. The team is the front
    /// door and needs no Accessibility, Screen Recording or microphone to keep
    /// an identity or a draft, so a prompt at launch would be asking for a
    /// capability nobody enabled. Opening the lab is what enables it.
    ///
    /// The watchers are unstructured on purpose: they report for as long as
    /// the process runs, because a seat outlives the window that opened it.
    /// Closing and reopening the lab therefore does not restart them, and the
    /// guard is what keeps a second window from doubling the polling.
    func startDesktopSurface() {
        guard !isWatchingDesktop else { return }
        isWatchingDesktop = true
        broker.requestMissingPermissions()
        capabilities = broker.capabilities()
        Task { await watchPermissions() }
        Task { await watchSeat() }
    }

    /// Re-reads the seat's own state for as long as the app runs.
    ///
    /// A poll and not a subscription: the seat comes and goes with the
    /// session, the kit publishes its state per seat, and a badge that is
    /// half a second stale is still the kit's answer where the old one was
    /// never the seat's at all.
    /// ponytail: half a second, no subscription; if the badge ever has to
    /// follow a transition rather than report one, take the kit's own stream.
    private func watchSeat() async {
        while !Task.isCancelled {
            refreshSeatState()
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// One reading of the three the badge shows. Assigning only what changed
    /// keeps the toolbar from being invalidated twice a second forever.
    func refreshSeatState() {
        let activity = session?.seatActivity ?? .noSeat
        if activity != seatActivity { seatActivity = activity }
        let hold = session?.inputHold
        if hold != inputHold { inputHold = hold }
        let preview = session?.previewSuspension
        if preview != previewSuspension { previewSuspension = preview }
    }

    func requestPermissions() {
        broker.requestMissingPermissions()
        capabilities = broker.capabilities()
    }

    /// macOS shows each privacy prompt once, so a denied grant can only be
    /// given back in System Settings.
    func openPermissionSettings() {
        broker.openPermissionSettings()
    }

    /// The capability lines shown under a seat failure: a missing grant is the
    /// usual reason the seat cannot do something, and the error alone does not
    /// say which one.
    var capabilityLines: String {
        capabilities.entries
            .map { "\($0.ready ? "✓" : "✗") \($0.name): \($0.detail)" }
            .joined(separator: "\n")
    }

    /// Re-reads the capability report until every facility is ready. A Screen
    /// Recording grant only reaches a fresh process, so that one relaunches.
    private func watchPermissions() async {
        while !capabilities.allReady {
            try? await Task.sleep(for: .seconds(2))
            capabilities = broker.capabilities()
            if !relaunchPending, await broker.screenRecordingNeedsRelaunch() {
                relaunchPending = true
                try? await Task.sleep(for: .seconds(1))
                relaunch()
                return
            }
        }
    }

    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    /// Opens the app's Settings window (⌘,) from code.
    func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    /// Ends the seat: the held window goes back to the person, an application
    /// the agent opened is quit, and the background display comes down. The log
    /// stays, because it is the record of what was done; the next message makes
    /// a new seat.
    /// It is the panic control, so it runs while a run is in flight: the run is
    /// cancelled first and given a bounded moment to unwind, and then the seat
    /// is ended whether or not it did. The wait is bounded because a run that
    /// will not stop is the case the person pressed this for; the session
    /// tolerates the overlap, refusing whatever the run tries next as a closed
    /// session rather than racing the teardown.
    ///
    /// A second click while that is going is nothing: the seat is already on
    /// its way back, `session` stays non-nil until the close returns, and the
    /// second call would otherwise cancel again, close a session that is
    /// already closed and post the closing line before the first close has
    /// finished saying it.
    func closeSession() async {
        guard let session, !isClosing else { return }
        isClosing = true
        defer { isClosing = false }
        isBusy = true
        // The gate first, then the cancellation and the bounded wait: the seat
        // used to keep admitting Commands for the whole of that wait.
        session.stopAdmittingCommands()
        // The badge reads suspended from this instant and not from whenever
        // the poll next comes round: the gate is already shut.
        refreshSeatState()
        cancelRun()
        let deadline = ContinuousClock.now + .seconds(2)
        while runTask != nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let refusal = await session.close()
        self.session = nil
        // The queue takes the seat back here and lets the next entry in. A
        // closed session is not parked, so the next one gets a fresh seat.
        lease?.giveBack()
        lease = nil
        isBusy = false
        // Only the sentence that is true: an application left running is the
        // one case where the usual line claims something that did not happen.
        post(.system, refusal.map { $0 + " The next message opens a new seat." }
            ?? "Seat ended. Anything it was holding went back to you. The next message opens a new one.")
    }

    /// Raises the permissions alert when a failure arrives while a facility is
    /// not granted. The sentence alone never names the missing grant, and this
    /// alert is the only place the person can ask for it at that moment; a
    /// failure with every facility ready stays in the log where it belongs.
    private func escalate(_ error: any Error) {
        // A seat holding nothing is not a missing grant: it says so itself and
        // there is no permission to ask for.
        if let refusal = error as? SeatBrokerError, case .noAdoptedApplication = refusal { return }
        capabilities = broker.capabilities()
        guard !capabilities.allReady else { return }
        openError = error.localizedDescription
    }

    /// `/observe`, `/click N [count]`, `/type N text`, `/scroll N k`, `/menu N title`,
    /// `/caps`; anything else is a free-form goal for the
    /// planner. The slash vocabulary is written three times and the three have
    /// to agree: `SemanticAction.parse`, the help line below, and the field
    /// placeholder in `ChatView`.
    ///
    /// `/menu N title` opens the element's own contextual menu and chooses the
    /// item by title. It is the route a copy or a paste is
    /// reached through, since a key equivalent is resolved by the frontmost
    /// application's menu and the seat never becomes frontmost. A file cannot be
    /// pasted by any route: measured on 18/09/2026, the item is chosen and
    /// nothing attaches, with the target frontmost as well as in the background.
    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        draft = ""
        post(.user, text)

        // The one command that answers before anything exists, and the explicit
        // rescan that the grid's Refresh button used to be.
        if text == "/caps" {
            capabilities = broker.capabilities()
            post(.system, capabilityLines)
            return
        }
        let isCommand = text.hasPrefix("/")
        // Nothing is checked before something asks, so a goal typed first
        // waits for the checks rather than being refused for want of them.
        if !isCommand, settings.availableProviders.isEmpty { await settings.refreshAndWait() }
        guard isCommand || !settings.availableProviders.isEmpty else {
            needsModel = true
            post(.system, "No usable model is configured, so there is nothing to plan the goal with.")
            return
        }

        isBusy = true
        defer { isBusy = false }
        do {
            // The seat is asked of the queue and waited for, never made here:
            // with one seat a second worker's message blocks at this line until
            // the first gives its seat back. It outlives every application that
            // passes through it and holds nothing until a decision opens
            // something.
            let session: AgentSession
            if let existing = self.session {
                session = existing
            } else {
                let lease = try await broker.queue.acquire("Mecum")
                self.lease = lease
                self.session = lease.session
                session = lease.session
            }
            if text == "/observe" {
                let observation = try await session.observe()
                messages.append(ChatMessage(role: .system, text: observation.text, observation: observation))
            } else if let action = SemanticAction.parse(command: text) {
                let report = try await session.execute(action)
                // The note carries what an action could not do in its own
                // words, and a contextual menu that offered other titles says
                // so there and nowhere else. It went to the model's history and
                // not to the person, who is the one holding the keyboard.
                let note = report.note.map { " — \($0)" } ?? ""
                messages.append(ChatMessage(role: .system,
                                            text: "\(action.verb) \(action.targetDescription) \(report.targetLabel): \(report.verification.summary)\(note)",
                                            report: report))
            } else if isCommand {
                post(.system, "Unknown command. Use /observe, /click N [count], /type N text, /scroll N k, /key return|escape|tab|cmd+c…, /menu N title, /caps.")
            } else {
                await run(goal: text, in: session)
            }
        } catch {
            post(.system, "Failed: \(error.localizedDescription)")
            escalate(error)
        }
    }

    func cancelRun() {
        runTask?.cancel()
    }

    /// One planner run as one message that fills in: status line while the
    /// model thinks, the live stream while it acts, then the final frame and
    /// the list of verified actions as the correctness debug trail.
    private func run(goal: String, in session: AgentSession) async {
        messages.append(ChatMessage(role: .system, text: "", isRunning: true, runStatus: "Thinking…"))
        let index = messages.count - 1
        let selection = self.selection
        let providerSettings = settings.providerSettings
        let task = Task { @MainActor in
            do {
                for try await event in session.run(goal: goal, model: selection, settings: providerSettings) {
                    refreshSeatState()
                    switch event {
                    case .thinking(let decision, let observation):
                        // No observation is the empty seat: nothing has been
                        // opened, so say that rather than "perceived 0 elements".
                        var status = observation == nil
                            ? "Nothing is open yet — choosing an application (\(selection.model) · \(selection.effort.title(for: selection.provider)))"
                            : "Thinking… (decision \(decision), \(selection.model) · \(selection.effort.title(for: selection.provider)))"
                        if let observation, let timing = observation.timing {
                            status += "\nPerceived \(observation.elements.count) elements in \(timing.summary)"
                        }
                        messages[index].runStatus = status
                    case .planned(let decision, let usage):
                        // The open is the one decision with nothing to watch
                        // while it runs: the display comes up and the
                        // application launches with no frame to show yet.
                        var status = switch decision.status {
                        case .plan: "Executing \(decision.steps.count) step\(decision.steps.count == 1 ? "" : "s"): \(decision.reason)"
                        case .open: "Opening \(decision.application ?? "an application")… \(decision.reason)"
                        default: decision.reason
                        }
                        if let usage {
                            var parts: [String] = []
                            if let tps = usage.tokensPerSecond { parts.append("\(Int(tps.rounded())) tok/s") }
                            if let out = usage.outputTokens { parts.append("\(out) out") }
                            parts.append(usage.duration.formatted(.units(allowed: [.seconds], width: .narrow)))
                            status += "  ·  " + parts.joined(separator: " · ")
                        }
                        messages[index].runStatus = status
                    case .executed(let report):
                        messages[index].reports.append(report)
                    case .notice(let text):
                        // Its own line and not the run's status, which the next
                        // decision overwrites: a measurement has to stay.
                        post(.system, text)
                    case .finished(let status, let reason, let decisions, let actions):
                        messages[index].text = "\(status.rawValue.capitalized) — \(reason)"
                        messages[index].runStatus = "\(decisions) decision\(decisions == 1 ? "" : "s"), \(actions) action\(actions == 1 ? "" : "s")"
                    }
                }
            } catch is CancellationError {
                messages[index].text = "Cancelled."
            } catch {
                messages[index].text = "Run failed: \(error.localizedDescription)"
                escalate(error)
            }
            messages[index].finalObservation = session.lastObservation
            messages[index].isRunning = false
        }
        runTask = task
        await task.value
        runTask = nil
    }

    private func post(_ role: ChatMessage.Role, _ text: String) {
        messages.append(ChatMessage(role: role, text: text))
    }
}
