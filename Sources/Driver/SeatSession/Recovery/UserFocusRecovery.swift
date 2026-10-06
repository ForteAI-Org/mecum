import Foundation
import Dispatch
import CoreGraphics
import os
import SeatCore
import SeatInput

/// One attempt per episode, directed only at the last observed user window. An
/// episode is one Turn, or one complete delivery or containment operation
/// outside a Turn, and a window an application raises between Turns is that
/// second kind. A failed or repeated activation leaves input paused until the
/// user returns.
/// All callbacks and state live on the main actor, including timer teardown.
final class UserFocusRecovery {

    static let log = Logger(subsystem: "dev.forte.AgentSeatKit", category: "FocusRecovery")

    /// What the last preparation attempt concluded, so the line is written when
    /// the answer changes instead of once per heartbeat. Empty until the first
    /// attempt, so both the first arming and the first refusal are written.
    ///
    /// A restoration that was never armed is invisible from outside. The seat
    /// reports `targetActivated`, waits, and the person reads it as the seat
    /// having stopped; nothing anywhere says the recovery had nothing in hand,
    /// which is the one fact a live diagnosis of that stop needs. Armed is
    /// logged as well as refused, because a silence that means "all is well" and
    /// a silence that means "nobody looked" are the same silence.
    private var lastPreparationOutcome = ""

    private let sensing: any SeatSensing
    private let gate: InputCommandGate
    private let adopted: () -> [WindowReference]
    private let restore: (WindowReference) throws -> Int32
    private let restoreForBriefActivation: (WindowReference) throws -> Int32
    private let changed: (UserFocusRecoveryReport) -> Void
    private let now: () -> UInt64
    private let requestTiming: () -> UserFocusRequestTiming
    private let prepareDestination: (WindowReference, [WindowReference]) throws -> Void
    private let renewDestination: (WindowReference) throws -> Void
    private let isFrontmost: (Int32) -> Bool
    private var requestRefusal: String?
    private var timing = UserFocusRecoveryTiming()

    /// preparationLifetimeNanoseconds is 1.25 s and is `SeatCore`'s value, not a
    /// second literal: two constants that have to agree are drift waiting to
    /// happen, and these two mean the same preparation. The age starts before
    /// the AX and WindowServer reads, so a slow preparation cannot renew itself,
    /// and 1.25 s still covers the 800 ms delayed menu activation observation.
    static let preparationLifetimeNanoseconds = AssignmentFocusCoordinator.preparationLifetimeNanoseconds

    /// The verification budget of one activation: two agreeing readings are
    /// expected within 250 ms, and past it the timer drops to its 100 ms cadence
    /// and the episode is waiting for the person. It is named rather than
    /// written twice because `isRestoring` and that cadence drop have to mean
    /// the same instant.
    static let verificationWindowNanoseconds: UInt64 = 250_000_000

    /// What one closure transition is allowed to spend, and the whole of it: the
    /// preparation its reconciliation may renew once, plus the verification
    /// window of the last request it may make. It is those two and not a third
    /// number, because a transition that has outlived both has nothing left to
    /// spend. The alternative to a deadline here is a seat fighting the
    /// application, or the person, for as long as either keeps going. Like every
    /// budget in ADR 0010 it is a requirement to be qualified, not a measurement.
    static let closureTransitionNanoseconds =
        preparationLifetimeNanoseconds + verificationWindowNanoseconds

    /// How many automatic requests one closure transition may make, where every
    /// other episode has one. A measured closure gave the focus back in 17 ms
    /// and the application took it again 32 ms later; that second steal is a
    /// distinct activation, and the episode had nothing left to answer it with.
    /// Two is a proposal to be qualified and not a licence: a third is refused,
    /// and each of the two still needs evidence that is valid again.
    static let closureRequestBudget = 2

    /// The protection a closure transition keeps after the dialog's
    /// accessibility surface disappears. An Electron panel's completion is
    /// deferred, so the focus can come back for an instant and be taken again:
    /// two agreeing readings inside this window end nothing, and the episode
    /// closes only when they still agree at the end of it. It is the same 250 ms
    /// as the verification window because it is the same question asked of the
    /// same two readings, and it is to be qualified live.
    static let closureProtectionNanoseconds = verificationWindowNanoseconds

    private var preparationGeneration: UInt64 = 0
    private var prepared: PreparedAction?
    private struct PreparedAction {
        let snapshot: FocusRecoverySnapshot
        let destination: WindowReference
        let targets: [WindowReference]
        let started: UInt64
        let duration: UInt64
        let identityDuration: UInt64
    }

    /// The evidence of one dialog closure, taken **before** the Command that
    /// closes it and never learned again afterwards.
    ///
    /// The steal happens between the post and the next thing anybody can read,
    /// so a destination discovered after it is the driven application's own
    /// activation dressed as the person's choice. This holds what was observed
    /// while the person still had the focus: their window and its attested
    /// identity, the surfaces the seat holds, the helper processes that may
    /// legitimately cause the steal, the preparation generation it belongs to,
    /// and one monotonic deadline for the whole thing.
    private struct ClosureTransition {

        /// The person's window as it was observed before the Command. The
        /// reconciliation checks that this is still the same window; it never
        /// replaces it, and it never learns another one from whatever is active.
        let destination: WindowReference

        /// The surfaces the seat had attested when the transition opened: the
        /// host, and the helper surfaces descending from the seat's own
        /// relation. A service's other windows are not in it.
        let attestedSurfaces: [WindowReference]

        /// Who may cause the steal. A remote service's process is here because
        /// its activation is the application's and not the person's; nothing
        /// here is adopted, attributed or given input by being in this set.
        let stealActors: Set<Int32>

        /// The modal surface the Command is expected to close, when the
        /// observation named one.
        let dialog: WindowIdentity?
        let openedAt: UInt64
        let deadline: UInt64
        let generation: UInt64

        /// Whether the Command went out. It is kept apart from the dialog's
        /// effect and from the focus recovery on purpose: a Cancel that posted
        /// stays posted while the recovery is still running, and nothing here
        /// posts it again.
        var posted = false

        /// When the dialog stopped being listed by accessibility.
        var surfaceGoneAt: UInt64?
        var reconciliations = 0
        var deadlineReported = false
    }
    private var closure: ClosureTransition?
    private var expectedClosure: (dialog: WindowIdentity?, helpers: [WindowReference])?
    private var reconcileInFlight = false

    /// The activation the seat is causing itself, and the uptime past which it
    /// explains nothing any more. See `expectActivation(of:until:)`.
    private var expectedActivation: (processID: Int32, deadline: UInt64)?

    /// How often a brief activation reads its caller's condition while the
    /// target is in front.
    static let briefActivationPollNanoseconds: UInt64 = 20_000_000

    /// The longest a brief activation holds the front, whatever its caller
    /// asks: the bound ADR 0013 accepted. One run measured on 30/09/2026 put
    /// Photoshop's menus disabled at 5 ms, unreadable from 61 to 961 ms and
    /// enabled at 1050 ms, so two seconds is that run with room, not a budget
    /// qualified over many.
    static let briefActivationLimitNanoseconds: UInt64 = 2_000_000_000

    /// Bounds verification after a brief activation's native handback. The
    /// consumer's activation can settle past ordinary recovery's 250 ms window;
    /// an app repetition needed 1010.4 ms for its second reading. Two timely
    /// identity matches remain required. See ADR 0023.
    static let briefHandbackLimitNanoseconds: UInt64 = 2_000_000_000

