import Foundation

/// The observe → plan → execute → verify loop. Budgets follow the research
/// lab: a bounded number of decisions and actions, one driver failure ends
/// the run, and a plan's remaining steps are dropped as soon as a step
/// changes the scene, because their indices belonged to the old scene.
@MainActor
struct AgentPlanner {
    let session: AgentSession
    let client: any ModelClient
    var maximumDecisions = 10
    var maximumActions = 24
    var maximumStepsPerPlan = 4
    /// Applications the run may open in a row without acting on any of them.
    /// Two is one honest correction: open the wrong application, see its first
    /// scene, open the right one. A third in a row is a run shopping for an
    /// application instead of doing the goal, and it ends saying so.
    var maximumOpensWithoutActing = 2
    /// The deadline on waiting out a recovery that is actually in flight.
    ///
    /// It is a deadline and not a sleep. The wait ends the moment the seat's
    /// gate admits again or the kit publishes a terminal outcome, and a
    /// Command refused for anything but a recovery never enters it; two
    /// seconds is what the wait may cost when neither of those arrives.
    ///
    /// A recovery that has not verified inside the kit's 250 ms window is
    /// waited out rather than read as a refusal, so a focus that arrives late
    /// is caught instead of missed by milliseconds, and the kit's own
    /// `unrecoverable` is what ends that case rather than a guess here. Two is
    /// what one focus swap is worth against a person who may have walked away
    /// from the keyboard, and the retry rule on the catch below bounds the
    /// pessimistic case to two in a row: four seconds before the run ends
    /// saying so. The measured swap is milliseconds, so the ordinary path pays
    /// none of it.
    var focusRecoveryWait: Duration = .seconds(2)
    /// The provider knows how slow it is; a local thinking model gets minutes.
    var requestTimeout: TimeInterval { client.requestTimeout }

    func run(goal: String, emit: @MainActor (AgentRunEvent) -> Void) async throws {
        var history: [String] = []
        var decisions = 0
        var actions = 0
        var nudged = false
        // Consecutive Commands the seat would not admit. Looking again is the
        // right answer to one of them and an infinite loop as an answer to all
        // of them: a run that cannot place a single Command has to say so.
        var notAdmitted = 0
        // Consecutive readings the seat would not give while its situation was
        // moving. One is a race with the application's own windows and the next
        // reading answers it; three in a row is a situation that is not going to
        // settle, and the causes are the report.
        var notObserved = 0
        // Applications opened since the last action was executed.
        var opened = 0
        let schema = try PlanSchema.json(maximumSteps: maximumStepsPerPlan, flavor: client.schemaFlavor)
        // Read once: every decision's prompt carries it, and an open resolves
        // what is installed again at the moment it opens.
        let applications = ApplicationOpening.catalog(TargetEnumerator.targets())

        while decisions < maximumDecisions, actions < maximumActions {
            try Task.checkCancellation()
            // The after-frame of the last step is this decision's scene when it
            // is recent. Nothing adopted is not a failure to observe: the run
            // started from the chat with an empty seat, so there is no scene to
            // take and the prompt asks for the open that makes one.
            let observation: SceneObservation?
            if session.isUsingApp {
                do {
                    observation = try await session.observe(reusingWithin: .seconds(3))
                } catch let error as SeatBrokerError {
                    guard case .observationSuspended = error, notObserved < 2 else { throw error }
                    notObserved += 1
                    // Long enough to outlast the seat's own settling of a window an
                    // application closed while the window server still shows it,
                    // which is a whole second there. A quarter of a second gave up
                    // just before the reading that would have been answered.
                    try await Task.sleep(for: .milliseconds(1_200))
                    continue
                }
            } else {
                observation = nil
            }
            notObserved = 0
            decisions += 1
            emit(.thinking(decision: decisions, observation: observation))

            var decision = try await decide(goal: goal, observation: observation, history: history,
                                            actions: actions, applications: applications, schema: schema,
                                            nudge: nil, emit: emit)
            // A block before anything was tried, on a scene full of elements, is
            // almost always over-caution; one re-ask naming the rule fixes it.
            if decision.status == .blocked, actions == 0, !nudged, let observation, !observation.elements.isEmpty {
                nudged = true
                let nudge = "Your previous answer was status=\"blocked\" (\(decision.reason.prefix(300))). "
                    + "That is not accepted before any action was tried while the scene has \(observation.elements.count) elements: "
                    + "apply rule 4 and return exactly one navigation step toward the goal."
                decision = try await decide(goal: goal, observation: observation, history: history,
                                            actions: actions, applications: applications, schema: schema,
                                            nudge: nudge, emit: emit)
            }

            if decision.status == .open, let wanted = decision.application {
                guard opened < maximumOpensWithoutActing else {
                    emit(.finished(status: .blocked,
                                   reason: "\(opened) applications were opened in a row without acting on any of "
                                       + "them, and \(wanted) would be the next: the goal is not being worked on.",
                                   decisions: decisions, actions: actions))
                    return
                }
                do {
                    let application = try await session.open(applicationNamed: wanted)
                    opened += 1
                    // Said outright: the next scene is another window, and the
                    // indices of every line above it name nothing now.
                    history.append("decision \(decisions): opened \(application.name). Every element index "
                        + "from before this line belongs to a window that is no longer on the display.")
                } catch SeatBrokerError.applicationNotResolved(let sentence) {
                    // Nothing was opened and nothing was released, so the run
                    // carries on holding what it held, one decision poorer.
                    history.append("decision \(decisions): \(sentence)")
                }
                continue
            }

            // A key chord names no index, so validation lets it through even
            // with no scene behind it. On an empty seat that would be posted
            // into nothing, so it ends here and says which answer was owed.
            if observation == nil {
                emit(.finished(status: .blocked,
                               reason: "Nothing is on the seat, so the only answer that could be carried out was "
                                   + "an open naming an installed application. The model answered "
                                   + "\"\(decision.status.rawValue)\" instead: \(decision.reason)",
                               decisions: decisions, actions: actions))
                return
            }

            if decision.status != .plan || decision.steps.isEmpty {
                emit(.finished(status: decision.status, reason: decision.reason, decisions: decisions, actions: actions))
                return
            }

            for step in decision.steps.prefix(maximumActions - actions) {
                try Task.checkCancellation()
                let report: ActionReport
                do {
                    report = try await session.execute(step.action)
                } catch SeatBrokerError.inputPaused(let sentence) where notAdmitted < 2 {
                    // The target activated itself, which a dialog opening does,
                    // and the seat stopped input until the person's focus is
                    // back. Nothing was posted: a step whose Command did go out
                    // answers with an uncertain report and never through here.
                    notAdmitted += 1
                    let recovery = await session.waitWhileRecoveringFocus(within: focusRecoveryWait)
                    guard recovery.admitted else { throw SeatBrokerError.driver(sentence) }
                    // The swap the person watched, measured. Reported on the
                    // recovery that worked and not only on the one that did not.
                    if let detail = recovery.detail {
                        emit(.notice("Input was paused while your focus went back to you. " + detail))
                    }
                    history.append("step \(actions + 1): \(step.action.verb) was stopped before "
                        + "this command went out, input was paused while the focus went back to "
                        + "the person (the seat read \(recovery.cause.title.lowercased())). "
                        + "Look at the scene again before repeating it.")
                    break
                }
                notAdmitted = 0
                actions += 1
                opened = 0
                history.append(Self.historyLine(step: actions, report: report))
                emit(.executed(report))
                if !Self.continuesPlan(after: report.verification.outcome) { break }
            }
        }
        emit(.finished(status: .blocked, reason: "Budget exhausted: \(decisions) decisions, \(actions) actions.",
                       decisions: decisions, actions: actions))
    }