    /// Whether a request was already made for the activation being answered
    /// now. A verification that did not agree is not a reason to ask again, so
    /// the reconciliation arms only an activation that asked for nothing.
    private var requestedThisActivation = false
    private var destinationPreparation: UInt64 = 0
    private var destination: WindowReference?
    private var candidate: WindowReference?
    private var started: UInt64 = 0
    private var activatingPID: Int32 = 0
    private var code: Int32?
    private var frontmostRestored: UInt64?

    /// How many times a preparation was built or tried in this episode, and how
    /// many times the restorer was actually invoked. They are two facts and they
    /// used to be one flag, which was raised before the request path knew
    /// whether a request could start at all: a stale preparation or a stale
    /// inventory then consumed the episode's whole budget without restoring
    /// anything. A request is counted where it is made, and a failure whose
    /// effect is uncertain counts as made, because nothing here can prove the
    /// focus did not move.
    private(set) var preparationAttempts = 0
    private(set) var restoreRequests = 0
    private var holdIsArmed = false
    private var operationIsArmed = false

    /// Whether a transfer joined the open operation, whose end then ends it,
    /// and when an operation no transfer joined had its restoration verified.
    /// See `openOperationOnActivation(at:)`.
    private var operationHasTransfer = false
    private var operationRestoredAt: UInt64?
    private var timer: Timer?
    private var userSelectedDestination = false
    private var isRefreshing = false

    /// A destination reading the refresh still owes. The person's focused
    /// window changes only when the person changes it, and the two
    /// notifications that say so, `activationChanged` and `userWindowChanged`,
    /// are the only things that raise this. The beat re-derives the destination
    /// on one of them or while it holds none, and on nothing else: that
    /// derivation is two accessibility round trips into the person's own
    /// application, and it was paying them once a second for an answer that had
    /// not moved. It starts raised because no notification has arrived yet.
    private var userWindowNeedsReading = true
    private(set) var isPaused = false

    init(sensing: any SeatSensing, gate: InputCommandGate,
         adopted: @escaping () -> [WindowReference],
         restore: @escaping (WindowReference) throws -> Int32,
         restoreForBriefActivation: ((WindowReference) throws -> Int32)? = nil,
         now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         requestTiming: @escaping () -> UserFocusRequestTiming = { UserFocusRequestTiming() },
         prepareDestination: @escaping (WindowReference, [WindowReference]) throws -> Void = { _, _ in },
         renewDestination: @escaping (WindowReference) throws -> Void = { _ in },
         isFrontmost: ((Int32) -> Bool)? = nil,
         changed: @escaping (UserFocusRecoveryReport) -> Void) {
        self.sensing = sensing
        self.gate = gate
        self.adopted = adopted
        self.restore = restore
        self.restoreForBriefActivation = restoreForBriefActivation ?? restore
        self.now = now
        self.requestTiming = requestTiming
        self.prepareDestination = prepareDestination
        self.renewDestination = renewDestination
        self.isFrontmost = isFrontmost ?? { sensing.frontmostProcessID == $0 }
        self.changed = changed
    }

    /// True while an episode is open, whichever opened it. An episode is one
    /// Turn, or one complete delivery or containment operation outside a Turn:
    /// a transfer that runs inside a Turn is that Turn's and opens no second
    /// budget, which is why this is an or and not a count.
    private var allowed: Bool { holdIsArmed || operationIsArmed || closure != nil }

    /// How many automatic requests this episode may make. A closure transition
    /// is the only one with two, and it keeps its count across the verified
    /// return in the middle of it, which is what stops the two from becoming
    /// a request per activation for as long as the transition lasts.
    private var requestBudget: Int { closure == nil ? 1 : Self.closureRequestBudget }

    /// A transition whose deadline has passed is out of time, and out of time
    /// is out of requests. Without this a later activation would start the
    /// fight the deadline exists to end.
    private var closureDeadlinePassed: Bool {
        closure.map { now() >= $0.deadline } == true
    }
    private var requestsSpent: Bool { restoreRequests >= requestBudget || closureDeadlinePassed }

    /// Whether a closure transition is open, and whether its Command went out.
    /// Two facts on purpose: the post is not the closure's effect and neither
    /// of them is the focus recovery that followed.
    var isInClosureTransition: Bool { closure != nil }
    var closureCommandWasPosted: Bool { closure?.posted == true }

    /// Whether the surface this transition is about has been seen to go. It is
    /// the verified half of the closure, kept apart from the post above for the
    /// same reason: the Command going out is not the dialog being gone.
    var closureSurfaceIsGone: Bool { closure?.surfaceGoneAt != nil }

    /// The surfaces as they were attested **before** the Command, which is the
    /// only frame of theirs anybody still has once the closure has happened.
    /// Empty outside a transition. It is read for measuring geometry across the
    /// closure; nothing is adopted, attributed or driven by being in it.
    var closureSurfacesBefore: [WindowReference] { closure?.attestedSurfaces ?? [] }

    /// How long the episode must still keep going after the dialog's
    /// accessibility surface disappeared, nil when no such disappearance is
    /// recorded and zero when the protection is over.
    private var closureProtectionRemaining: UInt64? {
        guard let goneAt = closure?.surfaceGoneAt else { return nil }
        let elapsed = now() &- goneAt
        return elapsed < Self.closureProtectionNanoseconds
            ? Self.closureProtectionNanoseconds &- elapsed
            : 0
    }

    /// isRestoring is the narrow half of `isPaused`: the request went out, came
    /// back with code 0, and the two agreeing readings are still owed inside the
    /// 250 ms window. Something is genuinely in flight, so nothing else in the
    /// seat may read or move windows underneath it.
    ///
    /// Every other paused state is the seat waiting for a person who may not be
    /// at the keyboard: a miss that asked for nothing, a refused request, or a
    /// request the 250 ms did not verify. Those end only when the person acts,
    /// so whatever stands down on them stands down for as long as they are away.
    /// It is derived and not stored because a second flag set beside `isPaused`
    /// is one more place for the two to disagree, which is the defect this
    /// answers. The gate never reads this: input admission stays on `isPaused`.
    var isRestoring: Bool {
        isPaused && code == 0 && now() &- started < Self.verificationWindowNanoseconds
    }

    func beginHold() {
        guard !isPaused else { return }
        holdIsArmed = true
        openEpisode()
    }

    func endHold() {
        holdIsArmed = false
        invalidatePreparation()
    }

    /// Opens the episode of one operation outside a Turn: a whole delivery or
    /// containment, never one window and never one notification.
    ///
    /// Without it an application the seat drives can raise a dialog between
    /// Turns, take the person's focus with it, and meet a recovery armed
    /// nowhere: no request, no pause and no reported miss. A Turn already holds
    /// an episode, so a transfer inside one finds this closed to it.
    func beginOperation() {
        if !isPaused, !allowed {
            operationIsArmed = true
            openEpisode()
        }
        // A transfer that finds the operation open joins it: its end is the end.
        if operationIsArmed {
            operationHasTransfer = true
            operationRestoredAt  = nil
        }
    }

    /// Opens the operation an activation outside a Turn is the first signal of,
    /// after ending an earlier one that is over although nothing ended it.
    ///
    /// Measured on 30/09/2026 with Photoshop: an activation opened an operation
    /// for the Save panel it announced, the restoration was verified, and the
    /// panel was cancelled before the seat detected it. No transfer began, so
    /// no `endOperation` came, and eight seconds later the activation of the
    /// next panel found the one request spent and left the seat waiting. So an
    /// operation no transfer joined ends once its restoration has been verified
    /// for a preparation's lifetime, the horizon past which nothing prepared
    /// before it is evidence either. Before that, or with a transfer joined, a
    /// second activation is the same operation and its one request stays spent.
    private func openOperationOnActivation(at detected: UInt64) {
        if operationIsArmed, !operationHasTransfer, !holdIsArmed, closure == nil,
           let restoredAt = operationRestoredAt,
           detected &- restoredAt > Self.preparationLifetimeNanoseconds {
            note("the operation restored \(Self.milliseconds(detected &- restoredAt)) ago "
                + "was never joined by a transfer: it is over")
            operationIsArmed    = false
            operationRestoredAt = nil
        }
        guard !isPaused, !allowed else { return }
        operationIsArmed     = true
        operationHasTransfer = false
        openEpisode()
    }

    /// Ends it without opening another: the next automatic attempt needs a new
    /// operation or a Turn.
    ///
    /// A Turn acquired while the operation was running owns what is prepared
    /// now, and dropping that would disarm the very activation the Turn is
    /// about to need, so the preparation goes only when no hold is left.
    func endOperation() {
        guard operationIsArmed else { return }
        operationIsArmed     = false
        operationHasTransfer = false
        operationRestoredAt  = nil
        guard !holdIsArmed else { return }
        invalidatePreparation()
    }

    /// The arming both kinds of episode share, so the budget, the destination
    /// and the evidence cannot come to mean two different things.
    ///
    /// It supersedes what is in flight and keeps what is in hand, which is the
    /// difference between a named miss and a request for the popup an
    /// application raises by itself. That popup activates its application
    /// before anything else happens, so the activation that opens this episode
    /// is also the moment the evidence is needed; discarding it right here left
    /// every such activation with nothing to be armed by. What keeps the kept
    /// evidence honest is unchanged: the destination check `rememberUserWindow`
    /// makes just below, which still drops a preparation whose user window is
    /// no longer the current one, the preparation lifetime, and every fact
    /// re-read at the activation.
    private func openEpisode() {
        supersedePreparation()
        preparationAttempts = 0
        restoreRequests = 0
        let destinationStart = now()
        rememberUserWindow()
        destinationPreparation = now() &- destinationStart
    }

    /// Declares that the Command the seat is about to post is expected to close
    /// this modal surface, so the transition opens on the preparation built for
    /// that Command.
    ///
    /// The declaration and the opening are two steps because the evidence is
    /// built between them: the driver awaits `prepareBeforeAction` immediately
    /// before the post, and that is the last reading taken while the person
    /// still has the focus. Opening earlier would carry older evidence and
    /// opening later would be after the steal, where a destination is the
    /// driven application's own activation dressed as the person's choice.
    ///
    /// `helpers` are surfaces the seat has already attested as descending from
    /// its own relation, and they are here for one reason: their process can
    /// cause the steal, so its serial number is retained beside the targets' and
    /// the activation it sends is read as the application's rather than the
    /// person's. Nothing is adopted, attributed or given input by being passed
    /// here, and a service's other windows are not the seat's to pass.
    func expectClosure(dialog: WindowIdentity?, helpers: [WindowReference] = []) {
        guard !isPaused, closure == nil else { return }
        expectedClosure = (dialog, helpers)
    }

    /// Drops an expectation whose Command never reached its preparation. An
    /// expectation left standing would open a transition for the next Command,
    /// which is a different Command about a different surface.
    func dropClosureExpectation() { expectedClosure = nil }

    /// Opens the transition on the evidence just built, and answers whether it
    /// opened. Without a preparation there is nothing to open one on: the
    /// destination, the attested identity and the snapshot are exactly what the
    /// transition carries across the steal.
    @discardableResult
    private func openExpectedClosure() -> Bool {
        guard let expected = expectedClosure, closure == nil,
              !isPaused, let action = prepared else { return false }
        let surfaces = action.targets + expected.helpers
        if !expected.helpers.isEmpty {
            // Retains the helper serial numbers beside the destination's, on
            // the same read-only path the targets already use.
            do { try prepareDestination(action.destination, surfaces) }
            catch {
                note("the closure transition could not retain its helpers: \(String(describing: error))")
                return false
            }
        }
        expectedClosure = nil
        let opened = now()
        closure = ClosureTransition(
            destination     : action.destination,
            attestedSurfaces: surfaces,
            stealActors     : Set(surfaces.map(\.processID)),
            dialog          : expected.dialog,
            openedAt        : opened,
            deadline        : opened &+ Self.closureTransitionNanoseconds,
            generation      : preparationGeneration
        )
        preparationAttempts = 0
        restoreRequests = 0
        note("a closure transition is open, back to window \(action.destination.windowNumber)")
        return true
    }

    /// The Command went out. The post is a fact of its own and stays true
    /// whatever the recovery does next; nothing here repeats it.
    func noteClosureCommandPosted() { closure?.posted = true }

    /// The dialog stopped being listed by accessibility. It starts the short
    /// protection, and only for the surface the transition is about.
    func noteClosureSurfaceGone(_ windowNumber: Int) {
        guard var transition = closure, transition.surfaceGoneAt == nil,
              transition.dialog == nil || transition.dialog?.windowNumber == windowNumber
        else { return }
        transition.surfaceGoneAt = now()
        closure = transition
    }

    /// Ends the transition without opening another. The teardown and the
    /// deliberate stop use it; the ordinary end is the verified return.
    func endClosureTransition() {
        expectedClosure = nil
        guard closure != nil else { return }
        closure = nil
        guard !holdIsArmed, !operationIsArmed else { return }
        invalidatePreparation()
    }

    /// Declares that the seat is about to bring `processID` in front on
    /// purpose, so its activation before `deadline`, on this recovery's clock,
    /// is not read as the person's focus being taken: the gate stays open,
    /// nothing is reported, no episode opens, no request is made and no budget
    /// is spent. The destination stays the person's window observed before it.
    ///
    /// Only that process is expected. The person switching to an application
    /// of their own meanwhile keeps its ordinary meaning and becomes the
    /// destination. Once the expectation ends or its deadline passes, an
    /// activation of that process is answered exactly as it always was.
    /// ADR 0013 records the one reason it exists.
    func expectActivation(of processID: Int32, until deadline: UInt64) {
        expectedActivation = (processID, deadline)
    }

    func endExpectedActivation() { expectedActivation = nil }

    private var isExpectingActivation: Bool {
        expectedActivation.map { now() < $0.deadline } == true
    }

    private func isExpected(_ processID: Int32) -> Bool {
        isExpectingActivation && expectedActivation?.processID == processID
    }