    /// Whether the rest of a plan may still be carried out after this outcome.
    ///
    /// ponytail: no rebinding of later steps onto a new scene; a changed scene
    /// invalidates their indices, so the run re-plans instead.
    ///
    /// `posted` is the one outcome the rest of a plan may stand on: the
    /// Command went out and the reading afterwards found the scene as it was,
    /// so the indices the model chose still name what it chose. Every other
    /// outcome either moved the scene or left nobody able to say what moved,
    /// and an uncertain effect is never carried forward. Nothing here repeats
    /// a step in any case: this decides whether to go on, never to retry.
    static func continuesPlan(after outcome: ActionOutcome) -> Bool { outcome == .posted }

    /// What one executed step leaves for the next decision to read.
    ///
    /// The note is appended rather than folded into the verification, because
    /// the two answer different questions: the verification says whether the
    /// window changed, and a contextual menu that refused a title changed
    /// nothing while still being the whole reason the step did nothing. A
    /// planner given only "scene unchanged" repeats the same step.
    static func historyLine(step: Int, report: ActionReport) -> String {
        let line = "step \(step): \(report.action.verb) \(report.action.targetDescription) "
            + "\(report.targetLabel) → \(report.verification.summary)"
        guard let note = report.note else { return line }
        return line + ". " + note
    }

    private func decide(goal: String, observation: SceneObservation?, history: [String], actions: Int,
                        applications: String, schema: Data, nudge: String?,
                        emit: @MainActor (AgentRunEvent) -> Void) async throws -> PlanDecision {
        let prompt = PlannerPrompt.build(goal: goal, app: session.app?.name, windowTitle: session.target?.title,
                                         observation: observation, history: history, applications: applications,
                                         maximumSteps: min(maximumStepsPerPlan, maximumActions - actions), nudge: nudge,
                                         compact: client.prefersCompactPrompt)
        let reply = try await client.plan(prompt: prompt, schema: schema, timeout: requestTimeout)
        do {
            let decision = try PlanSchema.decision(from: reply.plan, observation: observation)
            emit(.planned(decision, usage: reply.usage))
            return decision
        } catch let error as PlanValidationError where nudge == nil {
            // One re-ask quoting the rejection: small models fix a malformed
            // target when told exactly what was wrong.
            let correction = "Your previous answer was rejected: \(error.localizedDescription) "
                + "Every target must be \"<index>:click\", \"<index>:type\", \"<index>:scroll\" or \"key:<chord>\" such as \"key:return\" or \"key:cmd+c\", "
                + "using the [index] shown at the start of the element's line, never its label. "
                + "To work in another application, answer status=\"open\" with \"application\" set to one name from the installed list and \"steps\": []."
            return try await decide(goal: goal, observation: observation, history: history, actions: actions,
                                    applications: applications, schema: schema, nudge: correction, emit: emit)
        }
    }
}