    /// Brings `target` in front through the restorer the recovery gives the
    /// focus back with, reads `isReady` every 20 ms while it is there, and
    /// gives the front back to the person's window, all under an expectation
    /// of its own activation. The summary is one log line's worth of what
    /// happened, with its timings.
    ///
    /// It refuses before any request when the recovery is paused, when no
    /// window of the person's own is in front, or when the target's identity
    /// cannot be resolved. The target is a window the seat holds, never the
    /// application's focused window, which lags behind in the application this
    /// exists for. The front goes back only while the target still holds it: a
    /// person who took it meanwhile keeps it, and the poll stops there too.
    ///
    /// The handback is verified by two agreeing readings inside the one-second
    /// verification window. A target that still holds the front after it is
    /// handed to the ordinary path as an activation of the target, so the seat
    /// pauses and waits for the person as it does for any other; the handback
    /// was that episode's request, so the recovery asks nothing more. The
    /// restorer holds one participant and the target spends it, so what was
    /// prepared for the person is dropped first and rebuilt at the end.
    ///
    /// `bound` is capped at two seconds. `isReady` runs on the main actor
    /// between two sleeps and holds the actor while it reads, so it has to
    /// answer quickly. A cancelled caller stops the poll and still hands back.
    /// `performOnce` is the package's admitted Adobe menu scope (ADR 0024),
    /// separate from readiness. It runs at most once before handback, only
    /// while the exact adopted identity and both foreground witnesses agree.
    /// Its effect survives an unverified handback and must never be replayed.
    func bringBrieflyInFront(
        _ target     : WindowReference,
        until isReady: @MainActor () -> Bool,
        atMost bound : UInt64,
        performOnce  : (@MainActor () -> Bool)? = nil
    ) async -> (outcome: BriefActivationOutcome, summary: String) {
        guard !isPaused else { return (.refused(.seatNotReady), "the focus recovery is paused") }
        rememberUserWindow()
        guard let person = destination, sensing.frontmostProcessID == person.processID else {
            return (.refused(.noUserWindow), "no window of the person's own is in front to come back to")
        }
        let targets = adopted()
        invalidatePreparation()
        do { try prepareDestination(target, targets) }
        catch {
            return (.refused(.targetNotPrepared),
                    "window \(target.windowNumber) could not be prepared: \(String(describing: error))")
        }

        let bound = min(bound, Self.briefActivationLimitNanoseconds)
        let start = now()
        expectActivation(of: target.processID, until: start &+ bound &+ Self.briefHandbackLimitNanoseconds)
        var frontRefusal: String?
        do {
            let code = try restoreForBriefActivation(target)
            if code != 0 { frontRefusal = "request code \(code)" }
        } catch { frontRefusal = String(describing: error) }
        var readyAfter: UInt64?
        if frontRefusal == nil {
            readyAfter = await pollInFront(target, until: isReady, from: start, bound: bound)
        }
        if readyAfter != nil, let performOnce {
            let current = sensing.windowGeometry(of: target.windowNumber)
            let canPerform = current?.hasSameIdentity(as: target) == true
                && adopted().contains(where: { $0.hasSameIdentity(as: target) })
                && now() < start &+ bound && !Task.isCancelled && !isPaused
                && isFrontmost(target.processID) && sensing.frontmostProcessID == target.processID
            if !canPerform || !performOnce() { readyAfter = nil }
        }

        let inFront = now() &- start
        let outcome: BriefActivationOutcome = frontRefusal != nil
            ? .refused(.frontRequestRefused)
            : readyAfter.map { .ready(afterMilliseconds: Int($0 / 1_000_000)) }
                ?? .notReady(afterMilliseconds: Int(inFront / 1_000_000))
        var summary = frontRefusal.map { "the request for the front was refused: \($0)" }
            ?? "in front for \(Self.milliseconds(inFront)), "
                + (readyAfter.map { "ready after \(Self.milliseconds($0))" } ?? "not ready")

        // A request that failed may still have moved the front, so this asks
        // the window server rather than the request's answer.
        guard isFrontmost(target.processID) else {
            endExpectedActivation()
            let front = sensing.frontmostProcessID.map { "process \($0)" } ?? "no process"
            summary += ", and the front is with \(front), where it was left"
            await refreshPreparation()
            return (readyAfter == nil ? outcome : .handbackNotVerified, summary)
        }
        let handbackStart = now()
        let handback = await giveFrontBack(to: person, targets: adopted())
        let handbackDuration = now() &- handbackStart
        endExpectedActivation()
        guard handback.verified else {
            summary += ", and the front was not verified back on window \(person.windowNumber) within "
                + Self.milliseconds(Self.briefHandbackLimitNanoseconds)
                + (handback.refusal.map { " (\($0))" } ?? "")
            if isFrontmost(target.processID) {
                activationChanged(to: target.processID, source: .briefActivationHandback)
                summary += ", so the ordinary recovery has it"
            } else {
                summary += ", where the person's front was left"
                await refreshPreparation()
            }
            return (.handbackNotVerified, summary)
        }
        summary += ", gave the front back to window \(person.windowNumber) in \(Self.milliseconds(handbackDuration))"
        await refreshPreparation()
        return (outcome, summary)
    }

    /// Reads `isReady` every 20 ms while `target` is in front, and answers how
    /// long after `start` it held, nil when it never did. It stops at `bound`,
    /// on cancellation, and once the person has taken the front the target had.
    /// A count bounds it as well as the clock, so an injected clock that stands
    /// still cannot hold the front for ever.
    private func pollInFront(
        _ target     : WindowReference,
        until isReady: @MainActor () -> Bool,
        from start   : UInt64,
        bound        : UInt64
    ) async -> UInt64? {
        let deadline = start &+ bound
        let polls    = bound / Self.briefActivationPollNanoseconds + 1
        var seenInFront = false
        for _ in 0 ..< polls {
            guard now() < deadline, !Task.isCancelled else { return nil }
            await EventLoopWait.sleep(.nanoseconds(Self.briefActivationPollNanoseconds))
            guard now() < deadline, !Task.isCancelled else { return nil }
            let inFront = isFrontmost(target.processID) && sensing.frontmostProcessID == target.processID
            // The activation can show a moment after the request, so only a
            // front the target was seen holding can be taken from it.
            if seenInFront, !inFront { return nil }
            seenInFront = seenInFront || inFront
            if inFront, isReady() {
                guard now() < deadline, !Task.isCancelled,
                      isFrontmost(target.processID), sensing.frontmostProcessID == target.processID
                else { return nil }
                return now() &- start
            }
        }
        return nil
    }

    /// Asks for the person's window and waits, inside the verification window
    /// and at the recovery's own 5 ms cadence, for it to read as focused twice
    /// in a row. `refusal` says why the request itself failed.
    private func giveFrontBack(
        to person: WindowReference,
        targets  : [WindowReference]
    ) async -> (verified: Bool, refusal: String?) {
        do {
            try prepareDestination(person, targets)
            let code = try restoreForBriefActivation(person)
            if code != 0 { return (false, "request code \(code)") }
        } catch { return (false, String(describing: error)) }
        let verificationStart = now()
        let deadline = verificationStart &+ Self.briefHandbackLimitNanoseconds
        var agreeing = 0
        var lastWindow: WindowReference?
        var lastFront: Int32?
        var lastWindowWasEligible = false
        var lastMatches = false
        var readings = 0
        var lastReadingDuration: UInt64 = 0
        var firstMatchAfter: UInt64?
        for _ in 0 ..< Self.briefHandbackLimitNanoseconds / 5_000_000 {
            guard now() < deadline, !Task.isCancelled else { break }
            await EventLoopWait.sleep(.milliseconds(5))
            guard now() < deadline, !Task.isCancelled else { break }
            let readingStart = now()
            lastWindow = sensing.focusedUserWindow
            let destinationIsValid = lastWindow.map(validDestination) ?? false
            // Geometry and visibility can take time to read. Check foreground
            // after them, so a choice made during that work cannot confirm the
            // previous window on the second agreeing sample.
            lastFront = sensing.frontmostProcessID
            lastWindowWasEligible = destinationIsValid && lastFront == lastWindow?.processID
            lastMatches = lastWindowWasEligible && lastWindow?.hasSameIdentity(as: person) == true
            readings += 1
            let readingEnd = now()
            lastReadingDuration = readingEnd &- readingStart
            if lastMatches, firstMatchAfter == nil { firstMatchAfter = readingEnd &- verificationStart }
            guard readingEnd < deadline, !Task.isCancelled else { break }
            agreeing = lastMatches ? agreeing + 1 : 0
            if agreeing == 2 { return (true, nil) }
        }
        let reading = lastWindow.map {
            "focused window \($0.windowNumber), owner \($0.processID), frame \($0.frame), eligible \(lastWindowWasEligible)"
        } ?? "no focused window"
        let firstMatch = firstMatchAfter.map(Self.milliseconds) ?? "none"
        return (false, "\(reading), workspace foreground \(lastFront.map(String.init) ?? "none"), "
            + "matches expected identity \(lastMatches), \(readings) readings, "
            + "last reading \(Self.milliseconds(lastReadingDuration)), first match \(firstMatch), "
            + "elapsed \(Self.milliseconds(now() &- verificationStart))")
    }

    /// The driver awaits this before preparation and before every atomic command,
    /// including menu selection and each command of a sequence. It never replays input.
    func prepareBeforeAction() async throws {
        try Task.checkCancellation()
        guard allowed else { throw InputFailure.inputPaused([.holdEnded]) }
        guard !isPaused else { throw InputFailure.inputPaused([.activationUnverified]) }
        // Supersede what is in flight, but do not discard what is already held.
        // This call rebuilds a preparation only when the person's application is
        // the front one, and a Command taken while the target is in front cannot
        // meet that: a dialog the previous Command opened has already activated
        // it. Dropping the held preparation there disarmed the very activation
        // it was made for, and the seat then waited for a person who had done
        // nothing. What keeps the kept evidence honest is unchanged: the one
        // second lifetime, and every fact re-checked at the activation.
        supersedePreparation()
        guard sensing.fenceIsActive else { throw InputFailure.inputPaused([.fenceInactive]) }
        // A transition out of time is over: leaving it would hold the budget of
        // the next Command closed until the next beat noticed.
        if let transition = closure, now() >= transition.deadline { endClosureTransition() }
        guard !requestsSpent else { return }
        let action = await makePreparation(readingUserWindow: true)
        try Task.checkCancellation()
        guard allowed else { throw InputFailure.inputPaused([.holdEnded]) }
        guard !isPaused else { throw InputFailure.inputPaused([.activationUnverified]) }
        guard sensing.fenceIsActive else { throw InputFailure.inputPaused([.fenceInactive]) }
        if let action { prepared = action }
        // The last reading before the post is what a closure transition is
        // opened on, and this is where it lands.
        openExpectedClosure()
    }

    /// Rebuilds the preparation outside the input path, so that an application
    /// which activates itself between two Commands or between two Turns meets
    /// evidence instead of a named miss.
    ///
    /// ## Why a refresh is the only way such an activation can be armed
    ///
    /// A preparation is storable only while the **person's** application is
    /// frontmost, and a driven application that raises a dialog activates
    /// itself before anything else is observable. So the only preparation that
    /// can ever arm that activation is one built before it, and outside an
    /// atomic Command nothing was building one.
    ///
    /// ## The signals it is called on, and why the ordering does not decide it
    ///
    /// The seat calls this on the accessibility window-created wake-up, which
    /// this repository measures 79 to 249 ms ahead of the window server
    /// publishing the window, and on the one-a-second heartbeat. Whether that
    /// wake-up also precedes the workspace activation of the same dialog is not
    /// established anywhere here, so nothing rests on it: the beat alone keeps
    /// the preparation no older than its own period, and the wake-up only makes
    /// it younger on the openings where it does come first. On the openings
    /// where it does not, the guards below refuse to store and the beat's
    /// preparation is the one that answers.
    ///
    /// ## What the beat re-derives, and what it leaves alone
    ///
    /// The snapshot, and not the destination. Window geometry moves with no
    /// notification behind it, an adopted window relocating or the person
    /// dragging their own, so the snapshot is what expires and what the beat
    /// exists to renew. The destination does not move by itself: it changes
    /// when the person changes it, and both notifications that carry that
    /// already read it. A destination that turned invalid with no notification,
    /// the person dragging their window over the virtual display or off every
    /// physical one, is refused at the activation by `containsUserWindow`
    /// against the freshly prepared snapshot, which is the same test the live
    /// `validDestination` makes and takes no round trip of its own.
    ///
    /// So the beat reads the destination on a notification or while it holds
    /// none, and otherwise reuses the one in hand. A read that answered nothing
    /// leaves none in hand and is therefore retried on the next beat, which is
    /// what keeps one 50 ms accessibility timeout from disarming the refresh
    /// until the person next switches application.
    ///
    /// It stores or stores nothing, under every guard the input path uses, and
    /// it activates, raises and posts nothing. The window enumeration stays off
    /// the main actor exactly as `prepareBeforeAction` leaves it.
    func refreshPreparation() async {
        // One refresh at a time: a second would supersede the first and pay for
        // a second enumeration to reach the same answer.
        guard !isRefreshing else { return }
        // The seat holds the front on purpose, so nothing of the person's is in
        // front to prepare, and the restorer's participant is in use.
        guard !isExpectingActivation else { return }
        // A closure transition is the one episode that may refresh with the gate
        // closed, and it refreshes something else: see `reconcileClosureEvidence`.
        guard !isPaused else {
            _ = await reconcileClosureEvidence()
            return
        }
        // One that outlived its deadline with the focus where it belongs closes
        // without a word: there is nothing left for it to answer.
        if let transition = closure, now() >= transition.deadline { endClosureTransition() }
        isRefreshing = true
        defer { isRefreshing = false }
        // Cleared before the await, so a notification arriving during it is
        // owed to the next beat rather than lost to this one.
        let readingUserWindow = userWindowNeedsReading || destination == nil
        userWindowNeedsReading = false
        guard let action = await makePreparation(readingUserWindow: readingUserWindow) else { return }
        prepared = action
    }

    /// The one build both paths share: resolve the destination, read the window
    /// server, re-check every fact the reading rests on, and answer a
    /// preparation or nothing.
    ///
    /// It never throws. A caller that has to refuse input refuses on the guards
    /// it reads around this call, not on this call, which is what lets the
    /// refresh use the same definition of a valid preparation without also
    /// inheriting the input path's reasons to fail a Command.
    /// `readingUserWindow` is false only for a beat that already holds a
    /// destination no notification has touched. Every guard that decides
    /// whether the answer may be **stored** is below and runs either way,
    /// including the one that requires the person's application to be frontmost
    /// for the destination this preparation is about.
    /// Refreshes the evidence of an open closure transition with the gate
    /// closed, which is the one thing `makePreparation` cannot do.
    ///
    /// `makePreparation` requires the person's application to be frontmost,
    /// and after the steal it is not: calling it again would refuse for the
    /// same reason it refused the first time, and the transition would have no
    /// way back. So this path refreshes only the environment and the target
    /// evidence, and keeps everything about the person exactly as it was.
    ///
    /// What it keeps: the destination and its attested identity and serial
    /// number. What it checks: that the same window is still there, under the
    /// same identity. What it refreshes: the adopted set, the retained serial
    /// numbers of the surfaces, and the window server snapshot. What it never
    /// does: learn a destination from whatever is active now, substitute an
    /// owner whose retention expired, or widen the set of surfaces the seat
    /// attested when the transition opened. If the original destination is not
    /// the window it was, this answers nothing and the seat waits for a real
    /// choice by the person.
    ///
    /// It is bounded twice, by the transition's deadline and by its own count,
    /// so a destination that stays unreadable costs a fixed number of readings
    /// and not one per verification tick.
    func reconcileClosureEvidence() async -> Bool {
        guard !isRefreshing, var transition = closure,
              transition.reconciliations < Self.closureRequestBudget,
              now() < transition.deadline else { return false }
        isRefreshing = true
        defer { isRefreshing = false }
        transition.reconciliations += 1
        closure = transition
        preparationAttempts += 1

        let start = now()
        let generation = preparationGeneration
        let targets = adopted()
        let destination = transition.destination
        // The same person, the same window. Its persistence is verified; it is
        // never re-derived, and the active target is never asked.
        guard let live = sensing.windowGeometry(of: destination.windowNumber),
              live.hasSameIdentity(as: destination) else {
            return refused("the closure transition's destination is no longer the window it was")
        }
        let identityStart = now()
        // The remote content may have closed with the dialog. Its PSN was
        // retained before the Command; renewal only rebinds the still-live
        // user destination and never discovers a replacement owner.
        do { try renewDestination(destination) }
        catch {
            return refused("the closure transition could not be renewed: \(String(describing: error))")
        }
        let identityDuration = now() &- identityStart
        let processIDs = Set(targets.map(\.processID)).union([destination.processID])
        let snapshot = await sensing.prepareFocusRecoverySnapshot(for: processIDs)

        guard closure != nil, generation == preparationGeneration else {
            return refused("the closure transition ended during its reconciliation")
        }
        guard now() &- start <= Self.preparationLifetimeNanoseconds else {
            return refused("the reconciliation outlived what a preparation is allowed to live")
        }
        guard adopted() == targets else {
            return refused("the windows the seat holds changed during the reconciliation")
        }
        guard let snapshot else {
            return refused("the window server reading for the reconciliation was refused")
        }
        note("the closure transition is renewed, back to window \(destination.windowNumber)")
        prepared = PreparedAction(snapshot: snapshot, destination: destination,
                                  targets: targets, started: start, duration: now() &- start,
                                  identityDuration: identityDuration)
        return true
    }

    private func makePreparation(readingUserWindow: Bool) async -> PreparedAction? {
        preparationAttempts += 1
        guard sensing.fenceIsActive else { return unprepared("the cursor fence is not active") }
        let start = now()
        if readingUserWindow { rememberUserWindow() }
        let generation = preparationGeneration
        let targets = adopted()
        guard let destination else {
            return unprepared("no window of the person's own is known to go back to")
        }
        let identityStart = now()
        // A failed read is an unarmed action, not evidence that it posted input.
        do { try prepareDestination(destination, targets) }
        catch {
            return unprepared("the destination could not be prepared: \(String(describing: error))")
        }
        let identityDuration = now() &- identityStart
        let processIDs = Set(targets.map(\.processID)).union([destination.processID])
        let snapshot = await sensing.prepareFocusRecoverySnapshot(for: processIDs)

        // The same guards, one at a time instead of in one list. Nothing about
        // the decision changed. A list answers "not armed", and a diagnosis has
        // to know which of six facts said so, because they are six different
        // stories and only one of them is anybody's fault.
        guard !isPaused else { return unprepared("input was already paused") }
        guard generation == preparationGeneration else {
            return unprepared("a newer preparation superseded this one")
        }
        guard now() &- start <= Self.preparationLifetimeNanoseconds else {
            return unprepared("the reading outlived what a preparation is allowed to live")
        }
        guard sensing.frontmostProcessID == destination.processID else {
            let front = sensing.frontmostProcessID.map { "\($0)" } ?? "none"
            return unprepared(
                "the person's own application is not frontmost: the destination is window "
                    + "\(destination.windowNumber) of process \(destination.processID), "
                    + "and process \(front) is in front"
            )
        }
        guard !sensing.userMayBeSwitchingApplications else {
            return unprepared("the person may be switching applications")
        }
        guard adopted() == targets else {
            return unprepared("the windows the seat holds changed during the reading")
        }
        guard let snapshot else {
            return unprepared("the window server reading for the restoration was refused")
        }

        note("a focus restoration is armed, back to window \(destination.windowNumber)")
        return PreparedAction(snapshot: snapshot, destination: destination,
                              targets: targets, started: start, duration: now() &- start,
                              identityDuration: identityDuration)
    }

    /// Answers no preparation and says why, once per distinct reason.
    ///
    /// It is a reading and nothing else: what the caller does is the `nil` it
    /// was already being given, unchanged. Only the silence is gone.
    private func unprepared(_ reason: String) -> PreparedAction? {
        note("no focus restoration is armed: " + reason)
        return nil
    }

    /// The same reading for the reconciliation, whose answer is a Bool.
    private func refused(_ reason: String) -> Bool {
        note("no focus restoration is armed: " + reason)
        return false
    }

    /// Writes one line when the preparation's answer changes, and nothing at all
    /// while it stays the same: this runs on every heartbeat, and a line per
    /// beat would bury the change it exists to report.
    private func note(_ outcome: String) {
        guard outcome != lastPreparationOutcome else { return }
        lastPreparationOutcome = outcome
        Self.log.notice("\(outcome, privacy: .public)")
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.1f ms", Double(nanoseconds) / 1_000_000)
    }

    private static func windowNumbers(_ windows: [WindowReference]) -> String {
        windows.isEmpty ? "none" : windows.map { "\($0.windowNumber)" }.joined(separator: ", ")
    }

    /// Makes a preparation in flight stale without discarding the one in hand.
    private func supersedePreparation() {
        preparationGeneration &+= 1
    }

    /// Supersedes and drops: the held evidence is about a destination, a hold or
    /// a user window that is no longer the one this recovery is about.
    private func invalidatePreparation() {
        supersedePreparation()
        prepared = nil
    }

    func rememberUserWindow() {
        guard !isPaused else { return }
        guard !adopted().contains(where: { $0.processID == sensing.frontmostProcessID }) else { return }
        let current = currentUserWindow()
        if destination?.windowNumber != current?.windowNumber || destination?.processID != current?.processID {
            invalidatePreparation()
        }
        destination = current
    }

    func activationChanged(
        to processID: Int32,
        source: UserFocusRecoveryTiming.ActivationSource = .unspecified,
        receivedAt: UInt64? = nil
    ) {
        let detected = now()
        userWindowNeedsReading = true
        let targets = adopted()
        // Whose activation this is. A remote service of an attested surface is
        // the application taking the front; an unknown process is nobody.
        let isSeatActor = targets.contains { $0.processID == processID }
            || closure?.stealActors.contains(processID) == true
        guard isSeatActor else {
            if isPaused {
                if processID == destination?.processID, frontmostRestored == nil {
                    frontmostRestored = now() &- started
                }
                // An application other than the recovery destination was
                // chosen while recovering. Its current window is authoritative.
                if processID != destination?.processID {
                    if let chosen = currentUserWindow() {
                        destination = chosen
                        userSelectedDestination = true
                        candidate = nil
                    } else if closure == nil {
                        destination = nil
                        userSelectedDestination = true
                        candidate = nil
                    } else {
                        // Neither the person nor the seat: the saved
                        // destination and the closed gate stay as they were.
                        note("an unclassifiable activation of process \(processID) "
                            + "left the closure transition's destination alone")
                    }
                }
                verify()
            } else {
                rememberUserWindow()
            }
            return
        }
        // The seat brought this process in front itself: not a steal, and it
        // spends nothing. See `expectActivation(of:until:)`.
        if isExpected(processID) {
            note("process \(processID) is in front because the seat brought it there on purpose")
            return
        }
        // Outside a Turn nothing had armed this, so the activation returned in
        // silence. It is the first signal of the operation, so it opens it.
        openOperationOnActivation(at: detected)
        guard allowed || isPaused else { return }
        guard !isPaused else { return }

        // Close the posting gate before any validation or private call.
        started = detected
        timing = UserFocusRecoveryTiming()
        timing.destinationPreparationNanoseconds = destinationPreparation
        timing.detectedAtUptimeNanoseconds = started
        timing.activationSource = source
        timing.notificationReceivedAtUptimeNanoseconds = receivedAt
        gate.pause(.focusRecovery)
        isPaused = true
        activatingPID = processID
        code = nil
        requestRefusal = nil
        frontmostRestored = nil
        candidate = nil
        userSelectedDestination = false
        requestedThisActivation = false
        emit(.restoring)

        requestRestoration(detected: detected, targets: targets, processID: processID)

        guard isPaused else { return }
        timer = Timer(timeInterval: 0.005, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.verify() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    /// Validates the evidence in hand and either asks for the destination or
    /// names why it could not. The gate is already closed and `.restoring` is
    /// already published.
    ///
    /// It is separate from the activation because a closure transition may run
    /// it a second time, on evidence its reconciliation made valid again, for
    /// an activation that asked for nothing. It is also the only place a
    /// request is counted, and the count happens where the call is made: the
    /// flag it replaced was raised here before any of this was known, so a
    /// stale preparation spent the episode's budget without restoring anything.
    private func requestRestoration(detected: UInt64, targets: [WindowReference], processID: Int32) {
        var checkpoint = now()
        timing.pauseAndPublicationNanoseconds = checkpoint &- started
        let action = prepared
        invalidatePreparation()
        // The four ways a preparation can fail to arm this activation are four
        // different situations with four different answers, so each one is
        // named. They used to share one sentence, which told a consumer that
        // something was missing and never which thing.
        let spent          = requestsSpent
        // `detected` identifies the activation for diagnostics. Reconciliation
        // can renew a preparation after that notification, so its freshness
        // must be measured from this request's monotonic instant. Unsigned
        // subtraction made a renewed action look billions of milliseconds old.
        let age            = action.map { checkpoint >= $0.started ? checkpoint - $0.started : 0 }
        let expired        = age.map { $0 > Self.preparationLifetimeNanoseconds } ?? false
        // An ID gone from a closure transition's set is the effect the Command
        // asked for. Nothing else is relaxed: see the ADR section of 19/09/2026.
        let targetsChanged = action.map { prepared in
            closure == nil
                ? prepared.targets != targets
                : !targets.allSatisfy(prepared.targets.contains)
        } ?? false
        let fresh = !spent && action != nil && !expired && !targetsChanged
        let snapshot = fresh ? action?.snapshot : nil
        timing.actionPreparationNanoseconds = action?.duration ?? 0
        timing.preparedIdentityNanoseconds = action?.identityDuration ?? 0
        timing.preparedWindowsNanoseconds = action?.snapshot.windowsNanoseconds ?? 0
        timing.preparedSnapshotAgeNanoseconds = age ?? 0
        let topologyValid   = snapshot?.topologyIsValid == true
        let windowsComplete = snapshot?.windowsAreComplete == true
        let physicalStable  = sensing.physicalTopologyIsUnchanged
        let virtualOnline   = sensing.virtualDisplayIsOnline
        let virtualUnmoved  = sensing.virtualDisplayBounds == snapshot?.virtualBounds
        let environmentValid = topologyValid && windowsComplete
            && physicalStable && virtualOnline && virtualUnmoved
        timing.environmentNanoseconds = now() &- checkpoint
        checkpoint = now()
        let adoptedValid = environmentValid && snapshot?.containsAdoptedWindows(targets) == true
        timing.adoptedWindowsNanoseconds = now() &- checkpoint
        checkpoint = now()
        let visibleValid = adoptedValid && Set(targets.map(\.processID)).allSatisfy {
            snapshot?.containsOnlyVirtualWindows(of: $0) == true
        }
        timing.visibleWindowsNanoseconds = now() &- checkpoint
        checkpoint = now()
        let destinationValid = visibleValid && destination.map {
            snapshot?.containsUserWindow($0, excluding: targets) == true
                && action?.destination.hasSameIdentity(as: $0) == true
        } == true
        timing.destinationNanoseconds = now() &- checkpoint
        checkpoint = now()
        let frontMatches = destinationValid && isFrontmost(processID)
        // The gate is already closed and activation posts no pointer input.
        // A WindowServer tapIsEnabled round trip belongs before input and in
        // verify(), not between losing focus and returning it to the user.
        let mayRestore = frontMatches && !sensing.userMayBeSwitchingApplications
        timing.finalGuardsNanoseconds = now() &- checkpoint
        if mayRestore, let destination {
            // Counted before the call: an uncertain effect is a request made,
            // because nothing here can prove the focus did not move.
            restoreRequests += 1
            requestedThisActivation = true
            var refusal: String?
            do {
                code = try restore(destination)
                if code != 0 { refusal = "The focus request was refused" }
            } catch { refusal = String(describing: error) }
            let request = requestTiming()
            timing.ownerLookupNanoseconds = request.ownerLookupNanoseconds
            timing.psnLookupNanoseconds = request.psnLookupNanoseconds
            timing.activationNanoseconds = request.activationNanoseconds
            timing.firstKeyNanoseconds = request.firstKeyNanoseconds
            timing.secondKeyNanoseconds = request.secondKeyNanoseconds
            // The restorer measures its own call, so a throw still carries it.
            timing.restoreCallNanoseconds = request.restoreCallNanoseconds
            timing.restoreCallControlNanoseconds = request.restoreCallControlNanoseconds
            timing.requestFinishedNanoseconds = now() &- started
            requestRefusal = refusal
            if let refusal { emit(.waitingForUser, detail: refusal) }
        } else {
            let reason: String
            if !fresh {
                if spent {
                    if closureDeadlinePassed {
                        reason = "The closure transition ran out of time before this request"
                    } else {
                        reason = requestBudget == 1
                            ? "The one automatic request of this episode was already spent"
                            : "Both automatic requests of this closure transition were already spent"
                    }
                } else if action == nil {
                    reason = "No prepared action was held when this activation arrived"
                } else if expired {
                    reason = "The prepared action expired: "
                        + "\(Self.milliseconds(age ?? 0)) old, and the limit is "
                        + "\(Self.milliseconds(Self.preparationLifetimeNanoseconds))"
                } else {
                    reason = "The adopted windows changed after the preparation: prepared "
                        + "\(Self.windowNumbers(action?.targets ?? [])), now "
                        + "\(Self.windowNumbers(targets))"
                }
            }
            else if !environmentValid {
                let fallen = [
                    topologyValid  ? nil : "the prepared snapshot's topology",
                    windowsComplete ? nil : "the prepared window list is incomplete"
                        + (snapshot?.firstUnresolvedWindow.map { " at Window ID \($0)" } ?? ""),
                    physicalStable ? nil : "the physical topology, which changed",
                    virtualOnline  ? nil : "the virtual display, which is not online",
                    virtualUnmoved ? nil : "the virtual display's bounds, which moved from "
                        + "\(String(describing: snapshot?.virtualBounds)) to "
                        + "\(sensing.virtualDisplayBounds)",
                ].compactMap { $0 }
                reason = "Focus recovery evidence is invalid: " + fallen.joined(separator: ", ")
            }
            else if !adoptedValid { reason = "An adopted window is absent or outside the virtual display" }
            else if !visibleValid {
                // Which window it was is the whole diagnosis: a thumbnail the
                // window manager keeps on the person's display reads exactly
                // like a target window that was never moved.
                let outside = targets.map(\.processID).compactMap {
                    snapshot?.firstWindowOutsideVirtualDisplay(of: $0)
                }.first
                reason = outside.map {
                    "A prepared target window is outside the virtual display: Window ID "
                        + "\($0.windowNumber) of PID \($0.processID) at \($0.frame)"
                } ?? "The prepared snapshot has no window of a target process"
            }
            else if !destinationValid { reason = "The prepared user window is absent or invalid" }
            else if !frontMatches { reason = "The front process no longer matches the activating target" }
            else { reason = "Recent user app-switch intent" }
            requestRefusal = reason
            emit(.waitingForUser, detail: reason)
        }
    }

    func verify() {
        guard isPaused else { return }
        guard sensing.physicalTopologyIsUnchanged, sensing.virtualDisplayIsOnline,
              sensing.fenceIsActive else { return }
        reconcileIfOwed()
        if sensing.frontmostProcessID == destination?.processID, frontmostRestored == nil {
            frontmostRestored = now() &- started
        }
        if let current = currentUserWindow(), let destination,
           current.hasSameIdentity(as: destination) {
            // Inside the protection two agreeing readings end nothing: an
            // Electron panel completes later than it disappears.
            if candidate?.hasSameIdentity(as: current) == true,
               closureProtectionRemaining ?? 0 == 0 {
                timer?.invalidate()
                timer = nil
                isPaused = false
                // The episode is over, so its one automatic request is over with
                // it. The budget is one request per activation, not one per
                // hold: an application that activates itself twice in one hold
                // is one dialog opening and then another, and the second had no
                // way to ask. A hold spans a whole run in a consumer that holds
                // the seat across Commands, which made the second activation of
                // that run wait for a person who may not be there. An operation
                // outside a Turn is one delivery or containment whatever it
                // opens, so its single attempt stays spent until it ends.

                // A closure transition is explicit and keeps its count: the
                // distinct steal after a return spends the second of its two.
                if holdIsArmed { restoreRequests = 0 }
                else if operationIsArmed, !operationHasTransfer { operationRestoredAt = now() }
                requestedThisActivation = false
                gate.resume(.focusRecovery)
                emit(userSelectedDestination ? .userTookControl : .restored)
                return
            }
            candidate = current
        } else { candidate = nil }
        if now() &- started >= Self.verificationWindowNanoseconds, timer?.timeInterval == 0.005 {
            emit(.waitingForUser, detail: requestRefusal ?? "Focus was not verified within 250 ms")
            timer?.invalidate()
            timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.verify() }
            }
            if let timer { RunLoop.main.add(timer, forMode: .common) }
        }
        // Last, so that the precise end is the last word a consumer reads and
        // not one the cadence drop writes over a tick later.
        noteClosureDeadline()
    }

    /// Names the real impossibility once, when the transition has spent
    /// everything it had and the person's focus is still not back.
    ///
    /// It stops the transition asking and reconciling; it does not stop the
    /// seat waiting. The person coming back still ends the episode, and the
    /// explicit panic is still theirs to press. Anything else here is a seat
    /// fighting an application or a person, which is the one thing this may
    /// never become.
    private func noteClosureDeadline() {
        guard var transition = closure, !transition.deadlineReported,
              now() >= transition.deadline else { return }
        transition.deadlineReported = true
        closure = transition
        emit(.unrecoverable, detail: "The closure transition ran out of time after "
            + "\(Self.milliseconds(now() &- transition.openedAt)) and "
            + "\(restoreRequests) of \(Self.closureRequestBudget) requests, with "
            + (requestRefusal.map { "the last refusal: " + $0 } ?? "the focus not verified"))
    }

    /// Renews a refused preparation while the gate is closed, and asks once on
    /// what the renewal made valid again.
    ///
    /// It runs only for an activation that asked for nothing: a request already
    /// made and not verified is not a reason to ask again, and a transition
    /// past its deadline or its count asks for nothing at all. The flag is
    /// raised before the task and not inside it, because the verification timer
    /// calls this every five milliseconds and an asynchronous guard would let a
    /// queue of them through.
    private func reconcileIfOwed() {
        guard isPaused, !reconcileInFlight, !requestedThisActivation, !requestsSpent,
              prepared == nil, let transition = closure,
              transition.reconciliations < Self.closureRequestBudget,
              now() < transition.deadline else { return }
        reconcileInFlight = true
        let detected = started
        let processID = activatingPID
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.reconcileInFlight = false }
            guard await self.reconcileClosureEvidence(), self.isPaused,
                  !self.requestedThisActivation else { return }
            self.requestRestoration(detected: detected, targets: self.adopted(),
                                    processID: processID)
        }
    }

    func userWindowChanged() {
        userWindowNeedsReading = true
        // A notification while the target is active may merely describe the
        // user's window losing key status. It must not erase the pending recovery.
        if !isPaused, !adopted().contains(where: { $0.processID == sensing.frontmostProcessID }) {
            invalidatePreparation()
        }
        if isPaused, sensing.userMayBeSwitchingApplications, let current = currentUserWindow() {
            destination = current
            userSelectedDestination = true
            candidate = nil
        } else { rememberUserWindow() }
    }

    func stop() {
        invalidatePreparation()
        closure              = nil
        expectedClosure      = nil
        expectedActivation   = nil
        holdIsArmed          = false
        operationIsArmed     = false
        operationHasTransfer = false
        operationRestoredAt  = nil
        timer?.invalidate()
        timer = nil
        // Terminal on purpose, and its own cause: a seat that lost its focus
        // recovery never posts again, and nothing resolves this one.
        gate.pause(.focusRecoveryStopped)
        if isPaused { emit(.cancelled) }
        isPaused = false
    }

    private func currentUserWindow() -> WindowReference? {
        guard let window = sensing.focusedUserWindow,
              sensing.frontmostProcessID == window.processID,
              validDestination(window) else { return nil }
        return window
    }

    private func validDestination(_ window: WindowReference) -> Bool {
        guard !adopted().contains(where: { $0.processID == window.processID }),
              let current = sensing.windowGeometry(of: window.windowNumber),
              current.hasSameIdentity(as: window),
              !current.frame.isEmpty, !current.frame.intersects(sensing.virtualDisplayBounds)
        else { return false }
        return sensing.windowIsVisibleOnPhysicalDisplay(current)
    }

    private func emit(_ outcome: UserFocusRecoveryReport.Outcome, detail: String = "") {
        changed(UserFocusRecoveryReport(outcome: outcome, destination: destination,
            activatingProcessID: activatingPID, requestCode: code,
            frontmostRestoredNanoseconds: frontmostRestored,
            elapsedNanoseconds: now() &- started, detail: detail, timing: timing))
    }

    isolated deinit { timer?.invalidate() }
}
