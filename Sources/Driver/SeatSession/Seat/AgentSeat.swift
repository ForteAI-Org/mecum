//
//  AgentSeat.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import ApplicationServices
import CoreGraphics
import CursorGuard
import Darwin
import Dispatch
import Foundation
import os
import SeatCapture
import SeatCore
import SeatInput
import VirtualScreens
import WindowPlacement

/// AgentSeat is the agent's operating domain on the Virtual Display: the
/// windows it adopted, the exclusive hold that separates two safe points, the
/// guard that runs before every Command and the bounded recovery that answers a
/// recoverable Issue.
///
/// ## What it adds to the driver, and what it deliberately does not
///
/// The driver posts events. The seat decides whether posting is allowed right
/// now, and that decision is the reason this type exists:
///
/// - the identity of the target is re-read **immediately before** the events go
///   out, because a Window ID is reused after the window dies and a check taken
///   a second earlier is a check on a different window;
/// - the person's own seat is re-read too, and a Command is refused if the
///   target became active or came in front of the person's application;
/// - the window is brought on stage first if Stage Manager stashed it, and
///   nothing is posted until two window server readings agree on the full-size
///   frame;
/// - every posted Command is remembered as unconfirmed, and the hold cannot be
///   released while one is.
///
/// It adds nothing to the recipe. One Command is still one call, one Preparation
/// policy, no retry and no split. The seat never queues a Command while its
/// state refuses input: it answers `seatNotReady(state)` and the caller decides.
/// The driver can wait behind another transaction aimed at the same target PID,
/// then it re-verifies window identity after that wait and before posting.
///
/// ## Every Command carries the observation it was decided on
///
/// There is no entry point that takes a window and sends into it. A Command is
/// addressed by a `SeatObservationReference` the seat issued with the Frame the
/// consumer looked at, and the seat verifies that reference against the world at
/// admission. A new observation is required after every complete Command and
/// after every invalidation, the recipient is never recomputed from the current
/// target, and nothing here captures implicitly to make an old plan admissible.
/// The legacy entry points are gone rather than deprecated: see the `unavailable`
/// declarations below for what each one migrates to.
///
/// ## What it composes
///
/// The assignment nucleus and the selection nucleus are owned here, not
/// duplicated: an adoption hands the instance over, every reading is folded
/// through both, and the causes of the gate that decide an observation are the
/// ones those nuclei report. The evidence they need is supplied by adapters, and
/// the shipped adapters remain fail-closed: AX and WindowServer must agree on
/// the inventory, capture must carry a valid display timestamp, and the menu
/// surface is still unavailable. Every gap produces a named refusal before any
/// effect rather than an invented fact.
///
/// ## Never replay an uncertain effect
///
/// The kit cannot verify an effect: verifying needs the observation layer it
/// deliberately does not have. So the consumer verifies and says so with
/// `confirm`, in three values, and the difference between "nothing happened"
/// and "I do not know" is the difference between a safe resend and a duplicated
/// action. A Command that is never confirmed stays `unknown`, with no timeout
/// that promotes it, and a recoverable Issue arriving on top of an `unknown`
/// fails the seat with `ambiguousEffect` rather than recovering into a replay.
public final class AgentSeat {

    /// One Command posted under the current hold, and what the consumer said
    /// about its effect.
    private struct PostedCommand {
        let receipt     : InputReceipt
        var confirmation: EffectConfirmation?
    }

    private static let log = Logger(subsystem: "dev.forte.AgentSeatKit", category: "Session")

    /// How long `confirmPlacement` waits for two agreeing readings, as an
    /// absolute monotonic budget rather than a number of laps.
    private static let placementConfirmationNanoseconds: UInt64 = 2_000_000_000

    // MARK: The state, which used to be seventeen properties of a view controller

    /// Where the seat is. Reading it is always allowed; acting on it is what
    /// the state decides.
    public private(set) var state: SeatState = .unavailable

    /// The single channel out. Transitions, Issues, recovery progress and the
    /// fence's latched batches arrive here; the host's own events arrive on the
    /// host's stream.
    public let events: AsyncStream<SeatEvent>

    /// The identity and geometry the seat was fixed to, once a window is
    /// adopted. It is the guard of Core, and it performs no system call: the
    /// seat supplies the readings.
    public internal(set) var seatGuard: SeatGuard?

    /// Where a release leaves a window its application hid: the host's shared
    /// ledger, which outlives this seat. Nil keeps a test's releases to itself.
    var hiddenReturns: HiddenWindowReturns?

    let eventChannel: AsyncStream<SeatEvent>.Continuation

    let sensing  : any SeatSensing
    private let placing  : any WindowPlacing
    private let sender   : any CommandSending
    private let fence    : CursorFence?
    /// The display whose virtual-seat bounds qualified this assignment. Capture
    /// uses the same display to crop an attested hosted-sheet family.
    let displayID: CGDirectDisplayID
    private let expectedMainDisplayID: CGDirectDisplayID
    private let defaultPlatform      : any InputPlatform

    private let turns: TurnQueue

    var session                    = SeatWindowSession()
    private var transferGeneration : UInt64 = 0
    private var transfersInFlight  = 0
    private var recoveryTrigger    : [SeatIssue] = []
    private var pendingAdoptions: [Int: AdoptedWindow] = [:]
    private var adoptionRestorations: [Int: WindowReleaseOutcome] = [:]
    private var adoptionInFlight = false
    /// The identity this adoption is placing. Its resulting front-order edge belongs to the kit,
    /// so the native reader's raise attribution cannot turn containment into a selection change.
    var adoptingPlacementIdentity: WindowIdentity?
    var isTearingDown = false

    @TaskLocal
    private nonisolated static var nativeTextInputID: UUID?

    private var nativeTextInputContext: (window: WindowReference, turn: Turn, id: UUID)?

    /// True for the length of one coordinated assignment release, so nothing
    /// inside it restages a predecessor of a window that is on its way out.
    private var isReleasingAssignment = false

    /// What the seat answered for every window it has let go, by Window ID.
    ///
    /// The audit's last two lines were a warning about one auxiliary surface
    /// and then a teardown that reported no window at all: the per-window
    /// answers were given before the teardown and the final report started from
    /// nothing. It is kept here so the two agree, and it is the seat's whole
    /// life rather than one assignment because that is what the teardown
    /// report's own field says it is.
    var releaseLedger: [Int: WindowReleaseOutcome] = [:]

    private var adoptionWaiters: [CheckedContinuation<Void, Never>] = []
    var stagedWindowNumber         : Int?
    private var posted             : [PostedCommand] = []
    /// Positive scoped closure proof outlives the transition filter's one
    /// emitted pass. It is keyed by the complete lifetime identity and is
    /// cleared only when that same identity is positively observed again.
    /// An unavailable fresh read never consults it.
    var logicalClosureEvidence: [WindowIdentity: LogicalSurfacePresence] = [:]
    var reconciledLogicalClosures: Set<WindowIdentity> = []
    /// Window server destruction proofs a reading took but has not yet spent.
    /// Only the fold and the reconciliation before a release end a containment
    /// wait, so a proof that landed in the presence probe waits here for one of
    /// them rather than being lost with the pass that carried it.
    var pendingDestruction: Set<WindowIdentity> = []
    private var observer           : SeatObserver?
    private var observationSoFar   : SeatObservation?
    private var recoveryBudget     = RecoveryPolicy()
    private var recoveryEpisode    = 0
    private var recoveryTask       : Task<Void, Never>?
    private var wasDegradedBeforeRecovery = false

    /// The running recovery's plan as its last reading left it: how long the
    /// window has been unreadable, how long the episode has lasted and how
    /// many readings that took. It is what tells a wait that did not end the
    /// way it expected whether the loop was starved or the budget really had
    /// not expired, which are the two explanations a lap count cannot separate.
    private(set) var recoveryProgress: WindowRecoveryPlan?
    /// Installed only by `enableFocusRecovery`, on a host configured for it. It
    /// is not private because the private facility it needs cannot be composed
    /// in the unit tier, so a suite installs one over the fakes instead.
    var focusRecovery: UserFocusRecovery?
    private var focusWatch: UserFocusWatch?
    private var focusRecoveryWasDegraded = false
    private var actionInFlight = false

    // MARK: The observation half

    /// The authority that mints and verifies Observation References. It is owned
    /// here and handed to nobody: a second one would be a second opinion about
    /// which observation is current.
    let observationIssuer = ObservationIssuer()

    /// The assignment nucleus this seat drives, and the selection nucleus that
    /// borrows it. Both are the committed ones, composed here rather than
    /// modelled again.
    let assignmentKit: SeatAssignmentKit
    let selectionKit : SeatTargetSelectionKit

    let surfaceReader    : any AssignedSurfaceReading
    let observationSource: any ObservedSurfaceSourcing
    let sampleQualifier  : FrameSampleQualifier

    /// How a gesture's recipient is discovered and revalidated. See
    /// `EndpointDiscovery`.
    let endpoints: EndpointDiscovery

    /// The process the keys of one logical surface are actually posted to, by
    /// the surface's Window ID.
    ///
    /// A key Command over a hosted panel is addressed to the panel's content,
    /// which is another process, and that is the process the hold registry is
    /// keyed by: what went down went down there. The seat's own accounting of
    /// held keys covers the adopted windows' processes, and a recipient of
    /// another process is not among them, so it is recorded here as soon as one
    /// is resolved.
    ///
    /// It is deliberately not dropped when the helper goes: a key held inside a
    /// process that then closes is exactly the case the stranded report exists
    /// for, and forgetting the PID with the window would make the seat stop
    /// counting it. The assignment ending is what clears it.
    var keyboardRecipients: [Int: Int32] = [:]

    /// The finite positive budgets this seat observes and admits under.
    public let observationProfile: ObservationProfile

    /// The geometry of the Frame the outstanding reference was issued with, kept
    /// so admission compares the live window against the sample's own reading
    /// rather than against a reading taken later.
    var outstandingGeometry: WindowGeometryObservation?

    /// The menu interaction currently scoping what may be sent, nil when none is.
    var menuContext: MenuContext?

    /// Counts menu interactions, so a context kept past its interaction matches
    /// nothing.
    var menuGeneration: UInt64 = 0

    /// The selection generation the seat's own operating-window record is
    /// already aligned with, so a fold follows an application-local transition
    /// once and never follows the seat's own target change backwards.
    var alignedSelectionGeneration: UInt64 = 0

    /// The last reason a follow pass stood down, so the log names a reason when
    /// it starts rather than on every tick of the cadence.
    private var lastWindowFollowStandDown: String?

    var stateRevision   : UInt64 = 0
    var stateSubscribers: [ObjectIdentifier: SeatStateSubscription] = [:]

    /// The Monitor's own health, set by the host that owns the Monitor. It is
    /// separate from the observation's availability on purpose: an isolated
    /// Monitor fault costs the person the preview and costs the agent nothing.
    var monitorHealth: SeatMonitorHealth = .notRequested

    /// MW-03's two experiments, both off unless the host was configured for
    /// them. They are separate because the outward leg is free of focus and the
    /// return leg is not: see `SeatHostConfiguration`.
    package var transfersFullScreenWindows  = false
    package var restoresFullScreenOnRelease = false

    private var windowWatch    : AppWindowWatch?
    private var windowInventory = AppWindowInventory()
    private var windowFollowTask: Task<Void, Never>?
    private var windowFollowAgain = false
    private var windowFollowUntil: ContinuousClock.Instant?
    private var windowFollowPassInFlight = false

    /// Most recent focus episode, including a failed verification. Readiness
    /// describes the private facility separately from the normal input gate.
    public private(set) var lastFocusRecovery: UserFocusRecoveryReport?
    public private(set) var focusRecoveryReadiness: FacilityReadiness?

    /// Last failed adoption, including cancellation and the verified rollback.
    public private(set) var lastAdoptionFailure: WindowAdoptionFailure?

    /// How many window server passes the window watch has made since the seat
    /// started following. It is published because the cost of the watch is a
    /// number in scans as well as in CPU, and a benchmark that reported only
    /// the CPU would hide a pass that got cheap by looking less often.
    public private(set) var windowFollowScanCount = 0

    /// A failed move still owned by the host until teardown can restore it.
    public var hasPendingWindowRestorations: Bool { !pendingAdoptions.isEmpty }

    /// Whether this seat still owes a window return, including earlier assignments.
    /// A consumer must retain the host while this is true. A deferred return
    /// accepted by the shared hidden-window ledger does not require this host.
    public var hasOutstandingWindowReturns: Bool {
        if hasPendingWindowRestorations { return true }
        return releaseLedger.values.contains(where: Self.returnRequiresHost)
            || adoptionRestorations.values.contains(where: Self.returnRequiresHost)
    }

    private static func returnRequiresHost(_ outcome: WindowReleaseOutcome) -> Bool {
        switch outcome {
        case .refused, .leftOnVirtualDisplay: true
        case .returned, .vanished, .returnsWhenShown: false
        }
    }

    /// Every successfully adopted window, in Window ID order.
    public var adoptedWindows: [AdoptedWindow] { session.adoptedWindows }

    /// The window the seat is operating on: the most recent one adopted or
    /// asked for with `switchTarget(to:)`, nil when the seat holds none.
    ///
    /// It is the target and not "the visible window": several adopted windows
    /// can be on the screen at once, and which of them the seat considers
    /// current is a decision of this type rather than a reading of Stage
    /// Manager. `send(_:to:turn:)` still takes its window by parameter, so a
    /// request addressed to one window is never delivered to another because
    /// the target moved.
    public var currentTarget: AdoptedWindow? { session.currentTarget?.window }

    /// The succession of targets, oldest first, each window at most once. It is
    /// what a closure falls back through, and it is exposed because a consumer
    /// that shows the person what the agent is doing needs the same order.
    public var targetHistory: [Int] { session.targetHistory }

    /// True when this window is the one Stage Manager currently has on stage.
    public func isStaged(_ window: AdoptedWindow) -> Bool {
        session[window.id]?.isStaged == true
    }

    /// The hold currently out, nil when the seat is free.
    public var currentTurn: Turn? { turns.current }

    /// Composes the seat with the collaborators it needs.
    ///
    /// The observation collaborators have defaults that refuse: an
    /// `UnqualifiedObservationSource` captures nothing and an
    /// `UnqualifiedContentClock` measures no age. A production `SeatHost`
    /// explicitly supplies `MachAbsoluteContentClock`; direct composition without
    /// an oracle still answers a named capability refusal. The surface reader defaults
    /// to the shipped `SensingSurfaceReader`, which cross-checks AX with the
    /// WindowServer and falls back to an incomplete on-screen pass on any gap.
    init(
        sensing              : any SeatSensing,
        placing              : any WindowPlacing,
        sender               : any CommandSending,
        fence                : CursorFence?,
        displayID            : CGDirectDisplayID,
        expectedMainDisplayID: CGDirectDisplayID,
        defaultPlatform      : any InputPlatform = ChromiumPlatform(),
        markers              : @escaping () -> Int64 = { Int64.random(in: 1...Int64.max) },
        surfaceReader        : (any AssignedSurfaceReading)? = nil,
        observationSource    : any ObservedSurfaceSourcing = UnqualifiedObservationSource(),
        contentClock         : any ContentClockQualifying = UnqualifiedContentClock(),
        observationProfile   : ObservationProfile = .initialLab,
        endpoints            : EndpointDiscovery = .shipping
    ) {
        self.endpoints             = endpoints
        self.sensing               = sensing
        self.placing               = placing
        self.sender                = sender
        self.fence                 = fence
        self.displayID             = displayID
        self.expectedMainDisplayID = expectedMainDisplayID
        self.defaultPlatform       = defaultPlatform
        self.turns                 = TurnQueue(markers: markers)

        let assignment = SeatAssignmentKit()
        self.assignmentKit      = assignment
        self.selectionKit       = SeatTargetSelectionKit(assignment: assignment)
        self.surfaceReader      = surfaceReader ?? SensingSurfaceReader(sensing: sensing)
        self.observationSource  = observationSource
        self.sampleQualifier    = FrameSampleQualifier(clock: contentClock)
        self.observationProfile = observationProfile

        var channel: AsyncStream<SeatEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(128)) { channel = $0 }
        self.eventChannel = channel
    }

    // MARK: The hold

    /// acquire waits its turn and hands out exclusive use of the seat.
    ///
    /// `previous` is the caller's own last Turn. Passing it is what makes
    /// `seatChangedSinceLastHold` a fact rather than a guess: with it the queue
    /// can tell "nothing happened since your last hold" from "somebody else
    /// held the seat in between". The rule for the consumer is one line:
    /// generation changed, perceive again before acting.
    public func acquire(after previous: Turn? = nil) async throws -> Turn {

        guard !isTearingDown, state != .failed else { throw SessionFailure.seatNotReady(state) }

        let turn = try await turns.acquire(after: previous)
        focusRecovery?.beginHold()
        return turn
    }

    /// release gives the seat back, and refuses while a Command posted under
    /// this hold is unconfirmed.
    ///
    /// This is the anti-replay invariant at the safe point. Handing the seat to
    /// the next holder with an `unknown` in its past would let that holder act
    /// on a state nobody established, and the next holder cannot know: the
    /// evidence is a Command that already went out.
    public func release(_ turn: Turn) throws {
        guard nativeTextInputContext?.turn != turn else { throw InputFailure.nativeTextInputRefused(.contextActive) }

        let unconfirmed = posted.filter { $0.confirmation == nil }.count
        guard unconfirmed == 0 else {
            throw SessionFailure.unconfirmedCommands(count: unconfirmed)
        }

        // The same safe point invariant one step further: a key this Turn
        // pressed and never released is state inside another application, and
        // the next holder would inherit it without being told.
        let stillHeld = heldKeyCount(of: turn)
        guard stillHeld == 0 else {
            throw SessionFailure.keysStillHeld(count: stillHeld)
        }

        try turns.release(turn)
        focusRecovery?.endHold()

        posted.removeAll()
        observer?.conclude()
        observer         = nil
        observationSoFar = nil
    }

    /// send drives a declarative Shortcut: it resolves the key, posts the one
    /// Command that carries it, and records which layout answered.
    ///
    /// The layout is read **only** for a Shortcut written as a character, which
    /// is the only kind that needs one. A position, an arrow or an escape, means
    /// the same thing on every layout, so asking the system what is installed
    /// could only cost a `UCKeyTranslate` sweep and introduce an error.
    ///
    /// A release of a character the Turn is already holding does not resolve
    /// again: it lifts the key that actually went down. The person can change
    /// keyboard layout between the press and the release, and on a Dvorak
    /// machine c is not where a QWERTY layout puts it, so resolving twice would
    /// lift a key that was never pressed and leave the pressed one down.
    @discardableResult
    public nonisolated func send(
        _ shortcut : Shortcut,
        phase      : KeyPhase = .press,
        observation: SeatObservationReference,
        turn       : Turn,
        platform   : (any InputPlatform)? = nil
    ) async throws -> InputReceipt {

        let needsLayout: Bool = if case .character = shortcut.key { true } else { false }
        let layout = needsLayout ? await KeyboardLayoutReader.current() : nil
        let resolved = try ShortcutResolution.resolve(
            shortcut,
            phase    : phase,
            layout   : layout,
            owner    : turn.correlationID,
            processID: await keyboardRecipientProcessID(of: observation)
                ?? observation.recipient.processID
        )
        return try await send(
            resolved.command,
            observation     : observation,
            turn            : turn,
            platform        : platform,
            layoutGeneration: resolved.layoutGeneration
        )
    }

    /// The process this observation's keys were last posted to, nil when none
    /// has been resolved for its surface yet.
    ///
    /// It is what a release of a held character has to be asked of: the press
    /// was recorded under the recipient's PID, and asking the surface's own
    /// process instead would find nothing held and resolve the character again
    /// under whatever layout is installed now. The first Command on a surface
    /// is a press, which holds nothing yet, so falling back to the observation's
    /// own recipient there costs the resolution nothing.
    private func keyboardRecipientProcessID(
        of observation: SeatObservationReference
    ) -> Int32? {
        guard let sheet = observation.role.attachedSheet else { return nil }
        return keyboardRecipients[sheet.windowNumber]
    }

    /// The pieces a string is delivered in, as Commands, decided and never sent.
    ///
    /// It replaces the old `sendText`, which cut a string into chunks and posted
    /// all of them from one observation. The cutting is the only part that was
    /// ever pure, so it stays and the sending does not: the consumer sends each
    /// Command against its own new observation, and decides between them. A
    /// single `insertText` is one atomic Command and is not cut per character.
    ///
    /// Every cut falls on a grapheme cluster boundary, so no piece carries half
    /// of a joined emoji, and a single cluster too large for one piece is
    /// refused here rather than split.
    public static func textCommands(
        of text: String,
        mode   : TextDeliveryMode = .inserted,
        limits : TextDeliveryLimits = .measured
    ) throws -> [InputCommand] {

        let chunks = try TextChunking.chunks(
            of              : text,
            maximumClusters : limits.maximumClusters,
            maximumCodeUnits: limits.maximumCodeUnits
        )
        return chunks.map { mode == .typed ? InputCommand.text($0) : InputCommand.insertText($0) }
    }

    /// Runs qualified native composition in one Turn, with a fresh observation and
    /// confirmation for every physical key. Preparation is owned by the scope,
    /// not by individual Receipts. Restoration closes the native context; it
    /// does not promise to discard marked text or undo committed edits.
    public func withNativeTextInput(
        observation: SeatObservationReference,
        turn       : Turn,
        within     : Duration = .seconds(3),
        operation  : @escaping @MainActor @Sendable () async throws -> Void
    ) async throws -> InputCleanupResult {
        guard nativeTextInputContext == nil, Self.nativeTextInputID == nil,
              menuContext == nil, !actionInFlight else {
            throw InputFailure.nativeTextInputRefused(.contextActive)
        }
        let window = try admitOrdinary(observation)
        var trace = InputTraceIdentity.submitted(
            command      : .key(virtualKey: 0, text: ""),
            window       : window.reference,
            correlationID: turn.correlationID
        )
        let record = try preflight(
            window,
            turn        : turn,
            traceContext: &trace
        )
        guard nativeTextInputIsQualified(on: record.platform),
              let preparing = sender as? any NativeTextInputPreparing
        else { throw InputFailure.nativeTextInputRefused(.unsupported) }
        let endpoint = try inputEndpoint(
            for: .key(
                virtualKey: 0,
                text      : ""
            ),
            observation: observation
        )?.endpoint
        let isOwnSurface = endpoint == nil || (
            endpoint?.identity == window.reference.identity
                && endpoint?.relation == .logicalSurface
                && (endpoint?.evidence == .attestedSurfaceItself
                    || (record.platform is ChromiumPlatform
                        && endpoint?.evidence == .windowlessContentOfSurface))
        )
        guard attestedModalSurface(for: observation) == nil,
              isOwnSurface
        else { throw InputFailure.nativeTextInputRefused(.unsupported) }
        guard heldKeyCount(of: turn) == 0 else { throw InputFailure.nativeTextInputRefused(.commandUnsupported) }
        let id = UUID()
        nativeTextInputContext = (
            window: window.reference,
            turn  : turn,
            id    : id
        )
        let previous = state
        actionInFlight = true
        transition(to: .acting, reason: .requested)
        defer {
            nativeTextInputContext = nil
            actionInFlight = false
            restoreActionState(previous, reason: .requested)
        }
        // Preparation can change focus and pixels. The entry observation cannot
        // be reused for the body's first Command.
        noteObservationConsumed()
        do {
            let cleanup = try await preparing.withNativeTextInput(
                to           : window.reference,
                correlationID: turn.correlationID,
                within       : within,
                operation    : { @MainActor in
                    self.actionInFlight = false
                    self.restoreActionState(previous, reason: .requested)
                    try await Self.$nativeTextInputID.withValue(id) {
                        try await operation()
                    }
                }
            )
            if cleanup.needsRecovery { report([.preparationNotRestored]) }
            return cleanup
        } catch {
            if let failure = error as? NativeTextInputFailure, failure.cleanup.needsRecovery {
                report([.preparationNotRestored])
            } else if let failure = error as? InputPreparationFailure,
                      failure.progress.neededRecovery != nil {
                report([.preparationNotRestored])
            }
            throw error
        }
    }

    /// Removed in the observation cutover, not deprecated: it posted every chunk
    /// of a string from one observation and one decision, which is the blind
    /// composed send the new contract forbids.
    ///
    /// Migration: `AgentSeat.textCommands(of:mode:limits:)` cuts the string, and
    /// the consumer sends each Command against its own new observation, deciding
    /// between them. A single `insertText` stays one atomic Command.
    @available(
        *, unavailable,
        message: "Use textCommands(of:mode:limits:), then send(_:observation:turn:platform:) per Command"
    )
    public nonisolated func sendText(
        _ text  : String,
        to window: AdoptedWindow,
        turn    : Turn,
        mode    : TextDeliveryMode = .inserted,
        limits  : TextDeliveryLimits = .measured,
        platform: (any InputPlatform)? = nil
    ) async throws -> TextDeliveryOutcome {
        fatalError("unavailable")
    }

    /// Reports the keys the kit is still holding when there is no longer a Turn
    /// to refuse.
    ///
    /// `release` refuses a Turn that still holds keys, which covers the ordinary
    /// case. This is the other one: a seat going terminal, where every Turn is
    /// about to be failed and nobody will ever send the missing key ups. It is
    /// reported and never thrown, for the same reason `preparationNotRestored`
    /// is: the key downs already went out, and an error at this point has nobody
    /// left to hand it to.
    ///
    /// The event is yielded straight to the channel rather than through
    /// `report`, which runs the state machine: this runs immediately before a
    /// forced transition to `failed`, and a second opinion about the next state
    /// is the last thing that path needs.
    private func reportStrandedKeys() {
        let stranded = recipientProcessIDs.reduce(0) { total, processID in
            total + KeyHold.shared.releaseEveryOwner(processID: processID).count
        }
        guard stranded > 0 else { return }
        eventChannel.yield(.issueDetected(.keysNotReleased, cause: nil))
    }

    /// Every process this seat's Commands can have left a key down in: the
    /// adopted windows' own, and the remote recipients keys were posted to.
    ///
    /// The second set is what the adopted windows do not answer for. A panel's
    /// content belongs to a service, its PID is in no record of the session,
    /// and a key held there is as real as one held in the driven application.
    private var recipientProcessIDs: Set<Int32> {
        session.processIDs.union(keyboardRecipients.values)
    }

    /// How many keys **this Turn** is still holding across every process this
    /// seat can have posted to, which includes the remote recipients and not
    /// only the adopted windows' own.
    ///
    /// Scoped to the Turn and not to the process: another holder's keys on the
    /// same application are that holder's to release, and refusing this release
    /// for them would make one Turn unable to finish because another one is
    /// mid-gesture. The processes are a Set because two windows of one
    /// application are one process and would otherwise be counted twice.
    private func heldKeyCount(of turn: Turn) -> Int {
        recipientProcessIDs.reduce(0) { total, processID in
            total + KeyHold.shared.held(
                owner    : turn.correlationID,
                processID: processID
            ).count
        }
    }

    // MARK: The windows

    /// adopt moves a window onto the Virtual Display and confirms it is there.
    ///
    /// The move is `AXPosition` and the confirmation is **two window server
    /// readings**, never Accessibility: an application publishes its own
    /// geometry and the server's at different moments, so one of them alone is
    /// not evidence that the window came to rest.
    ///
    /// `title` feeds the structural recovery path only; empty turns that path
    /// off, and a recovery then refuses rather than guessing.
    ///
    /// There are two entries, this one and `integrateDetectedWindow`, and what
    /// they differ in is admission and nothing else: the transaction below, the
    /// move it performs and the verified rollback behind it are shared.
    @discardableResult
    public func adopt(
        _ window: WindowReference,
        platform: any InputPlatform = ChromiumPlatform(),
        title   : String = ""
    ) async throws -> AdoptedWindow {

        try Task.checkCancellation()
        try checkIdentityIsAttested(of: window)
        guard mayAdmit(window) else { throw SessionFailure.seatNotReady(state) }

        return try await adoptionTransaction(
            window,
            platform: platform,
            title   : title,
            reason  : .adopted
        )
    }

    /// integrateDetectedWindow brings a window somebody else detected into the
    /// seat, at a command boundary. It is the interface MW-02's watcher uses,
    /// and it exists so that the watcher never calls `adopt` from a callback.
    ///
    /// A new window of the target appears exactly when the target is being
    /// driven, so a detection routinely arrives while the state is `.acting` or
    /// `.waiting`. `adopt` would answer `seatNotReady` and the window would be
    /// dropped; widening `acceptsCommands` would instead let an adoption write
    /// geometry that a Command in flight is already consuming. So this waits for
    /// the boundary, and only then holds input closed with `.windowTransfer`
    /// across the move: closing the gate first would refuse the next Command of
    /// a sequence already running, which is a split Command.
    ///
    /// It posts nothing and repeats nothing. In particular it never repeats the
    /// Command that opened the window it is adopting.
    ///
    /// `takenInPlace` is the window that was born on the Virtual Display: it is
    /// already where an adoption would put it, so the transaction owns it where
    /// it stands and writes no geometry at all.
    @discardableResult
    package func integrateDetectedWindow(
        _ window       : WindowReference,
        platform       : any InputPlatform = ChromiumPlatform(),
        title          : String = "",
        restoringTo    : CGRect? = nil,
        takenInPlace   : Bool = false,
        within deadline: Duration = .seconds(2)
    ) async throws -> AdoptedWindow {

        try Task.checkCancellation()
        try checkIdentityIsAttested(of: window)

        guard await awaitCommandBoundary(within: deadline), mayAdmit(window) else {
            throw SessionFailure.seatNotReady(state)
        }
        // A selected successor that qualified this narrow admission supersedes
        // the recovery of the hidden predecessor before the transaction starts.
        // Every other detected window leaves that recovery untouched.
        supersedeLostHostRecovery(for: window)
        beginTransfer()
        defer { endTransfer() }

        return try await adoptionTransaction(
            window,
            platform    : platform,
            title       : title,
            reason      : .detected,
            restoringTo : restoringTo,
            takenInPlace: takenInPlace
        )
    }

    /// A raw PID and Window ID are an unverified compatibility value and cannot
    /// authorize anything, adoption included.
    private func checkIdentityIsAttested(of window: WindowReference) throws {
        guard window.identity != nil else {
            throw InputFailure.windowIdentityUnverified(
                processID   : window.processID,
                windowNumber: window.windowNumber
            )
        }
    }

    /// Whether an adoption may start right now. It is a reading and not a
    /// refusal so that the detected-window entry can wait for it to become
    /// true instead of failing on the first look.
    private func mayAdmit(_ window: WindowReference) -> Bool {
        !isTearingDown && !adoptionInFlight && pendingAdoptions.isEmpty
            // A selected application-modal surface can be already inside the
            // seat while the direct containment effector has suspended input.
            // Its own detected-window transaction is the qualified way to
            // establish the missing held record; admitting that one exact
            // surface does not reopen ordinary command admission.
            && (state == .unavailable || state.acceptsCommands
                || selectedContainmentRecoveryMayAdmit(window)
                || selectedModalRecoveryMayAdmit(window))
            && session[window.windowNumber] == nil
    }

    private func selectedContainmentRecoveryMayAdmit(_ window: WindowReference) -> Bool {
        guard containmentOnlyFollowWait,
              let identity = window.identity,
              selectionKit.selected?.surface == identity
        else { return false }
        return sensing.virtualDisplayBounds.contains(window.frame)
    }

    /// A newly selected, attested surface may replace a host that disappeared
    /// while opening it. Native `NSOpenPanel.begin` reports `AXStandardWindow`
    /// with `AXModal = 0`, so this is deliberately about the exact selected
    /// successor rather than an inferred application-modal role. Taking that
    /// one surface through the normal ownership transaction is safe; admitting
    /// a general recovery candidate would move a window while a real focus or
    /// user-intent stop is in force.
    private func selectedModalRecoveryMayAdmit(_ window: WindowReference) -> Bool {
        guard state == .recovering,
              recoveryTrigger == [.windowUnavailable],
              let identity = window.identity,
              selectionKit.selected?.surface == identity,
              let member = assignmentKit.inventory.surfaces[identity.windowNumber],
              member.identity == identity,
              member.origin == .bornDuringAssignment,
              !sensing.userMayBeSwitchingApplications,
              focusRecovery?.isRestoring != true,
              !inputPauseReasons.contains(.focusRecovery),
              !inputPauseReasons.contains(.focusRecoveryStopped)
        else { return false }
        return session[window.windowNumber]?.window.reference.identity != identity
    }

    /// The selected, attested surface is the only successor allowed to
    /// supersede a recovery of a hidden host. The recovery was about a window
    /// that no longer exists in the application scope; leaving its task alive
    /// after the panel has become the exact selected surface lets it later fail
    /// the seat for that obsolete host.
    func supersedeLostHostRecovery(for window: WindowReference) {
        guard selectedModalRecoveryMayAdmit(window), recoveryTrigger == [.windowUnavailable] else { return }
        recoveryTask?.cancel()
        recoveryTask     = nil
        recoveryEpisode &+= 1
        recoveryTrigger  = []
        recoveryProgress = nil
    }

    /// MW-03: takes a window out of native fullscreen so that it can be moved
    /// at all, and answers with the **re-read** reference and whether it was in
    /// fullscreen to begin with.
    ///
    /// A window that is not in native fullscreen passes straight through. A
    /// maximised window is not this case and is not touched: the two have the
    /// identical rectangle, and only `AXFullScreen` tells them apart.
    ///
    /// Three refusals, all of them measured, all of them leaving the window
    /// exactly where it is:
    ///
    /// - the experiment is off, which is the default;
    /// - `AXFullScreen` is unreadable or read only, which is **not supported**
    ///   rather than a retry, and varies per window inside one application;
    /// - the window's Space is still the one on screen, where leaving costs the
    ///   person 437 to 875 ms of their display instead of 36 to 100 ms.
    ///
    /// The frame that comes back is the accessibility body and not the window
    /// server's rectangle. With Stage Manager on the server publishes a
    /// thumbnail for a window it has stashed, and centring the Virtual Display
    /// placement on a thumbnail's size is how a window ends up hanging off the
    /// edge; the body answers the real normal frame in both Stage Manager
    /// states.
    private func leaveFullScreenForAdoption(
        _ window: WindowReference
    ) async throws -> (window: WindowReference, wasFullScreen: Bool) {

        guard let reading = try? placing.fullScreen(of: window), reading.isNativeFullScreen else {
            return (window, false)
        }
        guard transfersFullScreenWindows else {
            throw SessionFailure.fullScreenTransferDisabled(windowNumber: window.windowNumber)
        }
        guard case .writable = reading else {
            throw reading.value == nil
                ? DisplayFailure.fullScreenStateUnreadable(
                    windowNumber: window.windowNumber, code: .attributeUnsupported)
                : DisplayFailure.fullScreenNotSettable(windowNumber: window.windowNumber)
        }
        guard !placing.spaceIsOnScreen(for: window) else {
            throw DisplayFailure.fullScreenSpaceStillOnScreen(windowNumber: window.windowNumber)
        }

        try placing.requestFullScreen(false, of: window)
        do {
            let settled = try await placing.awaitFullScreen(false, of: window)
            let body    = try? placing.frame(of: settled)
            return (body.map { settled.replacingFrame($0) } ?? settled, true)
        } catch {
            // The known hole, said out loud rather than papered over: the write
            // was accepted, so the window can leave fullscreen a moment after
            // this wait gave up or was cancelled, and there is no record yet to
            // hang that on. Everything after this point is inside the
            // transaction, where the handle carries `wasFullScreen`.
            let left = (try? placing.fullScreen(of: window))?.value == false
            Self.log.error("""
                window \(window.windowNumber, privacy: .public) was asked to leave fullscreen and \
                the transition was not observed: \(String(describing: error), privacy: .public). \
                It is out of fullscreen now: \(left, privacy: .public)
                """)
            throw error
        }
    }

    /// Which display a rectangle belongs to, so that a return names a display
    /// instead of inferring one. `nil` when no display contains its centre,
    /// which a window parked off the edge legitimately is.
    private func displayContaining(_ frame: CGRect) -> CGDirectDisplayID? {
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        var count  = UInt32.zero
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var identifiers = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &identifiers, &count) == .success else { return nil }
        return identifiers.prefix(Int(count)).first { CGDisplayBounds($0).contains(centre) }
    }

    /// The window server's rectangle for a window that is still at the frame
    /// it is owed, or `nil` when the server cannot be shown to be describing
    /// that frame at all.
    ///
    /// The guard is the whole value of the reading: a Stage Manager thumbnail
    /// is a fraction of the window's size, measured at 90 by 97 points and at
    /// 120 by 121 rather than at any one number, and a window shrunk to fit the
    /// display is owed a frame it no longer has, and in both cases the server's
    /// rectangle is not the one a return has to land on. `crossSourceTolerance`
    /// is the right comparison here because this is the cross-source question,
    /// and the comparison is always against the window's own size, never a
    /// literal thumbnail size.
    private func serverFrameOwed(_ owed: CGRect, of window: WindowReference) -> CGRect? {
        guard let reading = sensing.windowGeometry(of: window.windowNumber),
              reading.hasSameIdentity(as: window),
              VirtualWindowPlacementCheck.framesMatch(
                  reading.frame,
                  owed,
                  tolerance: VirtualWindowPlacementCheck.crossSourceTolerance
              )
        else { return nil }
        return reading.frame
    }

    /// freshQtAdoptionBody records the body Qt exposes when ownership begins.
    /// Display creation and Stage Manager may settle a previously discovered
    /// window elsewhere. Its old frame is then an invalid return destination.
    /// WindowServer identity brackets the AX read; a thumbnail never supplies
    /// the body size. Missing AX geometry retains the existing placement path.
    private func freshQtAdoptionBody(for window: WindowReference) throws -> WindowReference {
        guard let before = sensing.windowGeometry(of: window.windowNumber) else {
            throw SeatInterruption(issues: [.windowUnavailable])
        }
        guard before.hasSameIdentity(as: window) else {
            throw SeatInterruption(issues: [.identityChanged])
        }
        guard let body = try placing.frame(of: window) else { return window }
        guard rectangleIsUsable(body) else {
            throw SeatInterruption(issues: [.windowUnavailable])
        }
        guard let after = sensing.windowGeometry(of: window.windowNumber) else {
            throw SeatInterruption(issues: [.windowUnavailable])
        }
        guard after.hasSameIdentity(as: window) else {
            throw SeatInterruption(issues: [.identityChanged])
        }
        return window.replacingFrame(body)
    }

    private func adoptionTransaction(
        _ inbound  : WindowReference,
        platform   : any InputPlatform,
        title      : String,
        reason     : SeatTargetChange,
        /// What the window is owed on its return, when that is not the frame it
        /// is being adopted from: a window shrunk to fit the Virtual Display is
        /// adopted at its new size and still owes the person the old one.
        restoringTo: CGRect? = nil,
        /// True for a window that is already inside the Virtual Display, which
        /// is taken in where it stands: nothing is written, and the two
        /// readings that confirm every adoption confirm this one too.
        takenInPlace: Bool = false
    ) async throws -> AdoptedWindow {

        // The fullscreen exit happens before anything is recorded, because the
        // normal frame this whole transaction is written in terms of does not
        // exist until the window has left fullscreen.
        let prepared      = try await leaveFullScreenForAdoption(inbound)
        var window        = prepared.window
        let wasFullScreen = prepared.wasFullScreen
        if platform is QtPlatform, !takenInPlace, restoringTo == nil, !wasFullScreen {
            window = try freshQtAdoptionBody(for: window)
        }
        let homeDisplay   = displayContaining(window.frame)
        let bounds        = sensing.virtualDisplayBounds

        // A window larger than the display is adapted, not refused, and still
        // owes the frame it arrived at. Beside the fullscreen exit because it
        // is the same preparation: the frame the transaction is written in.
        var adapted: CGRect?
        if !takenInPlace, restoringTo == nil,
           window.frame.width > bounds.width || window.frame.height > bounds.height {
            try checkAdoptionMayContinue()
            guard let shrunk = shrinkToFit(window, body: window.frame, within: bounds) else {
                throw SessionFailure.windowDoesNotFit(
                    windowNumber: window.windowNumber,
                    size        : window.frame.size,
                    bounds      : bounds.size
                )
            }
            adapted = window.frame
            window  = window.replacingFrame(shrunk)
        }

        lastAdoptionFailure = nil
        adoptionInFlight = true
        defer {
            adoptionInFlight = false
            adoptingPlacementIdentity = nil
            let waiting = adoptionWaiters
            adoptionWaiters.removeAll()
            for waiter in waiting { waiter.resume() }
        }
        let previous = state
        transition(to: .starting, reason: .requested)

        // Centred, then clamped so the whole window fits: the frame comes from
        // the consumer's observation layer, and a window Stage Manager stashed
        // reports its full size to itself and a thumbnail to the window server.
        // Centring a thumbnail's size and then staging it is how a window ends
        // up hanging off the bottom of the display, which the confirmation then
        // refuses; clamping costs one `min` and removes the whole class.
        let origin = takenInPlace ? window.frame.origin : CGPoint(
            x: min(max(bounds.minX, bounds.midX - window.frame.width  / 2),
                   max(bounds.minX, bounds.maxX - window.frame.width)),
            y: min(max(bounds.minY, bounds.midY - window.frame.height / 2),
                   max(bounds.minY, bounds.maxY - window.frame.height))
        )

        // Both sources of the same window, in the same place, before anything
        // moves: the return is verified against the window server, so the
        // server's own rectangle is what it has to be compared with.
        let owed              = restoringTo ?? adapted ?? window.frame
        let originalOnServer  = serverFrameOwed(owed, of: window)
        // Read here, while the tree still holds the relation: a sheet has no
        // destination of its own and the frame it was born at is not one.
        let owesNoReturn = window.identity.map {
            selectionKit.attachedHost(of: $0) != nil
        } ?? false

        var pending = AdoptedWindow(
            reference          : window,
            originalFrame      : owed,
            title              : title,
            originalDisplayID  : homeDisplay,
            wasFullScreen      : wasFullScreen,
            originalServerFrame: originalOnServer,
            owesNoReturn       : owesNoReturn
        )
        pendingAdoptions[window.windowNumber] = pending
        adoptionRestorations[window.windowNumber] = nil
        do {
            let beforeMovement = sensing.windowGeometry(of: window.windowNumber)
            let wasStashed = beforeMovement.map {
                $0.hasSameIdentity(as: window) && SeatWindowSession.readsAsThumbnail(
                    serverSize: $0.frame.size,
                    fullSize  : window.frame.size
                )
            } ?? false
            // A window born on the display is already at `origin`, so the one
            // write this transaction makes is the one it does not need.
            if !takenInPlace {
                adoptingPlacementIdentity = window.identity
                try placing.move(window, to: origin)
            }
            try checkAdoptionMayContinue()

            let confirmation = try await confirmPlacement(
                of            : window,
                expectedOrigin: origin,
                within        : bounds,
                takenInPlace  : takenInPlace,
                wasStashed    : wasStashed
            )
            let placed = confirmation.reference
            if takenInPlace, restoringTo == nil, !wasFullScreen,
               confirmation.body != window.frame {
                // No physical frame was borrowed for this in-place adoption.
                // The application's settled AX body, bracketed by agreeing
                // server readings, is its return destination. Retaining the
                // transient birth size would invent a resize obligation.
                pending = AdoptedWindow(
                    reference          : placed,
                    originalFrame      : confirmation.body,
                    title              : pending.title,
                    originalDisplayID  : pending.originalDisplayID,
                    wasFullScreen      : pending.wasFullScreen,
                    originalServerFrame: placed.frame,
                    owesNoReturn       : pending.owesNoReturn
                )
                pendingAdoptions[window.windowNumber] = pending
            }
            let record = WindowRecord(
                window  : pending.withReference(placed),
                platform: platform,
                // Staged or stashed is read off the size: a stashed window reads
                // as a thumbnail of no fixed size, 90 by 97 points and 120 by
                // 121 when measured, so the comparison is against the window's
                // own size and never a literal. `placed` is the window
                // server's and `confirmation.body` the confirmed body, so use
                // the wider tolerance: MarkEdit's 3 pt read as stashed.
                isStaged: SeatWindowSession.readsAsStaged(
                    serverSize: placed.frame.size,
                    fullSize  : confirmation.body.size
                ),
                operationalSize: confirmation.body.size
            )

            try checkAdoptionMayContinue()
            pendingAdoptions[window.windowNumber] = nil
            session.hold(record)
            hiddenReturns?.forgive(record.window.id)
            if record.isStaged { stagedWindowNumber = record.window.id }
            windowInventory.clearAttempts(of: record.window.id)
            refreshWindowFollowing()

            transition(to: previous == .degraded ? .degraded : .ready, reason: .requested)
            // The instance is handed over to the assignment nucleus here, at the
            // one moment the seat knows it is driving it, and the observation of
            // whatever was current before stops being current with the target.
            takeOverInstance(of: placed)

            guard adoptionTakesTheTarget(reason) else {
                eventChannel.yield(
                    .windowAdoptedNotTargeted(
                        window: placed,
                        target: session.currentTargetNumber
                    )
                )
                // The reading this path used to take on its way to the nucleus
                // is still taken: a surface seen once is not a verified member.
                foldCurrentReading()
                publishCoherentState()
                return record.window
            }
            guard session.currentTargetNumber != record.window.id else {
                // Already the target, so there is no move to make and none to
                // announce. One move, one event.
                publishCoherentState()
                return record.window
            }
            let displaced = session.currentTargetNumber
            session.makeCurrent(record.window.id)
            seatGuard = SeatGuard(
                target       : placed,
                displayID    : displayID,
                displayBounds: bounds
            )
            observationIssuer.invalidate(.targetChanged)
            outstandingGeometry = nil
            selectExplicitly(placed)
            eventChannel.yield(.targetChanged(from: displaced, to: placed, reason: reason))
            publishCoherentState()
            return record.window

        } catch {
            let observed: CGRect?
            if case .placementNotConfirmed(_, let lastFrame) = error as? DisplayFailure { observed = lastFrame }
            else { observed = sensing.windowGeometry(of: window.windowNumber)?.frame }
            let rollback = await restorePendingAdoption(pending)
                ?? (outcome: .refused, error: nil)
            let restoration = rollback.outcome
            adoptionRestorations[window.windowNumber] = restoration
            if restoration == .returned || restoration == .vanished {
                pendingAdoptions[window.windowNumber] = nil
            }
            lastAdoptionFailure = WindowAdoptionFailure(
                window: window,
                requestedFrame: CGRect(origin: origin, size: window.frame.size),
                virtualBounds: bounds,
                lastObservedFrame: observed,
                cause: error,
                restoration: restoration,
                restorationError: rollback.error
            )
            if state != .failed, !isTearingDown {
                transition(to: restoration == .refused ? .failed : previous, reason: .cancelled)
                if state == .failed { turns.failAll(with: SessionFailure.seatNotReady(.failed)) }
            }
            throw error
        }
    }

    /// Whether the window an adoption has just recorded becomes the operating
    /// target, or is only held.
    ///
    /// The consumer's own `adopt` always takes it: the consumer chose that
    /// window and the seat is to drive it. **A detection never takes it**, and
    /// that is the rule rather than a threshold, a level, a subrole or a child
    /// count, because three of those were tried and all three failed live.
    ///
    /// What defeated them is the traffic light overlay macOS draws over every
    /// window it raises: 66 by 20 points, `AXWindow` with subrole `AXDialog`,
    /// position settable, `AXRaise` supported, a new Window ID each time, born
    /// with no accessibility children and measured twice gaining one within 18
    /// ms. It became the target, invalidated the agent's outstanding
    /// observation, retargeted its capture and was destroyed a moment later. No
    /// readable attribute separates it from a dialog a person operates, so
    /// nothing here can decide, and the seat stops deciding.
    ///
    /// The window is still adopted: held, handed to the assignment nucleus,
    /// contained and released through the same lifecycle. The consumer hears
    /// about it as `windowAdoptedNotTargeted` and moves the target with
    /// `switchTarget(to:)` if it wants it. The only move the seat still makes
    /// on its own is the takeover after the current target is proved gone.
    private func adoptionTakesTheTarget(_ reason: SeatTargetChange) -> Bool {
        reason != .detected
    }

    /// stage brings a stashed window back to full size on the Virtual Display,
    /// without activating its application.
    ///
    /// The primitive is `kAXRaiseAction`, measured on 26A5425a: it brings a
    /// stashed window back to full size, Stage Manager stashes whatever was on
    /// stage before it, and `NSApp.isActive` and `isKeyWindow` both stay false
    /// in the target. It costs the animation, half a second on Chrome, which is
    /// why nothing may be posted until the confirmation arrives.
    @discardableResult
    public func stage(_ window: AdoptedWindow) async throws -> AdoptedWindow {

        guard let record = session[window.id] else {
            throw SessionFailure.windowNotAdopted(windowNumber: window.id)
        }

        let staged: WindowReference
        do {
            staged = try await placing.stage(
                record.window.reference,
                // What full size means for this window is the size the seat
                // took it in at, never what it is owed on its return: a window
                // shrunk to fit the Virtual Display owes the person the frame
                // it had before, and waiting for that frame here is waiting for
                // a size the window will not have until it goes home. It is the
                // same reading `refreshStaging` compares against, and the two
                // disagreeing is what left a shrunk window unstageable.
                expectedSize: record.operationalSize,
                within      : sensing.virtualDisplayBounds
            )
        } catch {
            report([.windowStashed])
            throw error
        }

        // The record is read again after the await, and it is not the one that
        // was captured before it: the animation costs half a second, and a
        // window released or replaced during it must not be written back from a
        // value that describes a window the seat no longer holds.
        guard var current = session[window.id],
              current.window.reference.hasSameIdentity(as: record.window.reference) else {
            throw SessionFailure.windowNotAdopted(windowNumber: window.id)
        }

        current.isStaged = true
        current.window   = current.window.withReference(staged)
        session[window.id] = current
        stagedWindowNumber = window.id

        // Which of the others is still on stage is read back, never assumed:
        // several adopted windows stay visible together, so the last window
        // `stage` was called for is not evidence that the rest became
        // thumbnails. An unreadable window keeps the value it had.
        session.refreshStaging(besides: window.id) { sensing.windowGeometry(of: $0)?.frame.size }

        if let existing = seatGuard, existing.target.hasSameIdentity(as: staged) {
            seatGuard = SeatGuard(
                target       : staged,
                displayID    : existing.displayID,
                displayBounds: existing.displayBounds
            )
        }

        return current.window
    }

    /// release lets a window go: back to its original frame in the User Seat by
    /// default, or left stashed on the virtual display.
    ///
    /// Closing the window is not the kit's business: a window is the person's,
    /// and a command that closes one is the caller's Command. A release of a
    /// window that has vanished is a no-op the event stream reports.
    @discardableResult
    public func release(
        _ window: AdoptedWindow,
        _ mode  : ReleaseMode = .returnToUserSeat
    ) async -> WindowReleaseOutcome {

        if let context = nativeTextInputContext, context.window.windowNumber == window.id,
           let preparing = sender as? any NativeTextInputPreparing {
            let cleanup = await preparing.cancelNativeTextInput(correlationID: context.turn.correlationID)
            if cleanup.needsRecovery { report([.preparationNotRestored]) }
        }
        if stagedWindowNumber == window.id { stagedWindowNumber = nil }

        // The return is a placement transition like the adoption, and the
        // watcher has to know: a window on its way home passes through frames
        // that are neither the virtual one nor the home one, and the follow
        // pass would read them as an escape and start pulling it back while
        // this is still writing. The pause ends when this transfer ends, and
        // the gate stays closed until every other pending reason ends too.
        beginTransfer()
        let outcome = await returnToUserSeat(window, mode)
        endTransfer()
        let successor = forgetRecord(window.id)
        refreshWindowFollowing()
        noteSurfaceGone(window.id)
        releaseLedger[window.id] = outcome
        eventChannel.yield(.windowReleased(windowNumber: window.id, outcome: outcome))

        // An explicit release is one of the two proofs that the target is gone,
        // and the only place other than an exhausted recovery where a
        // predecessor is chosen. A teardown chooses none: every window is on
        // its way out and restaging one would be work against the person.
        await takeOverAfterLostTarget(successor)
        return outcome
    }

    /// forgetRecord lets go of the record of one window and moves the guard
    /// with it: onto the target that takes over, or off the window entirely
    /// when nothing does.
    ///
    /// Every release of a record comes through here because the guard is what
    /// the heartbeat reads while the seat is `waiting`. Left on a window the
    /// seat no longer held, it kept watching an application the consumer had
    /// already given back, and the consumer quitting that application read as
    /// `processUnavailable` and failed the seat for good.
    ///
    /// A seat still waiting with no guard has nothing left that could end the
    /// wait, so it goes back to `ready`, or `degraded` if it came from there,
    /// as the release the caller asked for. A paused focus recovery is the one
    /// exception: that wait is its own, and its verified end or its stop is
    /// what brings the seat out of it.
    @discardableResult
    func forgetRecord(_ windowNumber: Int) -> Int? {

        let successor = session.forget(windowNumber)
        // A Command moves the guard onto the window it went to, which need not
        // be the target: a panel or a dialog closing then leaves the target it
        // was opened from, and the guard goes back to it.
        if let next = successor ?? (seatGuard?.target.windowNumber == windowNumber
                                        ? session.currentTargetNumber : nil),
           let record = session[next] {
            seatGuard = SeatGuard(
                target       : record.window.reference,
                displayID    : displayID,
                displayBounds: sensing.virtualDisplayBounds
            )
        } else if seatGuard?.target.windowNumber == windowNumber {
            seatGuard = nil
        }
        if state == .waiting, seatGuard == nil, focusRecovery?.isPaused != true {
            transition(
                to    : wasDegradedBeforeRecovery ? .degraded : .ready,
                reason: .requested
            )
        }
        return successor
    }

    /// Puts the predecessor back on stage and makes it the target again, after
    /// the current one was proved gone.
    private func takeOverAfterLostTarget(_ successor: Int?) async {

        // A coordinated release is a teardown of the assignment: every window
        // is on its way out, so staging one of them again is work against the
        // person for exactly as long as it takes to release it too.
        guard !isTearingDown, !isReleasingAssignment,
              let successor, session[successor] != nil else { return }
        do { _ = try await transferTarget(to: successor, reason: .predecessor) }
        catch {
            Self.log.error("""
                the predecessor at Window ID \(successor, privacy: .public) could not take over: \
                \(String(describing: error), privacy: .public)
                """)
        }
    }

    // MARK: The assigned application

    /// releaseAssignedApplication gives the Assigned Application back: the
    /// consumer has finished with this instance, and the seat may be entrusted
    /// with another one.
    ///
    /// ## Why it has to be said rather than inferred
    ///
    /// `AssignmentEnd` is a closed set of three, and neither the end of a Turn
    /// nor the last window closing is in it: a Turn is exclusive use between two
    /// safe points, and an application between two documents legitimately has
    /// nothing on screen. So the only thing that means "I have finished with
    /// this application" is the consumer saying it, and this is where it is
    /// said. Nothing here counts windows.
    ///
    /// After it returns the next adoption hands its own instance over:
    /// `AssignmentLifecycle.accept` refuses only while something is assigned or
    /// the seat is stopped, and its generation separates the two assignments so
    /// that a record made under the first authorises nothing under the second.
    ///
    /// ## What it refuses
    ///
    /// Everything the seat still has a claim on, each before any effect:
    /// nothing is released, invalidated or moved by a refusal. An application
    /// cannot be given back while a Turn, a Command, an adoption, a transfer or
    /// an unverified focus restore is in flight, while a return owed by an
    /// earlier assignment is unfinished, or while the seat still holds windows
    /// of the instance. That last one is what keeps the handback's own return
    /// obligation empty: `SeatAssignmentKit.release` turns the surfaces the seat
    /// owes a return into pending returns, and after the assignment has ended
    /// nothing can complete them, so a successful handback is one that leaves
    /// none. The two read the one claim, which is why neither of them counts
    /// members: a window of the instance the seat never touched is not held, and
    /// an application that has one open, which Finder always does, is given back
    /// like any other.
    ///
    /// ## The invalidation reason
    ///
    /// `.lifecycleChanged` and not a reason of its own: its doc is "the
    /// assignment ended or another instance was handed over", which is exactly
    /// what this is, and which of the three ends it was is already
    /// `AssignmentLifecycle.lastEnd`, answered as `.explicitRelease`.
    public func releaseAssignedApplication() throws {

        guard let assignment = assignmentKit.lifecycle.current else {
            throw SessionFailure.applicationNotAssigned
        }
        if let use = assignmentUseInFlight() {
            throw SessionFailure.assignmentStillInUse(use)
        }
        let outstanding = assignmentKit.restitution.outstanding
        guard outstanding.isEmpty else {
            throw SessionFailure.returnsStillOutstanding(windowNumbers: outstanding)
        }
        let held = windowsStillHeld(of: assignment.instance)
        guard held.isEmpty else {
            throw SessionFailure.assignedWindowsStillHeld(windowNumbers: held)
        }

        // Routed through the one coordinated end rather than duplicated: it
        // revokes input authority, invalidates the observation and clears both.
        endAssignmentAndObservation(reason: .lifecycleChanged)
        publishCoherentState()
    }

    /// releaseAssignment closes **every** obligation of the current assignment
    /// and then gives the application back, in one operation the consumer can
    /// ask for without knowing what the seat is holding.
    ///
    /// ## Why it exists
    ///
    /// `releaseAssignedApplication` refuses over `pendingAdoptions` and over
    /// held members, and neither of those is anything the consumer can reach:
    /// it returns the Adopted Windows it knows about and is then refused over a
    /// surface it was never told of. Live, one leftover window kept the whole
    /// assignment bound and the person could not move on to a second
    /// application. So the set is closed here, where the registers are, and the
    /// consumer stops keeping a copy of them.
    ///
    /// ## What it closes, in order
    ///
    /// The reconciliation first, because it is the part that writes nothing:
    /// the Window IDs the window server proved destroyed leave every register,
    /// and a window already standing at the frame it is owed is let go without
    /// being moved again. Then the rollbacks of failed adoptions, then the
    /// Adopted Windows, then the members the seat moved in and never adopted.
    /// A surface owing no return is carried by the same paths and moved by
    /// none of them.
    ///
    /// ## What it will not do
    ///
    /// It touches only the assigned instance: a window of another assignment
    /// is not this operation's to move, and every step filters on the attested
    /// process lifetime rather than on a PID. It waits for a Command boundary
    /// instead of interrupting one, so a gesture already admitted keeps its
    /// release. It is idempotent: a second call with nothing assigned answers
    /// `nothingAssigned` and repeats whatever is still owed. And it never
    /// invents a destination: a window born on the Virtual Display stays a
    /// named obligation with the identity that survives a reused Window ID.
    ///
    /// ## The deadline
    ///
    /// `within` bounds the whole operation. Running out of it, or being
    /// cancelled, stops before the next surface and leaves the assignment
    /// standing: it is what entrusts the return of whatever is still out
    /// there, and ending it would leave obligations nothing can discharge.
    /// Asking again resumes from what is left.
    @discardableResult
    public func releaseAssignment(
        within deadline: Duration = .seconds(10)
    ) async -> AssignmentReleaseReport {

        // A zero or negative budget is already expired. Keep that fact as the
        // common absolute deadline so the normal obligation accounting still
        // names every untouched surface without converting a signed duration to
        // an enormous unsigned wait.
        let limit = Self.absoluteDeadline(after: deadline)
            ?? DispatchTime.now().uptimeNanoseconds

        // A Command already admitted is atomic and an adoption in flight is a
        // window on its way in: both finish before anything is given back.
        guard await awaitCommandBoundary(until: limit) else {
            return AssignmentReleaseReport(
                outcome    : .cancelled,
                obligations: outstandingObligations()
            )
        }
        while adoptionInFlight, Self.mayContinue(until: limit) {
            await EventLoopWait.sleep(Self.boundedPause(.milliseconds(10), until: limit))
        }
        guard !adoptionInFlight else {
            return AssignmentReleaseReport(
                outcome    : .cancelled,
                obligations: outstandingObligations()
            )
        }

        guard let assignment = assignmentKit.lifecycle.current else {
            return AssignmentReleaseReport(
                outcome    : .nothingAssigned,
                obligations: outstandingObligations()
            )
        }
        if let use = assignmentUseInFlight() {
            return AssignmentReleaseReport(outcome: .refused(use))
        }

        let instance = assignment.instance
        isReleasingAssignment = true
        // One cause for the whole operation: between two returns the gate would
        // otherwise reopen on a window the next step is about to move.
        beginTransfer()
        defer {
            endTransfer()
            isReleasingAssignment = false
        }

        var windows: [Int: WindowReleaseOutcome] = [:]

        // Recorded as each surface is answered for: a refused return forgets its
        // record, so a register read at the end would say nothing is owed.
        var owed: [Int: AssignmentObligation] = [:]
        func note(_ reference: WindowReference, _ frame: CGRect?, _ reason: AssignmentObligationReason) {
            guard let identity = reference.identity else { return }
            owed[identity.windowNumber] = AssignmentObligation(
                identity : identity,
                owedFrame: frame,
                reason   : reason
            )
        }

        let reconciled = reconcileBeforeRelease(of: instance)
        for number in reconciled {
            if let outcome = releaseLedger[number] { windows[number] = outcome }
        }

        var stopped = false
        for number in pendingAdoptions.keys.sorted() {
            guard let pending = pendingAdoptions[number],
                  pending.reference.identity?.process == instance else { continue }
            guard Self.mayContinue(until: limit) else { stopped = true; break }
            guard let restoration = await restorePendingAdoption(pending, until: limit) else {
                stopped = true
                break
            }
            let outcome = restoration.outcome
            windows[number]              = outcome
            releaseLedger[number]        = outcome
            adoptionRestorations[number] = outcome
            if outcome == .returned || outcome == .vanished { pendingAdoptions[number] = nil }
            else { note(pending.reference, pending.originalFrame, .restorationOwed) }
        }

        if !stopped {
            for window in adoptedWindows
            where window.reference.identity?.process == instance {
                guard Self.mayContinue(until: limit) else { stopped = true; break }
                guard let outcome = await releaseForAssignment(window, until: limit) else {
                    stopped = true
                    break
                }
                windows[window.id] = outcome
                // The shared hidden-window ledger owns an accepted deferred return.
                if outcome != .returned, outcome != .vanished, outcome != .returnsWhenShown {
                    note(window.reference, window.originalFrame, .returnRefused)
                }
            }
        }

        if !stopped {
            for member in assignmentKit.inventory.heldMembers
            where member.identity.process == instance && session[member.windowNumber] == nil {
                guard Self.mayContinue(until: limit) else { stopped = true; break }
                // A surface born on the Virtual Display has no place of its own
                // in the User Seat, and this kit does not invent one.
                guard member.origin == .preexisting else {
                    note(member.reference, nil, .noDestinationInUserSeat)
                    continue
                }
                guard let outcome = await returnHeldMember(member, until: limit) else {
                    stopped = true
                    break
                }
                windows[member.windowNumber] = outcome
                if outcome != .returned, outcome != .vanished, outcome != .returnsWhenShown {
                    note(member.reference, member.originalFrame, .returnRefused)
                }
            }
        }

        if stopped {
            // The assignment stays, deliberately. Everything still held is
            // named so the next call knows what it is resuming.
            for window in adoptedWindows
            where window.reference.identity?.process == instance
                    && windows[window.id] == nil && !window.owesNoReturn {
                note(window.reference, window.originalFrame, .notAttempted)
            }
            for pending in pendingAdoptions.values
            where pending.reference.identity?.process == instance
                    && windows[pending.id] == nil {
                note(pending.reference, pending.originalFrame, .notAttempted)
            }
            for member in assignmentKit.inventory.heldMembers
            where member.identity.process == instance && session[member.windowNumber] == nil
                    && windows[member.windowNumber] == nil && owed[member.windowNumber] == nil {
                let owedItsFrame = member.origin == .preexisting
                note(member.reference, owedItsFrame ? member.originalFrame : nil, .notAttempted)
            }
            publishCoherentState()
            return AssignmentReleaseReport(
                outcome    : .cancelled,
                windows    : windows,
                reconciled : reconciled,
                obligations: owed.keys.sorted().compactMap { owed[$0] }
            )
        }

        // The same coordinated end the handback uses. What the returns did not
        // finish becomes the restitution ledger's, which outlives the assignment.
        endAssignmentAndObservation(reason: .lifecycleChanged)
        publishCoherentState()
        for obligation in outstandingObligations() { owed[obligation.windowNumber] = obligation }

        return AssignmentReleaseReport(
            outcome    : .released,
            windows    : windows,
            reconciled : reconciled,
            obligations: owed.keys.sorted().compactMap { owed[$0] }
        )
    }

    private static func mayContinue(until limit: UInt64?) -> Bool {
        guard let limit else { return true }
        return !Task.isCancelled && DispatchTime.now().uptimeNanoseconds < limit
    }

    private static func remainingDuration(until limit: UInt64?) -> Duration? {
        guard let limit else { return nil }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < limit else { return .zero }
        return .nanoseconds(Int64(clamping: limit - now))
    }

    private static func boundedPause(_ duration: Duration, until limit: UInt64?) -> Duration {
        remainingDuration(until: limit).map { min(duration, $0) } ?? duration
    }

    /// Makes one non-wrapping monotonic deadline. A zero or negative Duration
    /// cannot be converted to an unsigned nanosecond count and therefore never
    /// becomes an accidentally unbounded release budget.
    private static func absoluteDeadline(after duration: Duration) -> UInt64? {
        let nanoseconds = duration.wholeNanoseconds
        guard nanoseconds > 0, let delta = UInt64(exactly: nanoseconds) else { return nil }
        let now = DispatchTime.now().uptimeNanoseconds
        let (deadline, overflow) = now.addingReportingOverflow(delta)
        return overflow ? UInt64.max : deadline
    }

    /// What the release found already settled, before it writes anything.
    ///
    /// Two facts and no others. A Window ID the window server was asked for by
    /// identity and answered no row at all is closed, and it leaves every
    /// register including the operating target's: the recovery episode that
    /// would otherwise keep that record is for a seat that goes on working, and
    /// this one is giving the whole application back. A window already standing
    /// at the frame it is owed is let go on the terms of a completed return.
    ///
    /// Neither writes geometry. That is what the phantom leftovers cost live:
    /// the windows had gone home and the seat was still refusing over records
    /// that described them.
    private func reconcileBeforeRelease(of instance: ProcessIdentity) -> [Int] {

        var settled: Set<Int> = []

        let snapshot = readSurfaces()
        var destroyed = pendingDestruction
        pendingDestruction = pendingDestruction.filter { $0.process != instance }
        if snapshot.inventory.completeness.isQualified {
            let currentNumbers = Set(snapshot.inventory.rows.map { $0.surface.reference.windowNumber })
            for (identity, presence) in logicalClosureEvidence
            where presence == .destroyed && !currentNumbers.contains(identity.windowNumber) {
                destroyed.insert(identity)
            }
        }
        for identity in destroyed where identity.process == instance {
            let number = identity.windowNumber
            if let current = session[number]?.window.reference.identity, current != identity { continue }
            if let pending = pendingAdoptions[number]?.reference.identity, pending != identity { continue }
            noteSurfaceGone(number, evidence: .windowServerConfirmedDestruction)
            if dropDestroyedRecord(number) { settled.insert(number) }
            if pendingAdoptions[number] != nil {
                pendingAdoptions[number]      = nil
                adoptionRestorations[number]  = .vanished
                releaseLedger[number]         = .vanished
                settled.insert(number)
            }
        }

        // One reading is enough because nothing is moved on the strength of it,
        // and it is the oracle the return itself is confirmed with.
        for window in adoptedWindows
        where window.reference.identity?.process == instance && !window.owesNoReturn {
            guard let reading = sensing.windowGeometry(of: window.id),
                  (try? originalFrameMatches(window, server: reading)) == true else { continue }
            letGoOfSettledRecord(window.id)
            settled.insert(window.id)
        }
        return settled.sorted()
    }

    /// Lets go of a record the reconciliation found already home, on the terms
    /// of a return that is complete and without writing any geometry.
    private func letGoOfSettledRecord(_ windowNumber: Int) {

        forgetRecord(windowNumber)
        if stagedWindowNumber == windowNumber { stagedWindowNumber = nil }
        refreshWindowFollowing()
        noteSurfaceGone(windowNumber)
        releaseLedger[windowNumber] = .returned
        eventChannel.yield(.windowReleased(windowNumber: windowNumber, outcome: .returned))
    }

    /// Gives back a surface the seat moved into the display and never adopted:
    /// a contained helper of the assigned application.
    ///
    /// It goes home through the seat's own placing, the way an Adopted Window
    /// does, because the nucleus's own effector is unqualified on this build
    /// and answers every request with a refusal. The record is built from what
    /// the inventory attested and from nothing else: the frame the surface was
    /// first seen at is what it is owed, the title stays empty so the
    /// structural recovery path refuses instead of matching some other window,
    /// and no window server rectangle is claimed for a reading that never
    /// took one.
    private func returnHeldMember(
        _ member: AssignedSurface,
        until limit: UInt64? = nil
    ) async -> WindowReleaseOutcome? {

        let window = AdoptedWindow(
            reference        : member.reference,
            originalFrame    : member.originalFrame,
            originalDisplayID: member.originalDisplayID
        )
        beginTransfer()
        let outcome = await returnToUserSeat(window, .returnToUserSeat, until: limit)
        endTransfer()
        guard Self.mayContinue(until: limit) else { return nil }
        releaseLedger[window.id] = outcome
        eventChannel.yield(.windowReleased(windowNumber: window.id, outcome: outcome))
        if outcome == .returned || outcome == .vanished { noteSurfaceGone(window.id) }
        else if outcome == .returnsWhenShown {
            noteSurfaceGone(window.id, evidence: .windowServerConfirmedOrderingOut)
        }
        return outcome
    }

    /// Assignment release keeps one monotonic budget. A return that crosses it
    /// may have written geometry, but its record remains held for a later
    /// reconciliation instead of being silently discarded as completed.
    private func releaseForAssignment(
        _ window: AdoptedWindow,
        until limit: UInt64
    ) async -> WindowReleaseOutcome? {
        guard Self.mayContinue(until: limit) else { return nil }
        if stagedWindowNumber == window.id { stagedWindowNumber = nil }
        beginTransfer()
        let outcome = await returnToUserSeat(window, .returnToUserSeat, until: limit)
        endTransfer()
        guard Self.mayContinue(until: limit) else { return nil }
        let successor = forgetRecord(window.id)
        refreshWindowFollowing()
        noteSurfaceGone(window.id)
        releaseLedger[window.id] = outcome
        eventChannel.yield(.windowReleased(windowNumber: window.id, outcome: outcome))
        await takeOverAfterLostTarget(successor)
        return outcome
    }

    /// Everything the restitution ledger still has open, as obligations. It
    /// outlives the assignment, which is why a second call can still describe
    /// what the first one left.
    private func outstandingObligations() -> [AssignmentObligation] {

        assignmentKit.restitution.outstanding.compactMap { number in
            guard let surface = assignmentKit.restitution.pending[number] else { return nil }
            let isOwedItsFrame = surface.origin == .preexisting
            return AssignmentObligation(
                identity : surface.identity,
                owedFrame: isOwedItsFrame ? surface.originalFrame : nil,
                reason   : isOwedItsFrame ? .returnRefused : .noDestinationInUserSeat
            )
        }
    }

    /// What the seat is in the middle of that the assignment is the authority
    /// for, nil when it is between things.
    private func assignmentUseInFlight() -> AssignmentUse? {
        if isTearingDown                      { return .seatTearingDown }
        if actionInFlight                     { return .commandInFlight }
        if turns.current != nil               { return .turnHeld }
        if adoptionInFlight                   { return .adoptionInFlight }
        if transfersInFlight != 0             { return .windowTransferInFlight }
        if focusRecovery?.isRestoring == true { return .focusRecoveryRestoring }
        return nil
    }

    /// Every window of this instance the seat still has a claim on, in Window ID
    /// order, from the three records that each hold part of the answer: the
    /// Adopted Windows, a failed move whose restoration the host still owes, and
    /// the assignment members the seat owes a return.
    ///
    /// The held members are in it because they are exactly what a release turns
    /// into the return obligation, and an adopted window is in it a moment
    /// before the next reading makes it one of them. Membership is not a claim:
    /// every window of the assigned application is a member whether the seat
    /// touched it or not, so counting members here refused the handback of any
    /// application that had a window open at all.
    ///
    /// Filtering by instance is the point: a window of another instance is not
    /// this assignment's to answer for, and a handback must leave it exactly
    /// where it is.
    ///
    /// A surface the adoption recorded as owing no return is left out of all
    /// three. A sheet is drawn inside the window it blocks and goes wherever
    /// that window goes: the seat owns it and holds a platform for it, and
    /// refusing the handback over it would strand the instance on a surface
    /// nothing public can give back. `AssignedSurfaceInventory` drops the same
    /// claim on its own side, so the third set never carries it either.
    private func windowsStillHeld(of instance: ProcessIdentity) -> [Int] {

        var numbers = Set(
            session.records.values
                .filter { $0.window.reference.identity?.process == instance }
                .map(\.window.id)
        )
        numbers.formUnion(
            pendingAdoptions.values
                .filter { $0.reference.identity?.process == instance }
                .map(\.id)
        )
        numbers.formUnion(
            assignmentKit.inventory.heldMembers
                .filter { $0.identity.process == instance }
                .map(\.windowNumber)
        )
        let owedNothing = Set(
            (session.records.values.map(\.window) + Array(pendingAdoptions.values))
                .filter(\.owesNoReturn)
                .map(\.id)
        )
        return numbers.subtracting(owedNothing).sorted()
    }

    // MARK: The current target

    /// switchTarget moves the seat's operating target to another Adopted
    /// Window, brings it on stage and tells the consumer to observe again.
    ///
    /// ## The contract
    ///
    /// It waits for a command boundary instead of interrupting: a Command in
    /// flight finishes atomically, and a Turn still holding a key is refused
    /// rather than having its presses stranded on the window it is leaving.
    /// It holds input closed with `.windowTransfer` for the whole transaction,
    /// so no Command starts on coordinates the stage is about to change, and
    /// nothing already posted is ever repeated. It re-confirms identity and
    /// geometry **after** the staging await, because the window a transaction
    /// starts on is not necessarily the one it ends on, and an uncertain
    /// reading is a refusal rather than a staged window. On a refusal it
    /// changes nothing at all: the previous target stays the target, and
    /// `targetChangeRefused` carries the state and the Issues that decided it.
    ///
    /// The target is not "the window input goes to". `send(_:to:turn:)` keeps
    /// taking its window by parameter, so a request addressed to one window is
    /// never delivered to another because the target moved; what changes is
    /// which window the seat guards, observes and falls back from.
    @discardableResult
    public func switchTarget(to window: AdoptedWindow) async throws -> AdoptedWindow {

        guard session[window.id] != nil else {
            refuseTargetChange(window.id, issues: [])
            throw SessionFailure.windowNotAdopted(windowNumber: window.id)
        }
        return try await transferTarget(to: window.id, reason: .requested)
    }

    /// The transfer itself, shared by an explicit request and by a predecessor
    /// taking over after the target was proved gone.
    @discardableResult
    private func transferTarget(
        to windowNumber: Int,
        reason         : SeatTargetChange,
        within deadline: Duration = .seconds(2)
    ) async throws -> AdoptedWindow {

        guard await awaitCommandBoundary(within: deadline), !isTearingDown,
              state.acceptsCommands, let record = session[windowNumber] else {
            refuseTargetChange(windowNumber, issues: [])
            throw SessionFailure.seatNotReady(state)
        }

        // A key this Turn pressed is state inside the window it was pressed on,
        // and moving the target with one still down would leave it there with
        // nobody left to lift it.
        if let turn = turns.current {
            let held = heldKeyCount(of: turn)
            guard held == 0 else {
                refuseTargetChange(windowNumber, issues: [])
                throw SessionFailure.keysStillHeld(count: held)
            }
        }

        transferGeneration &+= 1
        let generation = transferGeneration
        let displaced  = session.currentTargetNumber

        beginTransfer()
        defer { endTransfer() }

        let staged: AdoptedWindow
        do {
            staged = try await stage(record.window)
        } catch {
            // The staging Issue is the one that decided this refusal, and
            // `stage` has just reported it. An empty list here would say the
            // seat's state was the reason, which is a different fact.
            refuseTargetChange(windowNumber, issues: [.windowStashed])
            throw error
        }

        // Everything above was read before an await that costs the staging
        // animation, so identity and geometry are established again here. A
        // second transfer started meanwhile owns the target, and this one loses.
        try Task.checkCancellation()
        guard generation == transferGeneration, !isTearingDown, state != .failed,
              let confirmed = session[windowNumber], confirmed.isStaged,
              confirmed.window.reference.hasSameIdentity(as: staged.reference),
              let reading = sensing.windowGeometry(of: windowNumber),
              reading.hasSameIdentity(as: staged.reference),
              sensing.virtualDisplayBounds.contains(reading.frame)
        else {
            refuseTargetChange(windowNumber, issues: [.windowUnavailable])
            throw SeatInterruption(issues: [.windowUnavailable])
        }

        session[windowNumber]?.window = confirmed.window.withReference(reading)
        session.makeCurrent(windowNumber)
        seatGuard = SeatGuard(
            target       : reading,
            displayID    : displayID,
            displayBounds: sensing.virtualDisplayBounds
        )

        // The observation belongs to the window it was opened on. It is folded
        // into the hold's running total so the next Command opens a new one on
        // the new target instead of reporting the old one's.
        if let observer {
            observationSoFar = (observationSoFar ?? SeatObservation()).merging(observer.conclude())
            self.observer = nil
        }

        // A change of target invalidates the previous observation at once, before
        // anything is arranged for the new one. Coming back to a window later is
        // a new selection under a new generation, which is what stops A to B to A
        // from reviving the first A's observation.
        observationIssuer.invalidate(.targetChanged)
        outstandingGeometry = nil
        selectExplicitly(reading)

        eventChannel.yield(.targetChanged(from: displaced, to: reading, reason: reason))
        publishCoherentState()
        return session[windowNumber]?.window ?? staged
    }

    private func refuseTargetChange(_ windowNumber: Int, issues: [SeatIssue]) {
        eventChannel.yield(
            .targetChangeRefused(windowNumber: windowNumber, state: state, issues: issues)
        )
    }

    /// Waits for the boundary between two Commands, the only moment at which
    /// anything here moves a window. False means the deadline passed with a
    /// Command still in flight, and the caller refuses rather than cutting it.
    ///
    /// It sleeps and never pumps. The Command it is waiting for is running on
    /// the main actor, so a wait that turned the event loop here would hold the
    /// actor the Command needs to finish on and the boundary would never
    /// arrive: measured as a transfer that timed out against its own send.
    private func awaitCommandBoundary(within deadline: Duration) async -> Bool {

        guard let limit = Self.absoluteDeadline(after: deadline) else { return !actionInFlight }
        return await awaitCommandBoundary(until: limit)
    }

    /// Waits under a deadline that its caller already fixed, so an earlier wait
    /// cannot silently grant the next release phase a fresh full budget.
    private func awaitCommandBoundary(until limit: UInt64) async -> Bool {
        while actionInFlight, Self.mayContinue(until: limit) {
            await EventLoopWait.sleep(Self.boundedPause(.milliseconds(10), until: limit))
        }
        return !actionInFlight && !Task.isCancelled
    }

    /// The stop the sender honours at command boundaries, when it has one. The
    /// seat reaches it through the sender because the focus recovery path is
    /// installed only for a host that restores user focus, and a window
    /// transfer has to close the gate in both configurations.
    private var commandGate: InputCommandGate? { sender.inputCommandGate }

    /// Why the gate is holding Commands back right now, sorted, and empty when
    /// it is holding none.
    ///
    /// Reading it grants nothing and decides nothing: admission is still the
    /// gate's own check at the point input is posted. It exists because
    /// `state` does not answer this question. The person's own stop closes the
    /// gate and leaves the seat `ready`, so a consumer that shows a seat state
    /// and reads only `state` tells the person input is going out when nothing
    /// is, which is the one reading a status indicator must never get wrong.
    public var inputPauseReasons: [InputPauseReason] {
        (commandGate?.pauseCauses ?? []).map(\.reason).sorted()
    }

    /// One cause for however many transfers are open.
    ///
    /// Transfers nest: a window released while another transfer is staging
    /// starts its predecessor's take over from inside that transfer's await. A
    /// set holds one `.windowTransfer` whoever inserted it, so the inner
    /// transfer's end would otherwise reopen input while the outer one is still
    /// moving a window. Counting here and not in the gate keeps the gate's rule
    /// the simple one: closed while any cause stands.
    ///
    /// The transfer is also the focus episode of an operation outside a Turn:
    /// one delivery or containment, opened once and ended once whatever it
    /// moves. The activation of an application that raised a window usually
    /// arrives before the seat has detected it, so that activation opens the
    /// episode itself and this finds it already open; what the bracket owns in
    /// every case is its end. Inside a Turn both calls stand down: the Turn's
    /// episode is the one that counts.
    private func beginTransfer() {
        transfersInFlight += 1
        if transfersInFlight == 1 {
            commandGate?.pause(.windowTransfer)
            focusRecovery?.beginOperation()
        }
    }

    private func endTransfer() {
        transfersInFlight -= 1
        if transfersInFlight == 0 {
            commandGate?.resume(.windowTransfer)
            focusRecovery?.endOperation()
        }
    }

    // MARK: The action

    /// send posts one Command against the observation it was decided on.
    ///
    /// ## The recipient is the reference's, never the current target
    ///
    /// The window this Command reaches is the one the reference names. A seat
    /// whose target moved while the consumer was deciding refuses the Command;
    /// it does not deliver it to whatever is current now, because a plan made on
    /// one window's pixels is not a plan for another window.
    ///
    /// ## Where it is verified
    ///
    /// At entry, and again on the last main actor statement before the sender is
    /// handed the Command, which is the boundary before the driver builds and
    /// posts. The driver then re-reads identity and geometry immediately before
    /// its first `postToPid`, and the reference is bound to that same identity
    /// and geometry, so the pair is the irreversible boundary. After the first
    /// event nothing is checked, because nothing can be undone.
    ///
    /// ## After it completes
    ///
    /// The barrier advances and the observation stops being current: the next
    /// Command needs a new one. A Command that was refused before any effect
    /// leaves the observation exactly as it was, so the consumer may fix the
    /// cause and send again without observing twice.
    ///
    /// The Receipt comes back with a `SeatObservation` attached, which is the
    /// User Seat diagnostic of the interval and not this observation.
    @discardableResult
    public nonisolated func send(
        _ command  : InputCommand,
        observation: SeatObservationReference,
        turn       : Turn,
        platform   : (any InputPlatform)? = nil
    ) async throws -> InputReceipt {
        try await send(
            command,
            observation     : observation,
            turn            : turn,
            platform        : platform,
            layoutGeneration: nil
        )
    }

    /// Writes a modal's position back when its application reports another one.
    ///
    /// Measured on 30/09/2026 with Photoshop's Save panel: the panel service
    /// lays its content out at the position the host application reports to
    /// accessibility, and a write of `AXPosition` moves the content with it.
    /// After the seat had taken the panel in, Photoshop kept reporting where it
    /// used to be, 2036 by 1347 points away from where the window server showed
    /// it, and every Command found the content outside the panel
    /// (`notContainedInSurface`, `geometryUnavailable`). Writing the position the
    /// window server already shows moves nothing on screen and brings the
    /// content back. Only when both sources read the same size: a window Stage
    /// Manager stashed reads smaller on the server, and that is not this.
    private func realignReportedPosition(of observation: SeatObservationReference) async {
        guard let modal = attestedModalSurface(for: observation) else { return }
        // A sheet follows its host, so the window written is the outermost one held.
        let outer = observationPicture(for: modal).surface
        guard let record   = session[outer.windowNumber],
              record.window.reference.identity == outer,
              let server   = sensing.windowGeometry(of: outer.windowNumber),
              server.hasSameIdentity(as: record.window.reference),
              let reported = (try? placing.frame(of: record.window.reference)) ?? nil
        else { return }
        // Temporary live diagnosis: both readings, whether they agree or not.
        Self.log.notice("""
            modal window \(outer.windowNumber, privacy: .public) reads \
            \(String(describing: reported), privacy: .public) to accessibility and \
            \(String(describing: server.frame), privacy: .public) to the window server
            """)
        guard VirtualWindowPlacementCheck.sizesMatchAcrossSources(server.frame.size, reported.size),
              !VirtualWindowPlacementCheck.framesMatch(
                  reported, server.frame, tolerance: VirtualWindowPlacementCheck.crossSourceTolerance
              ),
              (try? placing.move(record.window.reference, to: server.frame.origin)) != nil
        else { return }
        Self.log.notice("""
            window \(outer.windowNumber, privacy: .public) was reported at \
            \(Int(reported.minX), privacy: .public),\(Int(reported.minY), privacy: .public) and shown at \
            \(Int(server.frame.minX), privacy: .public),\(Int(server.frame.minY), privacy: .public): \
            wrote the shown position back
            """)
        await EventLoopWait.step(.milliseconds(150))
    }

    private func send(
        _ command       : InputCommand,
        observation     : SeatObservationReference,
        turn            : Turn,
        platform        : (any InputPlatform)?,
        layoutGeneration: UInt64?
    ) async throws -> InputReceipt {

        // While a menu interaction is current, only the menu and its closing may
        // be acted on, and those go through the interaction. An ordinary Command
        // here is refused whatever it carries.
        if let context = menuContext {
            throw ObservationAdmissionRefusal.ordinaryCommandDuringMenu(parent: context.parent)
        }
        guard !observation.role.isTransientMenu else {
            throw ObservationAdmissionRefusal.menuContextRevoked
        }
        let admitted = try admitOrdinary(observation)
        await realignReportedPosition(of: observation)
        // The picture may be the host's while the Command is over a modal drawn
        // inside it: a gesture goes to the window under the point of the down,
        // and a key to the window the observed internal focus is in.
        let resolvedGesture = try inputEndpoint(for: command, observation: observation)
        let endpoint        = resolvedGesture?.endpoint
        if let endpoint, endpoint.kind == .keyboardContext {
            keyboardRecipients[endpoint.logicalSurface.windowNumber] = endpoint.identity.processID
        }
        let window          = resolvedGesture?.surface ?? admitted
        let routed          = endpoint.map { command.rebased(onto: $0.geometry) } ?? command
        // The current reference of the endpoint's own reading, never the record
        // the adoption wrote with the frame the surface used to be at.
        let recipient       = endpoint?.geometry.window ?? window.reference

        if Self.nativeTextInputID != nil || nativeTextInputContext != nil {
            guard let context = nativeTextInputContext else {
                throw InputFailure.nativeTextInputRefused(.contextClosed)
            }
            guard Self.nativeTextInputID == context.id else {
                throw InputFailure.nativeTextInputRefused(.contextMismatch)
            }
            try requireNativeTextInputCommand(routed)
            guard context.turn == turn, recipient.identity == context.window.identity,
                  recipient.windowNumber == context.window.windowNumber
            else { throw InputFailure.nativeTextInputRefused(.contextMismatch) }
        }

        var traceContext = InputTraceIdentity.submitted(
            command      : routed,
            window       : recipient,
            correlationID: turn.correlationID
        )
        traceContext.beginExecution(at: DispatchTime.now().uptimeNanoseconds)

        let record: WindowRecord
        do {
            record = try preflight(window, turn: turn, traceContext: &traceContext)
        } catch {
            sender.recordCompletedTrace(
                traceContext.completed(at: DispatchTime.now().uptimeNanoseconds)
            )
            throw error
        }

        // The recipe comes from what the seat established about the surface and
        // from what this Command needs. One that qualifies none refuses.
        let classification = SurfaceInputClassification.of(
            observation,
            endpoint: endpoint,
            remoteAppKitPanelServiceQualified: endpoint.map {
                endpoints.qualifiedAppKitPanelService($0.identity)
            } ?? false
        )
        let isModalSurface = attestedModalSurface(for: observation) != nil
        if nativeTextInputContext != nil, isModalSurface {
            throw InputFailure.nativeTextInputRefused(.unsupported)
        }
        guard let resolved = platform ?? classification.platform(
            for                : routed,
            ofDrivenApplication: record.platform,
            host               : window.reference,
            recipient          : recipient,
            isModalSurface     : isModalSurface
        ) else {
            sender.recordCompletedTrace(
                traceContext.completed(at: DispatchTime.now().uptimeNanoseconds)
            )
            throw SessionFailure.surfaceFamilyUnclassified(
                windowNumber: observation.role.attachedSheet?.windowNumber
                    ?? recipient.windowNumber
            )
        }
        if isModalSurface, resolved is UXPPlatform,
           resolved.preparation(for: routed) == .internalAppKitState {
            sender.recordCompletedTrace(
                traceContext.completed(at: DispatchTime.now().uptimeNanoseconds)
            )
            throw SessionFailure.surfaceFamilyUnclassified(windowNumber: recipient.windowNumber)
        }
        // UXP recipient proof requires its own key window. A caller override
        // cannot omit priming, activate the app, or prime a different window.
        if endpoint?.evidence == .unfocusedModalSurface
            || endpoint?.evidence == .mainWindowUnderFocusProxy
            || (endpoint?.evidence == .leafSurface && record.platform is UXPPlatform && !routed.hasMouseLocation),
           !(resolved is UXPPlatform
             && resolved.preparation(for: routed) == .none
             && resolved.keyWindowPriming(for: routed)?.host.identity == recipient.identity) {
            sender.recordCompletedTrace(
                traceContext.completed(at: DispatchTime.now().uptimeNanoseconds)
            )
            throw SessionFailure.surfaceFamilyUnclassified(windowNumber: recipient.windowNumber)
        }
        // Where a Command went, never what it carried: a first key to a panel
        // that did nothing could not be told from one that went elsewhere.
        Self.log.notice("""
            \(routed.hasMouseLocation ? "pointer" : "keys", privacy: .public) on window \
            \(observation.surface.windowNumber, privacy: .public) go to window \
            \(recipient.windowNumber, privacy: .public) of pid \(recipient.processID, privacy: .public), \
            \(endpoint.map { "\($0.relation) by \($0.evidence)" } ?? "no endpoint", privacy: .public), \
            recipe \(String(describing: type(of: resolved)), privacy: .public)
            """)
        // A Command on a modal surface can close it, and closing it is what
        // takes the focus. See `UserFocusRecovery.expectClosure`.
        if let sheet = attestedModalSurface(for: observation)
            ?? endpoint.flatMap({ $0.relation == .remoteContent ? $0.logicalSurface : nil }) {
            focusRecovery?.expectClosure(
                dialog : sheet,
                helpers: endpoint.map { [$0.geometry.window] } ?? []
            )
        }
        let previous = state
        var commandPosted = false
        actionInFlight = true
        transition(to: .acting, reason: .requested)
        defer {
            actionInFlight = false
            restoreActionState(previous, reason: .requested)
            // An expectation whose Command never prepared belongs to nothing.
            // The transition itself outlives this: the steal follows the post.
            focusRecovery?.dropClosureExpectation()
            // A window opened by the Command that has just finished is looked
            // for here, at the boundary, rather than a beat later.
            requestWindowFollow(
                through: commandPosted ? resolved.windowArrivalHorizon(after: routed) : .zero
            )
        }

        do {
            // The boundary: the last statement on this actor before the driver
            // builds and posts. The preflight above changed the seat's state, so
            // the reference is checked against the world one more time here.
            if let refusal = admissionRefusal(for: observation, expecting: .ordinaryTarget) {
                restoreActionState(previous, reason: .cancelled)
                sender.recordCompletedTrace(
                    traceContext.completed(at: DispatchTime.now().uptimeNanoseconds)
                )
                throw refusal
            }
            // The other half of the attestation rule: what the driver cannot
            // read is that the surface and the selection are still these.
            if let endpoint, let retired = endpointInvalidation(of: endpoint) {
                restoreActionState(previous, reason: .cancelled)
                sender.recordCompletedTrace(
                    traceContext.completed(at: DispatchTime.now().uptimeNanoseconds)
                )
                throw retired
            }
            traceContext.beginQueue(at: DispatchTime.now().uptimeNanoseconds)
            let receipt = try await sender.send(
                routed,
                to           : recipient,
                correlationID: turn.correlationID,
                platform     : resolved,
                traceContext : traceContext,
                beforeFirstPost: { [weak self] in
                    try await MainActor.run {
                        guard let self else { throw CancellationError() }
                        if let refusal = self.admissionRefusal(for: observation, expecting: .ordinaryTarget) {
                            throw refusal
                        }
                        // The waits the recipe itself imposed are not the endpoint growing old.
                        if let endpoint, let retired = self.endpointInvalidation(
                            of      : endpoint,
                            allowing: Self.preparationWait(of: resolved, for: routed)
                        ) {
                            throw retired
                        }
                    }
                }
            )
            commandPosted = true
            // The Command is complete, so the observation it was decided on is
            // no longer current. It is not a fault: the reason says so.
            noteObservationConsumed()
            // The post is its own fact. A closure that went out stays out while
            // the recovery is still running, and nothing posts it again.
            focusRecovery?.noteClosureCommandPosted()

            let traced = receipt.trace == nil
                ? receipt.replacingTrace(
                    traceContext.completed(at: DispatchTime.now().uptimeNanoseconds)
                )
                : receipt
            // Stamped **before** `finish` records it, never after it is
            // returned. `confirm` matches a Receipt by its whole value, which
            // is the anti replay invariant: a Receipt changed on the way out is
            // a Receipt the seat will not recognise, and a Command that cannot
            // be confirmed is a Turn that cannot be given back.
            let resolved = layoutGeneration == nil
                ? traced
                : traced.replacingLayoutGeneration(layoutGeneration)
            return finish(resolved, returningTo: previous)

        } catch let failure as InputPreparationFailure {
            if failure.progress.neededRecovery != nil {
                report([.preparationNotRestored])
            }
            restoreActionState(previous, reason: .cancelled)
            throw failure
        } catch {
            // Every refusal of the driver happens before the first
            // `postToPid`: the posting loop itself cannot fail. So a thrown
            // send posted nothing and leaves no unconfirmed Command behind.
            restoreActionState(previous, reason: .cancelled)
            throw error
        }
    }

    /// Removed in the observation cutover, not deprecated: it posted a list of
    /// Commands from one observation and one decision, with no new observation
    /// and no new decision between them.
    ///
    /// Migration: the consumer orchestrates the succession itself, observing and
    /// deciding again between Commands. The Preparation saving a sequence bought
    /// is deliberately given up: a saved Preparation is not worth a Command
    /// posted onto pixels nobody looked at.
    @available(
        *, unavailable,
        message: "Orchestrate the succession: send(_:observation:turn:platform:) per observation"
    )
    public nonisolated func sendSequence(
        _ commands: [InputCommand],
        to window : AdoptedWindow,
        turn      : Turn,
        platform  : (any InputPlatform)? = nil
    ) async throws -> [InputReceipt] {
        fatalError("unavailable")
    }

    // MARK: The contextual menu

    /// Runs a native dropdown inside one Turn. The caller supplies native actions and an
    /// asynchronous reader; the Seat owns window discovery, observation and mandatory cleanup.
    /// Returning true means a selection was requested, not that its application effect succeeded.
    public func useNativePopupMenu(
        of window: AdoptedWindow,
        turn: Turn,
        within deadline: Duration = .milliseconds(1500),
        opening: @MainActor @Sendable () throws -> Void,
        choosing choose: @MainActor @Sendable (ContextMenu) async throws -> Bool
    ) async throws -> PopupMenuReceipt {
        try await usePopupMenu(of: window, turn: turn, within: deadline,
                               opening: { _, _ in try opening() }, choosing: choose)
    }

    /// Opens a pixel-resolved dropdown with one routed left click, then executes the reader's
    /// keyboard selection while the attested menu still exists. Nil means dismiss without choosing.
    /// The opener uses the adopted platform; keys are unprepared so they preserve the menu loop.
    /// The caller supplies pacing and must verify the value afterwards. Commands are never replayed.
    public func useDropdownMenu(
        openedAt location: InputLocation,
        of window: AdoptedWindow,
        turn: Turn,
        within deadline: Duration = .milliseconds(1500),
        keyInterval: Duration,
        choosing choose: @MainActor @Sendable (ContextMenu) async throws -> [CGKeyCode]?
    ) async throws -> PopupMenuReceipt {
        var opening: InputReceipt?
        var choosing: [InputReceipt] = []
        let result = try await usePopupMenu(of: window, turn: turn, within: deadline, opening: { target, platform in
            opening = self.witnessed(try await self.sender.send(
                .click(location, button: .left), to: target,
                correlationID: turn.correlationID, platform: platform
            ))
        }) { menu in
            guard let keys = try await choose(menu), !keys.isEmpty else { return false }
            for (index, key) in keys.enumerated() {
                try Task.checkCancellation()
                let liveMenus = self.sensing.menuWindows(ownedBy: window.reference.processID)
                guard liveMenus.count == 1, let live = liveMenus.first,
                      live.hasSameIdentity(as: menu.window), live.frame == menu.frame else {
                    throw InputFailure.currentCoordinateGeometryUnavailable
                }
                choosing.append(self.witnessed(try await self.sender.send(
                    .key(virtualKey: key, text: ""), to: window.reference,
                    correlationID: turn.correlationID, platform: AppKitPlatform()
                )))
                if index < keys.count - 1 { try await Task.sleep(for: keyInterval) }
            }
            return true
        }
        return PopupMenuReceipt(
            menu: result.menu, selectionRequested: result.selectionRequested,
            closedBy: result.closedBy, observation: result.observation,
            opening: opening, choosing: choosing
        )
    }

    /// Shares preflight, menu attestation and mandatory cleanup between native and routed openers.
    private func usePopupMenu(
        of window: AdoptedWindow,
        turn: Turn,
        within deadline: Duration,
        opening: @MainActor @Sendable (WindowReference, any InputPlatform) async throws -> Void,
        choosing choose: @MainActor @Sendable (ContextMenu) async throws -> Bool
    ) async throws -> PopupMenuReceipt {
        // Preflight uses the same guard and observation baseline as other Seat actions.
        // This trace is not an InputReceipt: no Driver event is fabricated for a native request.
        var trace = InputTraceIdentity.submitted(
            command: .text(""), window: window.reference, correlationID: turn.correlationID
        )
        let record = try preflight(window, turn: turn, traceContext: &trace)
        let target = record.window.reference
        guard sensing.menuWindows(ownedBy: target.processID).isEmpty else {
            throw SessionFailure.contextMenuAlreadyOpen(processID: target.processID)
        }
        let previous = state
        actionInFlight = true
        transition(to: .acting, reason: .requested)
        defer {
            actionInFlight = false
            restoreActionState(previous, reason: .requested)
            requestWindowFollow()
        }
        let started = ContinuousClock.now
        var menu: ContextMenu?
        var requested = false
        var failure: (any Error)?
        do {
            try Task.checkCancellation()
            try await opening(target, record.platform)
            _ = await EventLoopWait.until({
                !self.sensing.menuWindows(ownedBy: target.processID).isEmpty
            }, timeout: deadline, interval: .milliseconds(30))
            let appeared = sensing.menuWindows(ownedBy: target.processID)
            guard let first = appeared.first else {
                throw SessionFailure.contextMenuNeverOpened(windowNumber: target.windowNumber, within: deadline)
            }
            let observed = ContextMenu(window: first, appearedAfter: started.duration(to: .now))
            menu = observed
            guard appeared.count == 1 else { throw PopupMenuFailure.ambiguousMenu }
            guard sensing.virtualDisplayBounds.contains(observed.frame) else {
                throw InputFailure.currentCoordinateGeometryUnavailable
            }
            try Task.checkCancellation()
            requested = try await choose(observed)
        } catch { failure = error }

        // Even a native request that timed out may have opened a menu. Never abandon it.
        if menu == nil, let late = sensing.menuWindows(ownedBy: target.processID).first {
            menu = ContextMenu(window: late, appearedAfter: started.duration(to: .now))
        }
        guard let menu else {
            // A timed-out native request may deliver late. Cycle the target's preparation
            // before giving it back, just as the contextual-menu opening timeout does.
            if let timeout = failure as? SessionFailure, case .contextMenuNeverOpened = timeout {
                do { try await sender.cyclePreparation(on: target) }
                catch {
                    if let cleanup = error as? InputPreparationFailure,
                       cleanup.progress.neededRecovery != nil { report([.preparationNotRestored]) }
                    throw error
                }
                _ = await EventLoopWait.until(
                    { self.sensing.menuWindows(ownedBy: target.processID).isEmpty },
                    timeout: .milliseconds(500), interval: .milliseconds(30)
                )
                if let late = sensing.menuWindows(ownedBy: target.processID).first {
                    report([.contextMenuLeftOpen])
                    throw SessionFailure.contextMenuNotClosed(menuWindowNumber: late.windowNumber, processID: target.processID)
                }
            }
            if let failure { throw failure }
            throw SessionFailure.contextMenuNeverOpened(windowNumber: target.windowNumber, within: deadline)
        }
        let closedBy = await close(
            menu,
            of                : target,
            turn              : turn,
            itemWasChosen     : requested,
            withinNanoseconds : observationProfile.menuCleanupNanoseconds
        )
        if requested {
            _ = await EventLoopWait.until(
                { self.sensing.frontmostProcessID == target.processID },
                timeout: .milliseconds(800), interval: .milliseconds(30)
            )
        }
        if sensing.frontmostProcessID == target.processID {
            if let focusRecovery { focusRecovery.activationChanged(to: target.processID, source: .contextMenuPoll) }
            else { report([.targetActivated]) }
        }
        guard let closedBy else {
            report([.contextMenuLeftOpen])
            throw SessionFailure.contextMenuNotClosed(menuWindowNumber: menu.window.windowNumber, processID: target.processID)
        }
        if let failure { throw failure }
        return PopupMenuReceipt(menu: menu, selectionRequested: requested, closedBy: closedBy, observation: observer?.observation())
    }

    /// useContextMenu opens the target's own contextual menu with a routed right
    /// click, hands the caller the rectangle the window server drew it at, posts
    /// the click the caller answers with, and **closes the menu whatever
    /// happens**.
    ///
    /// ## Why it is one call and not three
    ///
    /// An open contextual menu is a modal tracking loop inside somebody else's
    /// process: while it is up, that application does not run its normal loop,
    /// and the only way out is a dismissal. A menu the kit opened and left open
    /// is therefore worse than any failed action, so closing it is not something
    /// a caller can forget. It happens here, with two nets, and a menu that
    /// survives both is the loudest failure the seat has: a thrown
    /// `contextMenuNotClosed` and a critical `contextMenuLeftOpen` on the event
    /// stream.
    ///
    /// That is also why the caller's part is a **synchronous** closure that
    /// answers with a point rather than a handle it could keep. There is no way
    /// to hold this menu open past the end of the call, and no way to be given
    /// one.
    ///
    /// ## The oracle is the window server, and only the window server
    ///
    /// The menu's existence is verified through its WindowServer window. AppKit
    /// exposes menu items through accessibility, while the measured Chromium
    /// menu does not. A missing accessibility menu therefore does not prove that
    /// the contextual menu failed to open.
    ///
    /// ## The recipe is inverted here, and the routing is not optional
    ///
    /// Every other mouse Command on a Chromium target is prepared. This one is
    /// not, and `ChromiumPlatform` says why: the restore is what dismisses the
    /// menu, at 413 to 453 ms against 1,9 s unprepared. The same property is
    /// what the teardown pulls on afterwards.
    ///
    /// The click is routed like every other, and here that is load bearing
    /// rather than an optimisation: an unrouted right click reaches the process
    /// with `windowNumber == 0` and no view to deliver it to, so it opens
    /// nothing at all.
    ///
    /// ## What it costs the person, said plainly
    ///
    /// The menu is **drawn**. On the Virtual Display it follows the target's
    /// window and stays inside that display, measured on both families, so the
    /// person sees nothing; at a target on a physical display they see a menu
    /// appear over what they are looking at.
    ///
    /// Opening one costs the User Seat nothing: sampled every 30 ms from before
    /// the click to after the teardown, on both families, the frontmost
    /// application appears once and never changes, and the target reports
    /// itself inactive throughout. Choosing an item can run a command that
    /// activates the target, such as Print. The caller must identify the item
    /// and account for its semantics; the centre of the menu is not a safe
    /// default. On 26A5425a, Select All, Undo and Redo identified in Chrome menu
    /// images each produced their measured editing effect without changing the
    /// frontmost application or cursor. This is not a promise for other items.
    ///
    /// This call still observes delayed activation after a choice and reports
    /// `SeatIssue.targetActivated`. An opted-in host attempts bounded user
    /// focus recovery; otherwise the seat waits for the user. Neither mode
    /// suppresses the initial activation caused by the selected command. A caller
    /// that cannot identify a suitable item returns nil and the menu is closed.
    ///
    /// ## None of its Commands is left for the caller to confirm
    ///
    /// Unlike `send`, the Commands this action posts are not remembered as
    /// unconfirmed. The anti-replay invariant exists because the kit usually
    /// cannot see an effect and the consumer can; here the opposite is true,
    /// and the seat sees every one of them: the menu appeared, the menu closed.
    /// What the item did **inside** the target is a further question and it
    /// stays the caller's, answered on the caller's own next observation.
    ///
    /// ## The budgets
    ///
    /// 180 s from the start of the opening for the whole interaction, captures,
    /// waits and any Vision the body ran included, and nothing renews it. 2 s
    /// separately for the cleanup and the verification of the close, measured
    /// from the end, the error or the expiry. Expiry revokes the context at once:
    /// the body may still be running, and every entry point it holds answers
    /// `menuContextRevoked` from that moment.
    ///
    /// ## What the body can actually do on this build
    ///
    /// Observing the menu's dedicated surface needs a native ability nothing here
    /// has qualified, so `SeatMenuInteraction.observe` refuses with the capability
    /// named and choosing an item cannot be reached. The parent's Frame is never
    /// offered in its place. The opening, the closing and the accounting are real;
    /// the choice is blocked by the evidence, not by a placeholder.
    @discardableResult
    public func withContextMenu(
        openedAt location  : InputLocation,
        observation        : SeatObservationReference,
        turn               : Turn,
        appearingWithin    : Duration = .milliseconds(1500),
        body               : (SeatMenuInteraction) async -> Void = { _ in }
    ) async throws -> SeatMenuOutcome {

        guard menuContext == nil else {
            throw SessionFailure.contextMenuAlreadyOpen(
                processID: observation.recipient.processID
            )
        }
        let admitted        = try admitOrdinary(observation)
        let rightClick      = InputCommand.click(location, button: .right)
        let resolvedGesture = try inputEndpoint(for: rightClick, observation: observation)
        let endpoint        = resolvedGesture?.endpoint
        let window          = resolvedGesture?.surface ?? admitted
        let opener          = endpoint.map { rightClick.rebased(onto: $0.geometry) } ?? rightClick

        var openingTrace = InputTraceIdentity.submitted(
            command      : opener,
            window       : endpoint?.geometry.window ?? window.reference,
            correlationID: turn.correlationID
        )
        openingTrace.beginExecution(at: DispatchTime.now().uptimeNanoseconds)
        let record: WindowRecord
        do {
            record = try preflight(window, turn: turn, traceContext: &openingTrace)
        } catch {
            sender.recordCompletedTrace(
                openingTrace.completed(at: DispatchTime.now().uptimeNanoseconds)
            )
            throw error
        }
        // The menu belongs to the process the click reaches, so the oracle that
        // watches for it watches that one and not the window the pixels are of.
        let target = endpoint?.geometry.window ?? record.window.reference
        let classification = SurfaceInputClassification.of(
            observation,
            endpoint: endpoint,
            remoteAppKitPanelServiceQualified: endpoint.map {
                endpoints.qualifiedAppKitPanelService($0.identity)
            } ?? false
        )
        guard let openerPlatform = classification.platform(
            for                : opener,
            ofDrivenApplication: record.platform
        ) else {
            sender.recordCompletedTrace(
                openingTrace.completed(at: DispatchTime.now().uptimeNanoseconds)
            )
            throw SessionFailure.surfaceFamilyUnclassified(
                windowNumber: observation.role.attachedSheet?.windowNumber ?? target.windowNumber
            )
        }
        let previous = state
        actionInFlight = true
        transition(to: .acting, reason: .requested)
        defer {
            actionInFlight = false
            restoreActionState(previous, reason: .requested)
            // A window opened by the Command that has just finished is looked
            // for here, at the boundary, rather than a beat later.
            requestWindowFollow()
        }

        guard sensing.menuWindows(ownedBy: target.processID).isEmpty else {
            restoreActionState(previous, reason: .cancelled)
            throw SessionFailure.contextMenuAlreadyOpen(processID: target.processID)
        }

        let interactionStarted  = DispatchTime.now().uptimeNanoseconds
        let interactionDeadline = interactionStarted
            &+ observationProfile.menuInteractionNanoseconds

        let postedAt = ContinuousClock.now
        let opening : InputReceipt
        do {
            // The boundary before the first event of the opening Command.
            if let refusal = admissionRefusal(for: observation, expecting: .ordinaryTarget) {
                restoreActionState(previous, reason: .cancelled)
                throw refusal
            }
            if let endpoint, let retired = endpointInvalidation(of: endpoint) {
                restoreActionState(previous, reason: .cancelled)
                throw retired
            }
            openingTrace.beginQueue(at: DispatchTime.now().uptimeNanoseconds)
            opening = witnessed(
                try await sender.send(
                    opener,
                    to           : target,
                    correlationID: turn.correlationID,
                    platform     : openerPlatform,
                    traceContext : openingTrace,
                    beforeFirstPost: { [weak self] in
                        try await MainActor.run {
                            guard let self else { throw CancellationError() }
                            if let refusal = self.admissionRefusal(
                                for: observation,
                                expecting: .ordinaryTarget
                            ) {
                                throw refusal
                            }
                            if let endpoint, let retired = self.endpointInvalidation(of: endpoint) {
                                throw retired
                            }
                        }
                    }
                )
            )
        } catch {
            restoreActionState(previous, reason: .cancelled)
            throw error
        }
        // The parent's observation is spent by the opening Command and the menu
        // now scopes what may be sent. Neither of them comes back afterwards.
        observationIssuer.invalidate(.menuOpened)
        outstandingGeometry = nil

        var appeared: WindowReference?
        _ = await EventLoopWait.until(
            {
                appeared = self.sensing.menuWindows(ownedBy: target.processID).first
                return appeared != nil
            },
            timeout : appearingWithin,
            interval: .milliseconds(30)
        )
        guard let appeared, let menuIdentity = appeared.identity else {
            // A menu that arrives one sample after the deadline would otherwise
            // be a menu this action opened, walked away from and never closed,
            // which is the one outcome worse than failing. So the failure path
            // pulls the lever too: on a target with no menu the cycle is two
            // records and no visible effect, and on one whose menu came late it
            // is the close. Only if something is still there does the refusal
            // become the louder of the two.
            do {
                try await sender.cyclePreparation(on: target)
            } catch {
                if let failure = error as? InputPreparationFailure,
                   failure.progress.neededRecovery != nil {
                    report([.preparationNotRestored])
                }
                Self.log.error("""
                    the preparation cycle was refused after a menu-open timeout: \
                    \(String(describing: error), privacy: .public)
                    """)
            }
            _ = await EventLoopWait.until(
                { self.sensing.menuWindows(ownedBy: target.processID).isEmpty },
                timeout : .milliseconds(500),
                interval: .milliseconds(30)
            )
            restoreActionState(previous, reason: .cancelled)
            publishCoherentState()
            if let late = sensing.menuWindows(ownedBy: target.processID).first {
                report([.contextMenuLeftOpen])
                throw SessionFailure.contextMenuNotClosed(
                    menuWindowNumber: late.windowNumber,
                    processID       : target.processID
                )
            }
            throw SessionFailure.contextMenuNeverOpened(
                windowNumber: target.windowNumber,
                within      : appearingWithin
            )
        }
        let menu = ContextMenu(
            window       : appeared,
            appearedAfter: postedAt.duration(to: .now)
        )

        menuGeneration &+= 1
        let generation = menuGeneration
        menuContext = MenuContext(
            generation         : generation,
            parent             : observation.recipient,
            parentReference    : target,
            menu               : menu,
            menuIdentity       : menuIdentity,
            correlationID      : turn.correlationID,
            deadlineNanoseconds: interactionDeadline
        )
        publishCoherentState()

        await body(
            SeatMenuInteraction(
                parent             : observation.recipient,
                menu               : menu,
                deadlineNanoseconds: interactionDeadline,
                seat               : self,
                generation         : generation
            )
        )

        let expired      = DispatchTime.now().uptimeNanoseconds >= interactionDeadline
        let insideMenu   = menuContext?.receipts ?? []
        let itemWasChosen = !insideMenu.isEmpty

        // The context is revoked before the cleanup starts: from here on only
        // the kit's own closing runs, and no semantic Command is admitted.
        menuContext = nil
        observationIssuer.invalidate(.menuClosed)
        outstandingGeometry = nil

        let closedBy = await close(
            menu,
            of                : target,
            turn              : turn,
            itemWasChosen     : itemWasChosen,
            withinNanoseconds : observationProfile.menuCleanupNanoseconds
        )

        // A selected command may activate the target after the menu fades.
        // Keep observing through that delay, including for identified items.
        if itemWasChosen {
            _ = await EventLoopWait.until(
                { self.sensing.frontmostProcessID == target.processID },
                timeout : .milliseconds(800),
                interval: .milliseconds(30)
            )
        }
        if sensing.frontmostProcessID == target.processID {
            if let focusRecovery { focusRecovery.activationChanged(to: target.processID, source: .contextMenuPoll) }
            else { report([.targetActivated]) }
        }
        publishCoherentState()

        guard let closedBy else {
            report([.contextMenuLeftOpen])
            throw SessionFailure.contextMenuNotClosed(
                menuWindowNumber: menu.window.windowNumber,
                processID       : target.processID
            )
        }
        return SeatMenuOutcome(
            menu              : menu,
            opening           : opening,
            insideMenu        : insideMenu,
            interactionExpired: expired,
            cleanup           : .verifiedClosed(closedBy)
        )
    }

    /// Removed in the observation cutover, not deprecated: its choice closure was
    /// synchronous, it had no observation of the menu's own surface, and it bound
    /// the whole interaction to one 1500 ms deadline.
    ///
    /// Migration: `withContextMenu(openedAt:observation:turn:appearingWithin:body:)`,
    /// whose body receives a scoped `SeatMenuInteraction`.
    @available(
        *, unavailable,
        message: "Use withContextMenu(openedAt:observation:turn:appearingWithin:body:)"
    )
    @discardableResult
    public func useContextMenu(
        openedAt location: InputLocation,
        of window        : AdoptedWindow,
        turn             : Turn,
        within deadline  : Duration = .milliseconds(1500),
        choosing choose  : (ContextMenu) -> CGPoint? = { _ in nil }
    ) async throws -> ContextMenuReceipt {
        fatalError("unavailable")
    }

    /// Posts one Command inside the menu the given interaction scopes.
    ///
    /// The recipient is the menu's own window, which is where an item click has
    /// to land, and the reference must be an observation of that surface. The
    /// Receipt is recorded on the context so the outcome carries what went out
    /// even when a later step fails: an event that went out is never withdrawn.
    func sendInsideMenu(
        _ command  : InputCommand,
        observation: SeatObservationReference,
        generation : UInt64
    ) async throws -> InputReceipt {

        guard let context = menuContext, context.generation == generation,
              DispatchTime.now().uptimeNanoseconds < context.deadlineNanoseconds
        else { throw ObservationAdmissionRefusal.menuContextRevoked }

        guard let refusal = admissionRefusal(
            for     : observation,
            expecting: .transientMenu(parent: context.parent)
        ) else {
            // Routed to the **menu's** window and not to the target's, and posted
            // through a platform that prepares nothing: a Preparation applied now
            // would close the menu before the click reached it.
            let receipt = witnessed(
                try await sender.send(
                    command,
                    to           : context.menu.window,
                    correlationID: context.correlationID,
                    platform     : AppKitPlatform()
                )
            )
            menuContext?.receipts.append(receipt)
            observationIssuer.noteCommandCompleted()
            outstandingGeometry = nil
            publishCoherentState()
            return receipt
        }
        throw refusal
    }

    /// The Receipt of a Command the seat verified for itself, with the
    /// observation attached and nothing remembered as unconfirmed.
    ///
    /// It is `finish` without the bookkeeping, and the difference is the whole
    /// point: `finish` is for a Command whose effect only the consumer can see,
    /// and this is for one whose effect the window server told the seat about.
    /// The one thing it keeps is the Issue, because a Preparation the target
    /// refused to give back is a fact about the target and not about who
    /// verifies what.
    private func witnessed(_ receipt: InputReceipt) -> InputReceipt {

        let attached = receipt.attaching(observer?.observation())
        if receipt.hasUnrestoredPreparation { report([.preparationNotRestored]) }
        return attached
    }

    /// A point inside the menu's own window, in the two frames of reference a
    /// routed event needs.
    ///
    /// This is the one place the seat converts a coordinate, and the exception
    /// has a reason: every other window in the kit has an owner that publishes
    /// its own geometry, so converting for it could move a click by whatever the
    /// two readings disagree about. A menu window publishes nothing and is in no
    /// tree, so the window server's frame is not one of two readings, it is the
    /// only one there is.
    func pointInside(
        _ menu       : ContextMenu,
        at pointFromTop: CGPoint
    ) throws -> InputLocation {
        guard let geometry = sensing.windowGeometryObservation(of: menu.window),
              geometry.window.frame.size == menu.frame.size,
              let location = InputLocation(
                  screenPoint: CGPoint(
                      x: geometry.window.frame.minX + pointFromTop.x,
                      y: geometry.window.frame.minY + pointFromTop.y
                  ),
                  observedIn: geometry
              )
        else { throw InputFailure.currentCoordinateGeometryUnavailable }
        return location
    }

    /// Closes the menu, in the order the levers were measured in, and answers
    /// which one did it. `nil` means none of them did.
    ///
    /// The teardown's own events are deliberately **not** registered as
    /// unconfirmed Commands. The anti-replay invariant is about a Command whose
    /// effect only the consumer can verify; the effect of these two is "the menu
    /// is gone", which the seat verifies itself, here, before answering.
    /// `withinNanoseconds` is the separate cleanup budget, measured from here.
    /// Every wait below is clamped to what is left of it, so the levers are
    /// pulled in the order they were measured in and the whole cleanup still
    /// ends inside its own budget. Reaching the budget with the menu still there
    /// answers nil, which the caller turns into an explicit failure: it does not
    /// mean the menu closed and it does not mean a native call ended.
    private func close(
        _ menu           : ContextMenu,
        of target        : WindowReference,
        turn             : Turn,
        itemWasChosen    : Bool,
        withinNanoseconds: UInt64
    ) async -> ContextMenuReceipt.Closure? {

        let cleanupDeadline = DispatchTime.now().uptimeNanoseconds &+ withinNanoseconds

        // Any menu of the target, not only the one that was opened. Clicking an
        // item that carries a submenu closes the parent and opens a **new**
        // window at the same level, so a check against the original Window ID
        // would read "closed" with a submenu still on the screen. Nothing else
        // of the target's can be here: the action refused to start if one was.
        func isOpen() -> Bool {
            !sensing.menuWindows(ownedBy: target.processID).isEmpty
        }

        func remaining(upTo wanted: Duration) -> Duration? {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < cleanupDeadline else { return nil }
            let left = cleanupDeadline - now
            return min(wanted, .nanoseconds(Int64(min(left, UInt64(Int64.max)))))
        }

        // Choosing an item dismisses the menu, which is the ordinary ending. The
        // wait is not padding: the dismissal is the target's own animation and
        // not an answer to the click, measured at 457 ms on a native target and
        // under 400 ms on a browser. Too short and a menu that closed by itself
        // is closed a second time by a Preparation cycle nobody needed.
        if itemWasChosen, let budget = remaining(upTo: .milliseconds(700)),
           await EventLoopWait.until(
               { !isOpen() }, timeout: budget, interval: .milliseconds(30)
           ) {
            return .chosenItem
        }
        guard isOpen() else { return itemWasChosen ? .chosenItem : .dismissedItself }

        do {
            try await sender.cyclePreparation(on: target)
        } catch {
            if let failure = error as? InputPreparationFailure,
               failure.progress.neededRecovery != nil {
                report([.preparationNotRestored])
            }
            Self.log.error("""
                the preparation cycle was refused while closing a menu: \
                \(String(describing: error), privacy: .public)
                """)
        }
        if let budget = remaining(upTo: .milliseconds(500)),
           await EventLoopWait.until(
               { !isOpen() }, timeout: budget, interval: .milliseconds(30)
           ) {
            return .preparationCycle
        }
        guard remaining(upTo: .milliseconds(1)) != nil else { return nil }

        do {
            _ = try await sender.send(
                .key(virtualKey: Self.escapeKeyCode, text: "", modifiers: []),
                to           : target,
                correlationID: turn.correlationID,
                platform     : AppKitPlatform()
            )
        } catch {
            Self.log.error("""
                the escape was refused while closing a menu: \
                \(String(describing: error), privacy: .public)
                """)
        }
        if let budget = remaining(upTo: .milliseconds(500)),
           await EventLoopWait.until(
               { !isOpen() }, timeout: budget, interval: .milliseconds(30)
           ) {
            return .escapeKey
        }
        return nil
    }

    /// `kVK_Escape`, written out because a bare 53 inside a teardown is the kind
    /// of constant nobody rereads.
    private static let escapeKeyCode: CGKeyCode = 53

    /// confirm is the consumer's answer about one Command's effect.
    ///
    /// Confirmations follow the order of the sends, which a Turn guarantees:
    /// the hold is exclusive, so the Commands under it are strictly ordered. A
    /// Receipt that is not the oldest unconfirmed one is refused instead of
    /// matched by guesswork, because attributing an effect to the wrong Command
    /// is how a real action gets repeated.
    public func confirm(_ receipt: InputReceipt, _ effect: EffectConfirmation) throws {

        guard let index = posted.firstIndex(where: { $0.confirmation == nil }) else {
            throw SessionFailure.nothingToConfirm
        }

        guard posted[index].receipt == receipt else {
            throw SessionFailure.receiptOutOfOrder
        }

        posted[index].confirmation = effect
    }

    /// How many Commands of this hold are still unconfirmed. Zero is the
    /// condition `release(_ turn:)` needs.
    public var unconfirmedCommandCount: Int {
        posted.filter { $0.confirmation == nil }.count
    }

    // MARK: The observation

    /// What the seat has seen in the User Seat during this hold so far, without
    /// the cursor audit's verdict: reading that verdict ends the audit, and the
    /// audit spans the whole hold rather than one Command inside it.
    public var observation: SeatObservation? {
        guard let observer else { return observationSoFar }
        return (observationSoFar ?? SeatObservation()).merging(observer.observation())
    }

    /// concludeObservation closes the observed interval and answers it whole,
    /// cursor audit included.
    ///
    /// The wait in the middle is not padding. The tap's callbacks for the last
    /// sampled instant can still be in flight, and the audit reconciles a
    /// cursor reading against the HID event that explains it, so concluding
    /// without that grace period would report the person's own last movement as
    /// unexplained.
    @discardableResult
    public func concludeObservation() async -> SeatObservation? {

        guard let observer else { return observationSoFar }

        observer.finishCursorSampling()
        await EventLoopWait.step(.nanoseconds(CursorMotionAudit.deliveryPublicationLimit))

        let whole = (observationSoFar ?? SeatObservation()).merging(observer.conclude())

        self.observer         = nil
        self.observationSoFar = whole
        return whole
    }

    // MARK: The heartbeat, driven by the host's watchdog

    /// heartbeat is the seat's one periodic duty, and it is deliberately almost
    /// nothing: at rest the seat reads nothing at all.
    ///
    /// A seat that is `ready` has no invariant to re-check on a timer. Its
    /// guard runs immediately before each Command, where the answer matters,
    /// and the observer runs during a hold, where movement matters. Polling it
    /// in between would buy nothing and cost the idle budget.
    ///
    /// The one state that needs a beat is `waiting`. The person is in the
    /// target application and the seat suspended with no deadline; the only way
    /// out other than cancellation is the application going back to the
    /// background, and nothing publishes that in a form the seat can wait on.
    func heartbeat() {

        // The window watch's periodic half rides this beat instead of adding a
        // timer, and the pass's own stand-down decides whether it may run.
        requestWindowFollow()
        refreshFocusPreparation()

        if focusRecovery?.isPaused == true { return }

        guard state == .waiting, let target = seatGuard?.target else { return }

        switch sensing.isActive(processID: target.processID) {

            case nil:
                report([.processUnavailable])

            case false:
                transition(
                    to    : wasDegradedBeforeRecovery ? .degraded : .ready,
                    reason: .targetWentInactive
                )

            case true:
                break
        }
    }

    /// Fails the seat because the host it lives on failed. The Issues are the
    /// host's, and the caller is the host: a seat cannot decide this for
    /// itself, because the display and the fence are not its own.
    func failFromHost(_ issues: [SeatIssue]) {

        reportStrandedKeys()
        stopFocusRecovery()
        stopWindowFollowing()

        recoveryTask?.cancel()
        recoveryTask = nil
        endAssignmentAndObservation(reason: .lifecycleChanged)
        transition(to: .failed, reason: .issues(issues))
        turns.failAll(with: SeatInterruption(issues: issues))
        publishCoherentState()
    }

    /// Lets every window go, best effort, and answers what happened to each.
    /// Used by the host's teardown, including the fail-closed one, where the
    /// point is the report: the person has to be told which windows did not
    /// make it back.
    func releaseAllWindows(_ mode: ReleaseMode) async -> [Int: WindowReleaseOutcome] {

        reportStrandedKeys()
        isTearingDown = true
        if let context = nativeTextInputContext,
           let preparing = sender as? any NativeTextInputPreparing {
            let cleanup = await preparing.cancelNativeTextInput(correlationID: context.turn.correlationID)
            if cleanup.needsRecovery { report([.preparationNotRestored]) }
        }
        stopWindowFollowing()
        if adoptionInFlight {
            await withCheckedContinuation { adoptionWaiters.append($0) }
        }
        // Seeded with what the seat has already answered for, so the final
        // report carries the windows a coordinated release closed instead of
        // starting from nothing and saying none was ever held.
        var outcomes = releaseLedger.merging(adoptionRestorations) { _, restoration in restoration }
        for id in pendingAdoptions.keys.sorted() {
            guard let window = pendingAdoptions[id] else { continue }
            outcomes[id] = (await restorePendingAdoption(window))?.outcome ?? .refused
        }
        pendingAdoptions.removeAll()
        adoptionRestorations.removeAll()

        for window in adoptedWindows {
            outcomes[window.id] = await release(window, mode)
        }
        // The stop revokes input authority before anything else, and what the
        // returns did not finish stays an explicit obligation of the host.
        endAssignmentAndObservation(reason: .lifecycleChanged)
        publishCoherentState()

        return outcomes
    }

    // MARK: Following the application's own windows

    /// How long the seat waits between two passes of a burst. The wake-up leads
    /// the window server by 79 to 249 ms measured, and a candidate needs two
    /// agreeing readings, so a cadence of 120 ms puts the second reading past
    /// the longest measured lead on the third pass.
    private static let windowFollowInterval = Duration.milliseconds(120)

    /// A delayed Qt child has already appeared on the physical display by
    /// the time the ordinary follow pass sees it. The bounded post-click tail
    /// samples more often without changing the idle or other-family cadence.
    private static let anticipatedWindowFollowInterval = Duration.milliseconds(60)

    /// The longest burst one wake-up may cause: ten passes at 120 ms covers
    /// 1,2 s, which is four times the longest lead measured. The cap is what
    /// makes a wake-up that arrives every beat cost a bounded amount of work
    /// instead of an unbounded one.
    private static let maximumWindowFollowPasses = 10
    private static let maximumAnticipatedWindowFollowPasses = 20

    /// Starts following the windows of the applications this seat drives.
    /// Installed only through a host configured for it; a seat that was never
    /// asked takes no reading of anybody's windows.
    func enableWindowFollowing() {

        guard windowWatch == nil, !isTearingDown else { return }
        windowWatch = AppWindowWatch(created: { [weak self] in
            self?.requestWindowFollow()
            self?.refreshFocusPreparation()
        })
        refreshWindowFollowing()
    }

    /// Stops it, whole: the burst, the accessibility observers and the
    /// inventory. A notification already on its way in finds a dropped closure
    /// and does nothing, which is what "no watch acts after the control is
    /// given back" means in code.
    func stopWindowFollowing() {

        windowFollowTask?.cancel()
        windowFollowTask  = nil
        windowFollowAgain = false
        windowFollowUntil = nil
        windowWatch?.stop()
        windowWatch     = nil
        windowInventory = AppWindowInventory()
    }

    /// Reconciles the observed processes with the ones the seat still holds
    /// windows of, and takes the baseline for whichever of them is new.
    ///
    /// The baseline belongs here and not in the first pass, because here is the
    /// moment the seat starts driving a process and therefore the moment
    /// "already there" is defined. A pass runs whenever the main actor is next
    /// free, which on a busy caller is long enough for the application to have
    /// opened the very window the feature is about.
    private func refreshWindowFollowing() {

        guard let windowWatch else { return }
        windowWatch.follow(session.processIDs)

        let processes = session.processIdentities
        guard !processes.isEmpty else { return }
        windowInventory.baseline(
            surfaces : sensing.windowSurfaces(ownedBy: Set(processes.map(\.processID))),
            processes: processes
        )
    }

    /// Asks for a pass. Every wake-up arrives here: the accessibility
    /// notification, the boundary of a finished Command and the heartbeat.
    ///
    /// Passes are coalesced into one task rather than queued. A second wake-up
    /// while a burst is running sets a flag the burst reads, so however many
    /// wake-ups arrive there is at most one task, and it ends after a bounded
    /// number of passes whatever keeps arriving.
    private func requestWindowFollow(through horizon: Duration = .zero) {

        guard windowWatch != nil, !isTearingDown, state != .failed else { return }
        if horizon > .zero {
            let until = ContinuousClock.now.advanced(by: horizon)
            if windowFollowUntil.map({ $0 < until }) ?? true {
                windowFollowUntil = until
            }
        }
        guard windowFollowTask == nil else {
            windowFollowAgain = true
            return
        }

        windowFollowTask = Task { @MainActor [weak self] in
            var passes = 0
            var maximumPasses = Self.maximumWindowFollowPasses
            while let self, !Task.isCancelled {
                self.windowFollowAgain = false
                await self.runWindowFollowPass()
                passes += 1

                let anticipating = self.windowFollowUntil.map {
                    ContinuousClock.now < $0
                } == true
                if anticipating {
                    maximumPasses = Self.maximumAnticipatedWindowFollowPasses
                }

                guard passes < maximumPasses, !Task.isCancelled,
                      self.windowWatch != nil, !self.isTearingDown,
                      self.windowFollowAgain || self.windowInventory.hasPendingCandidate
                          || anticipating
                else { break }

                await EventLoopWait.sleep(
                    anticipating ? Self.anticipatedWindowFollowInterval
                                 : Self.windowFollowInterval
                )
            }
            guard let self, !Task.isCancelled else { return }
            self.windowFollowTask = nil
            self.windowFollowUntil = nil
        }
    }

    /// One pass: read the window server for the driven processes, fold it into
    /// the inventory, act on what changed.
    ///
    /// The refusals in front are the whole coordination story. Nothing is read
    /// or moved while a Command or a contextual menu action is in flight, while
    /// an adoption is already running, or while a focus request is in flight and
    /// unverified: the pass is skipped and the next wake-up finds the same
    /// window, which is why a detection during a menu action never waits for the
    /// menu action to end. A recovery that is only waiting for the person is not
    /// a refusal: it ends when they act, and standing the pass down on it would
    /// leave the application's popup on their own display until then.
    ///
    /// The last two refusals are the person's. A physical click or application
    /// switch observed in the last third of a second is deliberate input, read
    /// from the event the focus watch latched and not from a PID; and a driven
    /// application that is active is an ambiguous seat whoever put it in front,
    /// so the pass stands down rather than moving windows underneath whoever
    /// did. Neither is inferred from the frontmost PID on its own.
    /// It is not private so that a test can run one pass and know the answer,
    /// instead of scheduling one and waiting for a task to be given the main
    /// actor: every suite here shares that actor, and a wait long enough to
    /// survive the contention is a wait long enough to hide a defect.
    func runWindowFollowPass() async {

        let scope = windowFollowScope()
        if let held = scope.heldBackReason {
            // Once per distinct reason: the pass runs on a cadence, and a line
            // per tick would bury the reason it is reporting.
            if held != lastWindowFollowStandDown {
                lastWindowFollowStandDown = held
                let did = scope.isStandDown ? "stood down" : "reconciles only"
                Self.log.notice("""
                    the window follow pass \(did, privacy: .public): \(held, privacy: .public)
                    """)
            }
            if scope.isStandDown { return }
            // Reconciliation is what the suspension does not stop: a reading
            // and the registers it settles, with nothing moved, adopted or
            // given back. Without it a window that really went away stays in
            // the registers for as long as the person keeps the focus, and the
            // recovery that is waiting for those registers waits on the pass
            // that is waiting for the recovery.
            foldCurrentReading()
            publishCoherentState()
            return
        }
        lastWindowFollowStandDown = nil

        // A driven application that is active used to stand the pass down. It
        // was the wrong reading of the same evidence: the applications this
        // seat drives activate themselves precisely when they open the window
        // the pass exists to find, so the rule left every dialog and every
        // window an agent's own Command opened outside the seat, on the
        // person's display, for as long as it held focus. What tells the
        // person's intent from the application's own is the physical evidence
        // above — a click or an app-switch shortcut in the last third of a
        // second — and that guard is unchanged, as are the hold, the action in
        // flight, a teardown, and a focus recovery still restoring.
        let processes = session.processIdentities
        windowFollowPassInFlight = true
        defer { windowFollowPassInFlight = false }
        windowFollowScanCount += 1
        let surfaces = sensing.windowSurfaces(ownedBy: Set(processes.map(\.processID)))
        // The level is the reading's and is kept for the evidence line: it is
        // not carried by a change, and re-reading it per candidate would cost.
        let levels = Dictionary(
            (surfaces ?? []).map { ($0.reference.windowNumber, $0.level) },
            uniquingKeysWith: { first, _ in first }
        )
        let changes = windowInventory.changes(
            surfaces : surfaces,
            processes: processes,
            adopted  : Set(session.records.keys),
            within   : sensing.virtualDisplayBounds,
            menuLevel: WindowServerProbe.popUpMenuLevel
        )

        for change in changes {
            guard !isTearingDown else { return }
            switch change {

                case .appeared(let window), .reappeared(let window):
                    guard state.acceptsCommands || containmentOnlyFollowWait
                            || selectedModalRecoveryMayAdmit(window)
                    else {
                        windowInventory.offerAgain(window.windowNumber)
                        continue
                    }
                    await transferDetectedWindow(window, level: levels[window.windowNumber])

                case .appearedInVirtualDisplay(let window):
                    guard state.acceptsCommands || containmentOnlyFollowWait
                            || selectedModalRecoveryMayAdmit(window)
                    else {
                        windowInventory.offerAgain(window.windowNumber)
                        continue
                    }
                    await ownWindowBornInSeat(window, level: levels[window.windowNumber])

                case .leftVirtualDisplay(let window):
                    guard state.acceptsCommands || containmentOnlyFollowWait
                    else { continue }
                    returnAdoptedWindow(window)

                case .vanished(let windowNumber):
                    guard state.acceptsCommands || containmentOnlyFollowWait
                    else { continue }
                    // One missing reading is not a destruction, and the proof
                    // is the recovery budget, which is the target's own.
                    if session.currentTargetNumber == windowNumber, !isHiddenInPlace(windowNumber) {
                        report([.windowUnavailable], cause: .windowClosure(.absentFromReading))
                    }
            }
        }
    }

    /// Whether a target that left the on-screen list is still the window server's
    /// row, with its identity and its frame: ordered out where it stood, which
    /// is how a Qt dialog closes. Recovery moves windows back into place, and
    /// there is nothing to move; waiting on it held a seat in `recovering`
    /// until the session was closed. The selection answers it instead: the
    /// transition filter withdraws such a window once it has stayed off screen,
    /// and the seat follows the selection to the window underneath.
    private func isHiddenInPlace(_ windowNumber: Int) -> Bool {
        guard let record = session[windowNumber] else { return false }
        guard let server = sensing.windowGeometry(of: windowNumber) else {
            return sensing.windowIsOrderedOut(record.window.reference)
        }
        return server.hasSameIdentity(as: record.window.reference)
            && VirtualWindowPlacementCheck.framesMatch(server.frame, record.window.reference.frame)
    }

    /// Gives an observation request a bounded join point with the same window
    /// follower that owns newly created windows. The first pass is a sighting;
    /// only a second agreeing pass may transfer a candidate. Joining here keeps
    /// assignment containment from racing ahead and asking its deliberately
    /// unqualified direct effector to move a popup the seat can instead adopt,
    /// confirm, register and later return through its existing lifecycle.
    func settleWindowFollowingForObservation(until deadlineNanoseconds: UInt64) async {

        guard windowWatch != nil,
              await waitForWindowFollowPass(until: deadlineNanoseconds)
        else { return }

        await runWindowFollowPass()
        guard windowInventory.hasPendingCandidate,
              await waitForWindowFollowPass(until: deadlineNanoseconds)
        else { return }

        await Task.yield()
        guard await waitForWindowFollowPass(until: deadlineNanoseconds)
        else { return }
        await runWindowFollowPass()
        _ = await waitForWindowFollowPass(until: deadlineNanoseconds)
    }

    /// Takes into the seat the windows the assigned application already had
    /// open outside it when it was handed over, once the assignment nucleus
    /// has planned their containment and its unqualified effector refused it.
    ///
    /// ## Why the follower is not the one
    ///
    /// An explicitly assigned application is entrusted whole, so the handover
    /// reading records every window it had as a pre-existing member and plans
    /// to move each one that stands outside. The follower was built for the
    /// opposite reading of the same moment: a window already there is in its
    /// baseline and it never takes it. Between the two nobody moved the window,
    /// its containment deadline ran out, and the first observation suspended
    /// the seat. Measured on DaVinci Resolve with a New Project dialog left
    /// open after a crash, the same dialog the follower adopts without a word
    /// when it opens during a session.
    ///
    /// ## What it takes, and through what
    ///
    /// A member of the assigned instance itself, recorded at the handover, that
    /// two agreeing readings put outside the seat, whose move the nucleus
    /// refused as `adapterNotQualified`, that is not drawn inside a host and
    /// that the seat does not hold yet. Nothing else: a window of another
    /// process or of a helper and a surface the nucleus does not count as a
    /// member are left where they are, and a window born during the
    /// assignment is the follower's.
    ///
    /// It moves nothing the follower would not move at this moment: the pass's
    /// own scope has to be full, so the person's recent physical intent, a
    /// focus restore in flight or a transfer already running hold it back the
    /// same way. The one difference is that it runs without a window watch,
    /// because the assignment reader found these members either way and the
    /// seat cannot be observed until they are contained.
    ///
    /// It goes through `transferDetectedWindow`, the follower's own entry to
    /// the detected-window transaction, so every refusal of that path stands:
    /// fullscreen, not movable, too large to shrink, attempts exhausted. The
    /// record it makes owes the frame the window was found at, which is what
    /// the release gives back to a window the person already had open.
    func takeInRefusedPreexistingMembers(until deadlineNanoseconds: UInt64) async -> ObservationUnavailable? {

        guard let assignment = assignmentKit.lifecycle.current,
              let blocks     = selectionKit.lastAssignmentStatus?.blocks
        else { return nil }

        let selectedBeforeContainment = selectionKit.selected?.surface
        var movedAnotherWindow = false
        let refused = blocks.compactMap { block -> Int? in
            guard case .effectRefused(let number, .adapterNotQualified) = block else { return nil }
            return number
        }
        for number in refused {
            // Read again before each one: a transfer awaits, and the person
            // may have acted in the meantime.
            guard !Task.isCancelled,
                  DispatchTime.now().uptimeNanoseconds < deadlineNanoseconds,
                  case .full = windowFollowScope(requiringWatch: false),
                  state.acceptsCommands || containmentOnlyFollowWait
            else { return nil }
            guard let member = assignmentKit.inventory.surfaces[number],
                  member.identity.process == assignment.instance,
                  member.origin == .preexisting,
                  member.presence == .outsideSeat,
                  member.isVerified,
                  !member.isAttachedToHost,
                  session[number] == nil
            else { continue }

            Self.log.notice("""
                window \(number, privacy: .public) was already open outside the seat when the \
                application was handed over and its direct move was refused: taking it in
                """)
            await transferDetectedWindow(member.reference, level: nil)
            if session[number]?.window.reference.identity == member.identity,
               member.identity != selectedBeforeContainment {
                movedAnotherWindow = true
            }
        }

        // A window a previous seat left where its display stood: a dialog born
        // there is given back to the frame it was born at, and the next display
        // takes the same rectangle. It is contained already, so nothing plans
        // its move, and it is in the follower's baseline, so nothing adopts it:
        // measured with DaVinci Resolve's Import Media panel, selected and never
        // owned. It is owned in place, as a window born in the seat would be.
        let containedUnowned = assignmentKit.inventory.surfaces.values
            .filter {
                $0.identity.process == assignment.instance
                    && $0.origin == .preexisting
                    && $0.presence == .containedInSeat
                    && $0.isVerified
                    && !$0.isAttachedToHost
                    && session[$0.reference.windowNumber] == nil
            }
            .map(\.reference)
            .sorted { $0.windowNumber < $1.windowNumber }
        for reference in containedUnowned {
            guard !Task.isCancelled,
                  DispatchTime.now().uptimeNanoseconds < deadlineNanoseconds,
                  case .full = windowFollowScope(requiringWatch: false),
                  state.acceptsCommands || containmentOnlyFollowWait,
                  session[reference.windowNumber] == nil
            else { return nil }
            Self.log.notice("""
                window \(reference.windowNumber, privacy: .public) was already on the virtual \
                display when the application was handed over, owned by no seat: taking it in place
                """)
            await ownWindowBornInSeat(reference, level: nil)
        }
        // Containment can put another held window above the selected one. Its
        // application-wide AX hit test would then name that other window.
        guard movedAnotherWindow,
              let selected = selectedBeforeContainment,
              selectionKit.selected?.surface == selected,
              selectionKit.attachedHost(of: selected) == nil,
              let record = session[selected.windowNumber],
              record.window.reference.identity == selected
        else { return nil }
        guard !Task.isCancelled,
              DispatchTime.now().uptimeNanoseconds < deadlineNanoseconds,
              case .full = windowFollowScope(requiringWatch: false),
              state.acceptsCommands || containmentOnlyFollowWait
        else { return nil }
        do { _ = try await stage(record.window) }
        catch {
            return .captureFailed(
                reason: "the selected window could not be staged after containment: \(String(describing: error))"
            )
        }
        return nil
    }

    /// Waits for the one notification or observation pass that owns the
    /// follower. Actor reentrancy lets another pass start at every `await`, so
    /// the observation bridge joins before both reads and once more before it
    /// returns to assignment folding.
    private func waitForWindowFollowPass(until deadlineNanoseconds: UInt64) async -> Bool {

        repeat {
            guard !Task.isCancelled,
                  DispatchTime.now().uptimeNanoseconds < deadlineNanoseconds
            else { return false }
            guard windowFollowPassInFlight else { return true }
            await EventLoopWait.step(.milliseconds(10))
        } while true
    }

    /// Brings one detected window onto the Virtual Display, or says why it
    /// stays where it is.
    ///
    /// The accessibility body is read before anything is written, and it pays
    /// for itself twice. It is the size to preserve: the window server
    /// publishes a Stage Manager thumbnail for a stashed window, and centring
    /// by a thumbnail's size is how a window ends up hanging off the display.
    /// And the same read is the answer to "can this be moved at all": a surface
    /// with no window element behind its Window ID has nothing to write
    /// `AXPosition` on, which is the ordinary shape of an external popup, and
    /// saying so costs one reading instead of a failed move and a rollback.
    private func transferDetectedWindow(_ candidate: WindowReference, level: Int?) async {

        guard let fresh = sensing.windowGeometry(of: candidate.windowNumber),
              fresh.hasSameIdentity(as: candidate)
        else { return }

        noteDetectedSurface(fresh, level: level)

        // MW-03's three answers, decided before an attempt is spent, because
        // two of them are permanent facts about the window and the third is
        // about the moment.
        //
        // `fullScreenSpaceStillOnScreen` is silent and costs nothing: it is a
        // "come back later", the next pass is the retry, and a window the
        // person is looking at right now will be transferable the moment they
        // look away. Spending attempts on it would exhaust the budget in three
        // passes and refuse the window for good, a third of a second before it
        // became movable.
        //
        // The read itself is behind the experiment, and that is a cost
        // decision: it is an accessibility round trip per candidate per pass,
        // and a seat that was not asked to handle fullscreen should not pay it
        // once a second. With the experiment off the ordinary path still names
        // the case, from inside the one attempt it makes.
        if transfersFullScreenWindows,
           let reading = try? placing.fullScreen(of: fresh), reading.isNativeFullScreen {
            guard case .writable = reading else {
                refuseTransfer(fresh, .fullScreenNotSupported)
                _ = windowInventory.mayAttempt(candidate.windowNumber)
                return
            }
            // Postponed, not refused, and therefore silent: this is a fact
            // about the moment and not about the window, and the next pass is
            // the retry. It is the one answer here that publishes no event, so
            // the reason a window is waiting is thinner than the others.
            guard !placing.spaceIsOnScreen(for: fresh) else {
                windowInventory.offerAgain(candidate.windowNumber)
                return
            }
        }

        guard windowInventory.mayAttempt(candidate.windowNumber) else {
            refuseTransfer(fresh, .attemptsExhausted)
            return
        }

        let body: CGRect?
        do { body = try placing.frame(of: fresh) }
        catch {
            refuseTransfer(fresh, .notMovable)
            return
        }
        guard let body, body.width > 0, body.height > 0 else {
            refuseTransfer(fresh, .notMovable)
            return
        }

        let bounds = sensing.virtualDisplayBounds
        var adopting = body
        var owed     : CGRect?
        if body.width > bounds.width || body.height > bounds.height {
            // The numbers first: this is the one refusal a consumer answers by
            // choosing a different display, and how much larger the window is
            // is the whole of what it needs to know.
            Self.log.notice("""
                window \(fresh.windowNumber, privacy: .public) is \
                \(Int(body.width), privacy: .public)x\(Int(body.height), privacy: .public) \
                and the virtual display is \
                \(Int(bounds.width), privacy: .public)x\(Int(bounds.height), privacy: .public)
                """)
            guard let shrunk = shrinkToFit(fresh, body: body, within: bounds) else {
                refuseTransfer(fresh, .tooLarge)
                return
            }
            adopting = shrunk
            owed     = body
        }

        do {
            _ = try await integrateDetectedWindow(
                fresh.replacingFrame(adopting),
                platform   : platformForDetected(fresh),
                restoringTo: owed
            )
        } catch {
            refuseTransfer(fresh, Self.refusal(for: error))
            Self.log.error("""
                window \(fresh.windowNumber, privacy: .public) was detected and not transferred: \
                \(String(describing: error), privacy: .public)
                """)
        }
    }

    /// Takes ownership of a window that was born on the Virtual Display,
    /// exactly where it stands.
    ///
    /// macOS opens a new window where the application's active window is, so a
    /// window the driven application opens while the agent works in the seat is
    /// born inside it. The reading finds it in the seat and it becomes a held
    /// member, and without an adoption it is a held member nobody owns: no
    /// consumer release loop iterates it, containment has no move to make for a
    /// window already contained, and `releaseAssignedApplication` then refuses
    /// for a window that is genuinely stranded on a display the person cannot
    /// see. This is the owner that was missing.
    ///
    /// Nothing is moved and no attempt is spent. The attempt budget bounds an
    /// application that keeps putting its own window back after a transfer, and
    /// there is no transfer here to disagree with.
    ///
    /// What the window is owed on its return is the frame it was born at, which
    /// is on the Virtual Display: a window opened during an assignment has no
    /// place in the User Seat to go back to, and the destination is the
    /// consumer's, exactly as `SurfaceOrigin.bornDuringAssignment` says.
    package func ownWindowBornInSeat(_ candidate: WindowReference, level: Int?) async {

        guard let fresh = sensing.windowGeometry(of: candidate.windowNumber),
              fresh.hasSameIdentity(as: candidate)
        else { return }

        // Before the platform is chosen and before the adoption records what
        // this surface owes: both read the tree, and only a fold reads it.
        foldCurrentReading()
        noteDetectedSurface(fresh, level: level)

        do {
            _ = try await integrateDetectedWindow(
                fresh,
                platform    : platformForDetected(fresh),
                takenInPlace: true
            )
        } catch {
            refuseTransfer(fresh, Self.refusal(for: error))
            Self.log.error("""
                window \(fresh.windowNumber, privacy: .public) was born on the virtual display \
                and could not be adopted: \(String(describing: error), privacy: .public)
                """)
        }
    }

    /// The platform a window the follower found is driven with: the one the
    /// seat already holds for that same application, and the configuration's
    /// own default when this is the first window of it.
    ///
    /// Both detection entries ask this, because they are the same decision.
    /// They used to disagree, one taking the host's default and the other a
    /// hardcoded `ChromiumPlatform`, and neither had anything to do with the
    /// application the window belongs to: a dialog opened by a native
    /// application was prepared with the Chromium recipe, which makes that
    /// application believe it is active and takes the focus off the person.
    ///
    /// ## A sheet is not AppKit by rule any more
    ///
    /// A surface published as a modal attached to one of the application's
    /// windows used to be answered with `AppKitPlatform` here, whatever the
    /// application was. The role says which window blocks which and says
    /// nothing about the toolkit behind the one the events reach: Electron
    /// presents web content through `beginSheet`, and Qt draws a file dialog
    /// with the native panel or with its own widgets. So the window keeps its
    /// own application's family, and what a Command on a modal surface is
    /// actually posted with is decided per Command from the endpoint the
    /// gesture attests. See `SurfaceInputClassification`.
    func platformForDetected(_ window: WindowReference) -> any InputPlatform {
        session.platform(drivingSameInstanceAs: window) ?? defaultPlatform
    }

    /// Says what a detected surface is before anything is adopted: the Window
    /// ID, the size in points, the window server level, and the verdict the
    /// selection nucleus holds for it.
    ///
    /// This is the whole evidence of a detection nobody asked for. An auxiliary
    /// surface measured at 33 by 10 points took the operating target on a live
    /// run and none of those facts was recorded anywhere, so the refusal that
    /// followed described the observation and never the window that broke it.
    /// One line per candidate and not per pass: a seat finding nothing stays
    /// silent.
    private func noteDetectedSurface(_ window: WindowReference, level: Int?) {

        let verdict: String
        if let identity = window.identity, assignmentKit.lifecycle.isAssigned {
            let status = selectionKit.status()
            verdict = status.candidates.contains(identity)
                ? "a candidate"
                : status.ineligible[identity].map { String(describing: $0) } ?? "not a member yet"
        } else {
            verdict = window.identity == nil ? "an unattested identity" : "no assignment yet"
        }
        Self.log.notice("""
            window \(window.windowNumber, privacy: .public) was detected at \
            \(Int(window.frame.width), privacy: .public) by \
            \(Int(window.frame.height), privacy: .public) pt, level \
            \(level.map { "\($0)" } ?? "unread", privacy: .public), and the selection \
            nucleus holds it as \(verdict, privacy: .public)
            """)
    }

    /// Why a detected window stayed where it is, keeping the fullscreen answers
    /// apart from a refused move. They are different facts for the person
    /// reading the event stream: one is a window this seat was not asked to
    /// handle, one is a window macOS will not let go of, one is a moment that
    /// costs too much, and only the last is an attempt that failed.
    private static func refusal(for error: any Error) -> WindowTransferRefusal {
        if case .fullScreenTransferDisabled = error as? SessionFailure {
            return .fullScreenTransferDisabled
        }
        switch error as? DisplayFailure {
            case .fullScreenStateUnreadable, .fullScreenNotSettable:
                return .fullScreenNotSupported
            case .fullScreenSpaceStillOnScreen:
                return .fullScreenSpaceStillOnScreen
            default:
                return .moveRefused
        }
    }

    /// Puts a window the seat already holds back where it put it.
    ///
    /// The operating target goes through the seat's own bounded recovery,
    /// which is the machinery that already answers a window that moved and
    /// already refuses to relocate while a Command is in flight. Any other held
    /// window is written straight back to the origin its placement was
    /// confirmed at, under the watch's own attempt budget, because a recovery
    /// episode is about the window the guard is fixed to and would answer for
    /// the wrong one.
    ///
    /// The target is answered **before** that budget is consulted, and the
    /// order is the whole point. The recovery is the seat's safeguard and it
    /// carries a budget of its own; spending the watch's budget on it as well
    /// would let a handful of readings switch the safeguard off for good.
    private func returnAdoptedWindow(_ window: WindowReference) {

        guard let record = session[window.windowNumber],
              record.window.reference.hasSameIdentity(as: window)
        else { return }

        guard session.currentTargetNumber != window.windowNumber else {
            report([.geometryChanged])
            return
        }

        guard windowInventory.mayAttempt(window.windowNumber) else {
            refuseTransfer(window, .attemptsExhausted)
            return
        }

        do { try placing.move(window, to: record.window.reference.frame.origin) }
        catch {
            refuseTransfer(window, .moveRefused)
            Self.log.error("""
                window \(window.windowNumber, privacy: .public) left the virtual display and \
                could not be put back: \(String(describing: error), privacy: .public)
                """)
        }
    }

    /// Shrinks a window that does not fit the Virtual Display and answers the
    /// body it ends up with, nil when it still does not fit.
    ///
    /// The write is not the answer: an application with a minimum size accepts
    /// it and keeps what it had, and one that refuses the attribute throws. Both
    /// are the same conclusion here — this window cannot be given the seat — and
    /// the window's own next reading is what says which happened. What the
    /// person is owed is unaffected: the frame from before this call is recorded
    /// as the adoption's original and written back on the return.
    private func shrinkToFit(
        _ window     : WindowReference,
        body         : CGRect,
        within bounds: CGRect
    ) -> CGRect? {

        let size = CGSize(
            width : min(body.width, bounds.width),
            height: min(body.height, bounds.height)
        )
        do { try placing.resize(window, to: size) }
        catch {
            Self.log.notice("""
                window \(window.windowNumber, privacy: .public) would not be resized: \
                \(String(describing: error), privacy: .public)
                """)
            return nil
        }
        guard let current = ((try? placing.frame(of: window)) ?? nil),
              current.width > 0, current.height > 0,
              current.width <= bounds.width, current.height <= bounds.height
        else { return nil }
        return current
    }

    private func refuseTransfer(_ window: WindowReference, _ reason: WindowTransferRefusal) {
        Self.log.notice("""
            window \(window.windowNumber, privacy: .public) was not brought in: \
            \(String(describing: reason), privacy: .public)
            """)
        eventChannel.yield(
            .windowTransferRefused(
                windowNumber: window.windowNumber,
                processID   : window.processID,
                reason      : reason
            )
        )
    }

    // MARK: The preflight

    /// Everything that has to be true before an event goes out, in the order it
    /// has to be true in.
    ///
    /// The stash is answered before the guard of Core, because it is the finer
    /// fact about the same reading: a window Stage Manager stashed also reads at
    /// a geometry the record disagrees with, and answering that first would
    /// report `geometryChanged` and send a bounded recovery after a window that
    /// only has to be staged. Every fold reads staging back, so the flag this
    /// reads is the window server's answer and not the adoption's memory.
    private func preflight(
        _ window    : AdoptedWindow,
        turn        : Turn,
        traceContext: inout InputTraceContext
    ) throws -> WindowRecord {

        focusRecovery?.rememberUserWindow()

        guard let current = turns.current, current == turn else {
            throw SessionFailure.turnRequired
        }

        guard let record = session[window.id] else {
            throw SessionFailure.windowNotAdopted(windowNumber: window.id)
        }

        guard !isTearingDown, state.acceptsCommands else { throw SessionFailure.seatNotReady(state) }

        // Recovery follows the requested adopted window, never a surface that
        // owes no return: closing a sheet is the ordinary end of using one.
        if let baseline = seatGuard, !record.window.owesNoReturn {
            seatGuard = SeatGuard(
                target       : record.window.reference,
                displayID    : baseline.displayID,
                displayBounds: baseline.displayBounds
            )
        }
        guard record.isStaged else {
            // The window is a Stage Manager thumbnail. Posting into a thumbnail
            // sends the events to coordinates the window does not occupy, so
            // this is a refusal and not a silent stage: staging is half a
            // second of animation and the caller has to know it happened.
            report([.windowStashed])
            throw SeatInterruption(issues: [.windowStashed])
        }

        let verificationStart = DispatchTime.now().uptimeNanoseconds
        let issues = currentIssues(for: record)
        traceContext.recordWindowVerification(
            from   : verificationStart,
            through: DispatchTime.now().uptimeNanoseconds
        )
        guard issues.isEmpty else {
            report(issues)
            throw SeatInterruption(issues: issues)
        }

        beginObservationIfNeeded(for: record, turn: turn)
        return record
    }

    /// The Issues the current readings show, using the guard of Core: one
    /// comparison, no system call inside it, the same one a test runs.
    private func currentIssues(for record: WindowRecord) -> [SeatIssue] {

        guard let seatGuard else { return [.windowUnavailable] }

        let windowGuard = SeatGuard(
            target       : record.window.reference,
            displayID    : seatGuard.displayID,
            displayBounds: seatGuard.displayBounds
        )
        return windowGuard.issues(
            server              : sensing.windowGeometry(of: record.window.id),
            currentDisplayID    : displayID,
            currentDisplayBounds: sensing.virtualDisplayBounds,
            displayIsOnline     : sensing.virtualDisplayIsOnline,
            cursorFenceIsActive : sensing.fenceIsActive,
            targetIsActive      : sensing.isActive(processID: record.window.reference.processID),
            frontmostProcessID  : sensing.frontmostProcessID
        )
    }

    /// The Receipt with the observation attached, the Command remembered as
    /// unconfirmed, and the state back where it was.
    private func finish(_ receipt: InputReceipt, returningTo previous: SeatState) -> InputReceipt {

        let attached = receipt.attaching(observer?.observation())

        posted.append(PostedCommand(receipt: attached, confirmation: nil))

        // A Preparation the target refused to give back. The events went out,
        // so this is never an error: it is an Issue, and the seat says it is
        // degraded and keeps working. The next Preparation on that
        // window resets the state.
        if receipt.hasUnrestoredPreparation {
            report([.preparationNotRestored])
            return attached
        }

        restoreActionState(previous, reason: .requested)
        return attached
    }

    // MARK: A moment in front, on purpose

    /// Brings the seat's target window in front for a moment, reads `isReady`
    /// every 20 ms while it is there, and gives the front back to the person's
    /// window as soon as it holds or `bound` passes, two seconds at most.
    ///
    /// It exists for one measured reason, recorded in ADR 0013: an Adobe UXP
    /// application recomputes its menu bar only when it becomes active, so a
    /// seat that drives it in the background finds its items disabled after a
    /// dialog closes. It is not a way to deliver input, a paste or a key
    /// equivalent, which ADR 0012 already measured and withdrew.
    ///
    /// The default bound is one run's measurement with room, 30/09/2026 on
    /// Photoshop 27.10 left in front: File > Save As... read disabled at 5 ms,
    /// its menu bar answered nothing from 61 to 961 ms while it recomputed, and
    /// the item read enabled at 1050 ms. A fixed 150 ms hold could never have
    /// worked, which is why this polls for the answer instead of waiting a time.
    ///
    /// The activation goes through the focus recovery's own restorer, onto the
    /// window the seat holds, and the recovery is told to expect it, so it is
    /// not read as the person's focus being taken: the seat reports no
    /// `targetActivated` and never waits, and it is `acting` for the length of
    /// it, like a Command, so no other pass runs underneath. It ends in the
    /// state it began in. If the person takes the front meanwhile it is left
    /// with them. An unverified handback returns `handbackNotVerified`, never
    /// success. If the target still holds the front, ordinary recovery pauses
    /// and waits; a different foreground is left with the person's choice.
    ///
    /// It refuses before bringing anything in front, and logs one line saying
    /// why, when no focus recovery is installed, when the seat is not ready,
    /// when a dialog of the application is open in the seat, when no window of
    /// the person's own is in front, or when the target window cannot be
    /// prepared.
    public func bringTargetBrieflyInFront(
        until isReady: @MainActor () -> Bool,
        atMost bound : Duration = .seconds(2)
    ) async -> BriefActivationOutcome {
        await withBriefTargetActivation(until: isReady, atMost: bound, performOnce: nil)
    }

    /// Performs one admitted Adobe menu command after readiness, before the
    /// verified handback (ADR 0024). The synchronous callback is never retried;
    /// a handback failure does not undo or disprove its possible effect.
    /// Other input remains on its existing background route.
    package func performMenuCommandBrieflyInFront(
        when isReady: @MainActor () -> Bool,
        performOnce : @escaping @MainActor () -> Void
    ) async -> BriefActivationOutcome {
        await withBriefTargetActivation(until: isReady, atMost: .seconds(2), performOnce: performOnce)
    }

    private func withBriefTargetActivation(
        until isReady: @MainActor () -> Bool,
        atMost bound : Duration,
        performOnce  : (@MainActor () -> Void)?
    ) async -> BriefActivationOutcome {

        guard let recovery = focusRecovery else {
            return refuseBriefActivation(.noFocusRecovery, "no focus recovery is installed")
        }
        guard !isTearingDown, state.acceptsCommands, !actionInFlight, !adoptionInFlight,
              transfersInFlight == 0, !recovery.isPaused else {
            return refuseBriefActivation(
                .seatNotReady,
                "the seat is \(state.rawValue)" + (recovery.isPaused ? " and its focus recovery is paused" : "")
            )
        }
        if let dialog = openDialogs.first {
            return refuseBriefActivation(
                .dialogOpen,
                "window \(dialog.windowNumber) of the application is a dialog open in the seat"
            )
        }
        guard let target = session.currentTarget?.window.reference else {
            return refuseBriefActivation(.targetNotPrepared, "the seat holds no target window")
        }

        let previous = state
        actionInFlight = true
        transition(to: .acting, reason: .requested)
        defer {
            actionInFlight = false
            restoreActionState(previous, reason: .requested)
            // What the application did while it was in front is looked for now.
            requestWindowFollow()
        }
        var scopedCommand: (@MainActor () -> Bool)?
        if let command = performOnce {
            scopedCommand = { [self] in
                let selected = session.currentTarget?.window.reference
                guard !isTearingDown, !recovery.isPaused, openDialogs.isEmpty,
                      selected?.hasSameIdentity(as: target) == true
                else { return false }
                command()
                return true
            }
        }
        let run = await recovery.bringBrieflyInFront(
            target,
            until : isReady,
            atMost: UInt64(clamping: bound.wholeNanoseconds),
            performOnce: scopedCommand
        )
        if case .refused(let refusal) = run.outcome, refusal != .frontRequestRefused {
            return refuseBriefActivation(refusal, run.summary)
        }
        Self.log.notice("""
            brought pid \(target.processID, privacy: .public) window \(target.windowNumber, privacy: .public) \
            briefly in front: \(run.summary, privacy: .public)
            """)
        return run.outcome
    }

    /// The dialogs of the driven application open in the seat now, empty when
    /// there is none: every adopted window the selection kit attests as a modal
    /// of either scope, and every modal whose block on the current target is in
    /// force, each once, in that order.
    ///
    /// It is the seat's own state and not a reading of accessibility, which is
    /// why it is the scope of a dialog button's press. Measured on 30/09/2026
    /// with Photoshop's "Save changes?" alert up: File > Save As... read
    /// disabled for that reason, and two seconds in front changed nothing; and
    /// right after the alert opened, Photoshop's focused window was still the
    /// document behind it. Only a window the window server still shows under
    /// the same identity counts, so a dialog already closed drops out at once
    /// rather than when the inventory next reads.
    public var openDialogs: [WindowIdentity] {
        let adopted = adoptedWindows.compactMap(\.reference.identity).filter {
            selectionKit.isApplicationModal($0) || selectionKit.namedModalHost(of: $0) != nil
        }
        let blocking = currentTarget?.reference.identity.map { selectionKit.modals(blocking: $0) } ?? []
        var seen: Set<WindowIdentity> = []
        return (adopted + blocking).filter { dialog in
            seen.insert(dialog).inserted
                && selectionKit.core.facts[dialog]?.visibility != .withdrawnEstablished
                && sensing.windowGeometry(of: dialog.windowNumber)?.identity == dialog
        }
    }

    /// Whether a dialog open in the seat is a file panel the system draws out
    /// of process: one of `openDialogs` whose one foreign content window
    /// belongs to the qualified panel service.
    ///
    /// Such a panel answers the keys that select a field differently. Measured
    /// on 30/09/2026 in Photoshop's Save As panel, its name field clicked:
    /// Command and Up went to the enclosing folder and left the selection as it
    /// was, Command, Shift and Down and Command and A did nothing, and a triple
    /// click selected the whole name with no key.
    public var holdsRemoteFilePanel: Bool {
        guard let instance = assignmentKit.lifecycle.current?.instance else { return false }
        return openDialogs.contains { dialog in
            guard let frame = sensing.windowGeometry(of: dialog.windowNumber)?.frame else { return false }
            let chain = DialogEndpointResolver<AXUIElement>.SurfaceChain(
                host        : selectionKit.attachedHost(of: dialog)
                    ?? selectionKit.namedModalHost(of: dialog)
                    ?? dialog,
                surface     : dialog,
                surfaceFrame: frame
            )
            guard let content = endpoints.foreignContentWindow(instance.processID, chain),
                  let owner = endpoints.identity(content)
            else { return false }
            return endpoints.qualifiedAppKitPanelService(owner)
        }
    }

    private func refuseBriefActivation(
        _ refusal: BriefActivationOutcome.Refusal,
        _ reason : String
    ) -> BriefActivationOutcome {
        Self.log.notice("""
            a brief activation was refused, \(refusal.rawValue, privacy: .public): \(reason, privacy: .public)
            """)
        return .refused(refusal)
    }

    /// Install only through a host configured for recovery. The private writer
    /// never receives an arbitrary caller-selected user window.
    func enableFocusRecovery(driver: InputDriver, allowUnvalidatedBuild: Bool, usesKeyRecords: Bool = false) throws {
        let restorer = try UserFocusRestorer(allowUnvalidatedBuild: allowUnvalidatedBuild, usesKeyRecords: usesKeyRecords)
        focusRecoveryReadiness = restorer.readiness
        let recovery = UserFocusRecovery(sensing: sensing, gate: driver.commandGate,
            adopted: { [weak self] in self?.adoptedWindows.map(\.reference) ?? [] },
            restore: { try restorer.restore($0) },
            restoreForBriefActivation: { try restorer.restore($0, primesKeyWindow: true) },
            requestTiming: { restorer.timing },
            prepareDestination: { try restorer.prepare($0, targets: $1) },
            renewDestination: { try restorer.renewDestination($0) },
            isFrontmost: { restorer.isFrontmost(processID: $0) },
            changed: { [weak self] report in self?.focusRecoveryChanged(report) })
        focusRecovery = recovery
        driver.commandGate.setPreparation { [weak self, weak recovery] correlationID in
            guard let self, let recovery else {
                throw InputFailure.inputPaused([.recoveryUnavailable])
            }
            // Four separate facts, each named where it is read. They used to
            // share one refusal, which told a consumer that the action had moved
            // on and never which of the four moved it.
            @MainActor func checkAction() throws {
                guard self.focusRecovery === recovery else {
                    throw InputFailure.inputPaused([.recoveryReplaced])
                }
                guard self.actionInFlight else {
                    throw InputFailure.inputPaused([.noActionInFlight])
                }
                guard self.state == .acting else {
                    throw InputFailure.inputPaused([.seatNotActing])
                }
                guard self.turns.current?.correlationID == correlationID else {
                    throw InputFailure.inputPaused([.turnChanged])
                }
            }
            try checkAction()
            try await recovery.prepareBeforeAction()
            try checkAction()
        }
        focusWatch = UserFocusWatch(changed: { [weak recovery] pid, received in
                recovery?.activationChanged(to: pid, source: .workspaceNotification, receivedAt: received)
            },
            windowChanged: { [weak recovery] in recovery?.userWindowChanged() },
            isUserApplication: { [weak self] pid in
                guard let self else { return false }
                return !self.adoptedWindows.contains { $0.reference.processID == pid }
            })
    }

    /// Closes the input gate because the person said stop, and leaves it
    /// closed. It is the first act of a panic and not part of the teardown.
    ///
    /// Panic used to reach the gate only through the teardown, which a run in
    /// flight is given a bounded moment to unwind before: for the whole of that
    /// moment the gate was open and whatever the run tried next was admitted.
    /// The cause is terminal, so nothing reopens it, and it is deliberately not
    /// on the recovery's fast lane: this stops Commands, it activates nothing,
    /// returns no window and takes no display down.
    ///
    /// The Command already admitted stays atomic. The gate stops the next one,
    /// so a key or button that is down still gets its release.
    public func stopAdmittingCommands() {
        commandGate?.pause(.deliberateStop)
        focusRecovery?.endClosureTransition()
    }

    func stopFocusRecovery() {
        focusWatch?.stop()
        focusWatch = nil
        focusRecovery?.stop()
        focusRecovery = nil
    }

    /// Asks the recovery to rebuild its preparation, on the two signals that
    /// can still precede a driven application taking the front: the
    /// accessibility notification that one of them created a window, and the
    /// heartbeat that is the net under an application family whose
    /// notification never comes. It adds no clock of its own.
    ///
    /// A seat holding no window is skipped, because no application it drives
    /// can raise a popup it would have to answer, and the refresh is a window
    /// server enumeration that would otherwise run once a second for nothing.
    ///
    /// The task is what keeps the enumeration off this actor, and the
    /// recovery's own single-flight guard is what makes a task that arrives
    /// while one is running cost an early return instead of a second reading.
    private func refreshFocusPreparation() {

        guard let focusRecovery, !isTearingDown, state != .failed,
              !adoptedWindows.isEmpty else { return }

        Task { @MainActor [weak focusRecovery] in await focusRecovery?.refreshPreparation() }
    }

    private func focusRecoveryChanged(_ report: UserFocusRecoveryReport) {
        lastFocusRecovery = report
        eventChannel.yield(.userFocusRecoveryChanged(report))
        // The event carries this to a consumer that subscribes, and the one the
        // kit ships does not: it reads `lastFocusRecovery` only once, at the
        // moment a Command has already failed. So a recovery that ran and one
        // that never started look identical from outside, which is the whole
        // difference between "the seat gave your focus back" and "the seat sat
        // there". It is one line and it belongs in the same log as the
        // transitions it explains.
        Self.log.notice("""
            user focus recovery: \(String(describing: report.outcome), privacy: .public), \
            destination \(report.destination.map { "window \($0.windowNumber)" } ?? "none", privacy: .public), \
            activated by process \(report.activatingProcessID, privacy: .public), \
            \(report.detail, privacy: .public)
            """)
        guard state != .failed else { return }
        switch report.outcome {
        case .restoring:
            focusRecoveryWasDegraded = state == .degraded
            eventChannel.yield(.issueDetected(.targetActivated, cause: nil))
            turns.recordIssue()
            transition(to: .waiting, reason: .issues([.targetActivated]))
        case .restored, .userTookControl:
            if state == .waiting {
                transition(to: actionInFlight ? .acting : (focusRecoveryWasDegraded ? .degraded : .ready),
                           reason: .recovered)
            }
        // The seat stays where it is on all three: `unrecoverable` says nothing
        // automatic asks again, not that the seat stopped.
        case .waitingForUser, .cancelled, .unrecoverable:
            break
        }
    }

    /// Completion of an in-flight command must not overwrite a recovery or a
    /// host failure that was delivered while the sender was awaited.
    private func restoreActionState(_ previous: SeatState, reason: SeatTransitionReason) {
        guard state == .acting else { return }
        transition(to: previous, reason: reason)
    }

    private func beginObservationIfNeeded(for record: WindowRecord, turn: Turn) {

        guard observer == nil else { return }

        let audit: (fence: CursorFence, marker: Int64)?
        if let fence, (try? fence.beginAudit(forSyntheticMarker: turn.correlationID)) != nil {
            audit = (fence, turn.correlationID)
        } else {
            audit = nil
        }

        let created = SeatObserver(
            target                    : record.window.reference,
            expectedFrontmostProcessID: sensing.frontmostProcessID,
            baselineCursor            : sensing.cursorLocation ?? .zero,
            sensing                   : sensing,
            audit                     : audit,
            recordsUserContext        : true,
            issueCheck                : { [weak self] in
                guard let self, let record = self.session[record.window.id] else {
                    return [.processUnavailable]
                }
                return self.currentIssues(for: record)
            }
        )

        created.start()
        observer = created
    }

    // MARK: Placement and release

    /// Two agreeing server readings confirm placement inside the display.
    /// A Stage Manager thumbnail may remain physical after AXPosition, so it
    /// must be staged before containment can be confirmed. Missing transitional
    /// readings do not bypass that step when the thumbnail becomes readable.
    ///
    /// An application may refuse the raise and still arrive: the move alone
    /// takes a stashed window out of the strip once it reaches the Virtual
    /// Display, where Stage Manager does not reach. Measured on 27.0 with
    /// Calculator, whose window lists `AXRaise` and answers -25205 to it in
    /// every state, and with Chess as the control: both were at full size on
    /// the display 75 ms after the move, with no raise and no activation. So a
    /// refused raise keeps waiting, and is what is thrown only when nothing
    /// confirms the window by the deadline. A thumbnail cannot be confirmed in
    /// its place: the strip is on the physical display, outside `bounds`.
    ///
    /// A window born inside the display may settle at a different body size.
    /// Only this in-place path accepts the new size: AX and two bracketed
    /// server readings must agree inside the display, followed by the ordinary
    /// two-reading stability proof. A smaller server frame with a full-size
    /// AX body still takes the thumbnail staging path.
    ///
    /// The budget is an absolute two-second deadline. Four early 20 ms readings
    /// let a cooperative child finish the same two-reading proof without
    /// spending 200 ms in fixed waits after its AX move. A slower window then
    /// uses the original 100 ms cadence until the same deadline; the shorter
    /// opening does not weaken the identity, geometry or stability checks.
    private func confirmPlacement(
        of window     : WindowReference,
        expectedOrigin: CGPoint,
        within bounds : CGRect,
        takenInPlace  : Bool,
        wasStashed    : Bool
    ) async throws -> (reference: WindowReference, body: CGRect) {

        var previous    : WindowReference?
        var previousBody: CGRect?
        var last        : WindowReference?
        var refusedRaise: DisplayFailure?
        var didAttemptStage = false
        var readings = 0

        let deadline = DispatchTime.now().uptimeNanoseconds
            + Self.placementConfirmationNanoseconds

        while DispatchTime.now().uptimeNanoseconds < deadline {
            try checkAdoptionMayContinue()
            await EventLoopWait.step(
                readings < 4 ? .milliseconds(20) : .milliseconds(100)
            )
            readings += 1
            try checkAdoptionMayContinue()

            guard var reading = sensing.windowGeometry(of: window.windowNumber) else {
                previous = nil
                previousBody = nil
                continue
            }

            last = reading

            guard reading.hasSameIdentity(as: window) else {
                throw SeatInterruption(issues: [.identityChanged])
            }

            var fullBody = window.frame
            if takenInPlace,
               !VirtualWindowPlacementCheck.sizesMatchAcrossSources(reading.frame.size, fullBody.size) {
                let body = try placing.frame(of: reading)
                guard let afterBody = sensing.windowGeometry(of: window.windowNumber) else {
                    previous = nil
                    previousBody = nil
                    continue
                }
                guard afterBody.hasSameIdentity(as: window) else {
                    throw SeatInterruption(issues: [.identityChanged])
                }
                guard VirtualWindowPlacementCheck.framesMatch(reading.frame, afterBody.frame) else {
                    previous = nil
                    previousBody = nil
                    continue
                }
                reading = afterBody
                last = reading
                if let body, bounds.contains(body), bounds.contains(reading.frame),
                   VirtualWindowPlacementCheck.framesMatch(
                       body,
                       reading.frame,
                       tolerance: VirtualWindowPlacementCheck.crossSourceTolerance
                   ) {
                    fullBody = body
                }
            }

            // Reads smaller than the body by more than the offset between the
            // two sources, so it is the thumbnail and not MarkEdit's 3 pt.
            let slack = VirtualWindowPlacementCheck.crossSourceTolerance
            if !didAttemptStage,
               reading.frame.width  < fullBody.width  - slack
                || reading.frame.height < fullBody.height - slack {
                didAttemptStage = true
                let requested = window.replacingFrame(
                    CGRect(origin: expectedOrigin, size: fullBody.size)
                )
                do {
                    _ = try await placing.stage(
                        requested,
                        expectedSize: fullBody.size,
                        within      : bounds
                    )
                } catch let failure as DisplayFailure {
                    guard case .raiseFailed = failure else { throw failure }
                    refusedRaise = failure
                }
                try checkAdoptionMayContinue()
                previous = nil
                previousBody = nil
                continue
            }

            // Stage Manager can pause at full size before its move finishes.
            // Confirm the requested position as well as the complete body.
            let requestedFrame = CGRect(origin: expectedOrigin, size: fullBody.size)
            guard VirtualWindowPlacementCheck.sizesMatchAcrossSources(reading.frame.size, fullBody.size),
                  takenInPlace || !(wasStashed || didAttemptStage)
                    || VirtualWindowPlacementCheck.framesMatch(
                      reading.frame,
                      requestedFrame,
                      tolerance: VirtualWindowPlacementCheck.crossSourceTolerance
                  ) else {
                previous = nil
                previousBody = nil
                continue
            }

            if let previous, let previousBody,
               VirtualWindowPlacementCheck.framesMatch(previous.frame, reading.frame),
               VirtualWindowPlacementCheck.framesMatch(
                   previousBody,
                   fullBody
               ),
               bounds.contains(reading.frame) {
                return (reading, fullBody)
            }

            previous = reading
            previousBody = fullBody
        }

        throw refusedRaise ?? DisplayFailure.placementNotConfirmed(
            windowNumber: window.windowNumber,
            lastFrame   : last?.frame
        )
    }

    private func checkAdoptionMayContinue() throws {
        try Task.checkCancellation()
        guard !isTearingDown, state != .failed else { throw SessionFailure.seatNotReady(state) }
    }

    /// Restore only the attempted PID/Window ID on unchanged physical topology.
    /// Missing geometry is unknown, never evidence that a live window vanished.
    /// Cleanup ignores task cancellation and needs two matching original frames.
    ///
    /// A missing reading the window server confirms as a destruction is the
    /// one exception: that window is owed no return, so it answers `vanished`.
    /// Measured on 30/09/2026 with Photoshop, a Save panel cancelled while it
    /// was being adopted answered `refused` here and failed the whole seat.
    private func restorePendingAdoption(
        _ window: AdoptedWindow,
        until limit: UInt64? = nil
    ) async -> (outcome: WindowReleaseOutcome, error: (any Error)?)? {
        var writeError: (any Error)?
        // The same obligation `returnToUserSeat` reads, on the path that rolls
        // an adoption back. A sheet is owed nothing, and the frame it was born
        // at is not a destination: writing it back there would move a surface
        // nobody placed, independently of the host it is drawn inside.
        guard Self.mayContinue(until: limit) else { return nil }
        guard !window.owesNoReturn else { return (.returned, writeError) }
        guard sensing.isActive(processID: window.reference.processID) != nil else { return (.vanished, writeError) }
        guard sensing.physicalTopologyIsUnchanged else { return (.refused, writeError) }
        var previousMatched = false
        var requested = false
        for _ in 0..<10 {
            guard Self.mayContinue(until: limit) else { return nil }
            guard sensing.isActive(processID: window.reference.processID) != nil else { return (.vanished, writeError) }
            guard sensing.physicalTopologyIsUnchanged else { return (.refused, writeError) }
            if let reading = sensing.windowGeometry(of: window.id) {
                guard reading.hasSameIdentity(as: window.reference) else { return (.refused, writeError) }
                let matches: Bool
                do { matches = try originalFrameMatches(window, server: reading) }
                catch { writeError = error; return (.refused, writeError) }
                if matches, previousMatched {
                    return (await finishReturn(of: window, until: limit), writeError)
                }
                previousMatched = matches
                if !matches, !requested {
                    requested = true
                    do { try restoreOriginalGeometry(of: window) }
                    catch { writeError = error }
                }
            } else if sensing.windowIsDestroyed(window.reference) {
                Self.log.notice("""
                    the window server confirmed window \(window.id, privacy: .public) was destroyed \
                    before its adoption was rolled back: it is owed no return
                    """)
                return (.vanished, writeError)
            } else { previousMatched = false }
            await EventLoopWait.step(Self.boundedPause(.milliseconds(100), until: limit))
            guard Self.mayContinue(until: limit) else { return nil }
        }
        return (.refused, writeError)
    }

    /// Writes back what the seat changed, size before origin.
    ///
    /// A window shrunk to fit the Virtual Display is owed its old size as much
    /// as its old place, and the return is verified against the whole frame, so
    /// a restored origin alone would never match and the window would be given
    /// back smaller than it was found. The size is written only when the window
    /// reads differently from what was recorded: the ordinary adoption changes
    /// no size and must post no size write.
    private func restoreOriginalGeometry(of window: AdoptedWindow) throws {

        let wanted = window.originalFrame.size
        if let current = ((try? placing.frame(of: window.reference)) ?? nil),
           !VirtualWindowPlacementCheck.framesMatch(
               CGRect(origin: .zero, size: current.size),
               CGRect(origin: .zero, size: wanted)
           ) {
            do { try placing.resize(window.reference, to: wanted) }
            catch {
                // Reported and not thrown: the move below is still worth making,
                // and the return is decided by the readings either way.
                Self.log.error("""
                    window \(window.id, privacy: .public) would not be resized for its return: \
                    \(String(describing: error), privacy: .public)
                    """)
            }
        }
        try placing.move(window.reference, to: window.originalFrame.origin)
    }

    /// A thumbnail outside the virtual display cannot expose its body's frame.
    /// In that case require the same server identity, unchanged topology and
    /// the exact AX body at the original physical origin. Callers require two
    /// consecutive matches; an AX frame alone never confirms a virtual move.
    ///
    /// The first comparison is server against server whenever the adoption
    /// could record the window server's own original rectangle, so the
    /// systematic offset between the two sources never enters it. Without that
    /// rectangle it is the old cross-source comparison and takes the wider
    /// tolerance, which is what left MarkEdit's window on the virtual display
    /// at 2 pt: its two sources differ by 3.
    private func originalFrameMatches(
        _ window: AdoptedWindow,
        server  : WindowReference
    ) throws -> Bool {
        guard server.hasSameIdentity(as: window.reference),
              sensing.physicalTopologyIsUnchanged else { return false }
        if let recorded = window.originalServerFrame {
            if VirtualWindowPlacementCheck.framesMatch(server.frame, recorded) { return true }
        } else if VirtualWindowPlacementCheck.framesMatch(
            server.frame,
            window.originalFrame,
            tolerance: VirtualWindowPlacementCheck.crossSourceTolerance
        ) { return true }
        let frame = server.frame
        guard frame.width > 0, frame.height > 0,
              frame.width  < window.originalFrame.width  - VirtualWindowPlacementCheck.crossSourceTolerance,
              frame.height < window.originalFrame.height - VirtualWindowPlacementCheck.crossSourceTolerance,
              !sensing.virtualDisplayBounds.intersects(frame),
              sensing.fenceContainsPhysicalPoint(CGPoint(
                  x: window.originalFrame.midX,
                  y: window.originalFrame.midY
              )),
              let body = try placing.frame(of: window.reference) else { return false }
        return VirtualWindowPlacementCheck.framesMatch(body, window.originalFrame)
    }

    private func returnToUserSeat(
        _ window: AdoptedWindow,
        _ mode  : ReleaseMode,
        until limit: UInt64? = nil
    ) async -> WindowReleaseOutcome {

        guard Self.mayContinue(until: limit) else { return .refused }
        guard mode == .returnToUserSeat else { return .leftOnVirtualDisplay }

        // A surface with no destination of its own is already wherever it
        // belongs, so its return is complete before it starts.
        guard !window.owesNoReturn else { return .returned }

        guard sensing.isActive(processID: window.reference.processID) != nil else {
            return .vanished
        }

        // A window its application ordered out answers no element, so there is
        // nothing to write until the application shows it again.
        if sensing.windowIsOrderedOut(window.reference) {
            guard let hiddenReturns else { return .refused }
            hiddenReturns.owe(window)
            return .returnsWhenShown
        }

        // Whatever fullscreen the window is in now has to come off before
        // anything can be written: `AXPosition` measured `settable false` and
        // `kAXErrorFailure` on a window in native fullscreen, so a move
        // attempted first fails and tells the caller the wrong thing.
        if (try? placing.fullScreen(of: window.reference))?.isNativeFullScreen == true,
           transfersFullScreenWindows {
            do {
                try placing.requestFullScreen(false, of: window.reference)
                _ = try await awaitFullScreen(false, of: window.reference, until: limit)
            } catch {
                Self.log.error("""
                    window \(window.id, privacy: .public) could not be taken out of fullscreen                     for its return: \(String(describing: error), privacy: .public)
                    """)
                return .refused
            }
        }

        let bounds = sensing.virtualDisplayBounds

        var previousMatched = false
        // Stage Manager can stash even a window whose original server frame was
        // known. Poll the same bound without restarting a matched AX body.
        let attempts = 8
        for _ in 0..<attempts {
            guard Self.mayContinue(until: limit) else { return .refused }
            guard sensing.physicalTopologyIsUnchanged else { return .refused }
            do {
                if !previousMatched {
                    let body = (try? placing.frame(of: window.reference)) ?? nil
                    if body.map({ VirtualWindowPlacementCheck.framesMatch(
                        $0, window.originalFrame
                    ) }) != true {
                        try restoreOriginalGeometry(of: window)
                    }
                }
            } catch {
                // The Window ID is momentarily not associable with an element,
                // which happens while a display transition is in flight. It is
                // the one case where a structural match is allowed, and it
                // refuses on two matches rather than moving a window the person
                // is using.
                try? placing.recover(
                    window.reference,
                    expectedTitle      : window.title,
                    expectedSize       : window.originalFrame.size,
                    sourceDisplayBounds: bounds,
                    to                 : window.originalFrame.origin
                )
            }

            await EventLoopWait.step(Self.boundedPause(.milliseconds(150), until: limit))
            guard Self.mayContinue(until: limit) else { return .refused }

            guard let reading = sensing.windowGeometry(of: window.id) else {
                previousMatched = false
                if sensing.isActive(processID: window.reference.processID) == nil { return .vanished }
                continue
            }

            do {
                let matches = try originalFrameMatches(window, server: reading)
                if matches && previousMatched { return await finishReturn(of: window, until: limit) }
                previousMatched = matches
            } catch { return .refused }
        }

        return .refused
    }

    /// The last step of a return, and deliberately the smallest one.
    ///
    /// **Fullscreen is not restored unless the host asked for it.** Measured on
    /// every run and in both Stage Manager states: re-entering native
    /// fullscreen takes the frontmost application every time and costs 538 to
    /// 792 ms of Space animation. Doing it by default would end a turn by
    /// taking the person's seat, which is the one thing this kit exists not to
    /// do. With the switch off the window comes back out of fullscreen, at its
    /// normal frame, on the display it came from, and stops there.
    ///
    /// **The window is not raised either.** `stage` is not inherited here for
    /// symmetry with the adoption, and the reason is the same measurement read
    /// the other way round: `kAXRaiseAction` with Stage Manager on stashes
    /// whatever was on stage, so raising a returning window would put the
    /// person's current window away, and with Stage Manager off it would jump
    /// the returning window over the windows they are looking at. Measured, the
    /// window comes back at full size on its own display in both states and
    /// sits behind the person's front window, at front to back index 1 to 3 of
    /// 15. Being findable is the seat's business; being on top is the person's.
    private func finishReturn(
        of window: AdoptedWindow,
        until limit: UInt64? = nil
    ) async -> WindowReleaseOutcome {

        guard Self.mayContinue(until: limit) else { return .refused }
        guard window.wasFullScreen, restoresFullScreenOnRelease else { return .returned }
        do {
            try placing.requestFullScreen(true, of: window.reference)
            _ = try await awaitFullScreen(true, of: window.reference, until: limit)
        } catch is CancellationError {
            // The fullscreen restitution is still owed. Calling it returned
            // would let a bounded release clear the only record of a late
            // transition.
            return .refused
        } catch {
            guard Self.mayContinue(until: limit) else { return .refused }
            // The window is home and usable; only the fullscreen state it was
            // found in is missing. That is reported, not turned into a refusal
            // of a return that did happen.
            Self.log.error("""
                window \(window.id, privacy: .public) returned but did not go back into                 fullscreen: \(String(describing: error), privacy: .public)
                """)
        }
        return .returned
    }

    /// Uses the release's one absolute deadline around a cancellable fullscreen
    /// transition. The placement collaborator owns the native wait; checking
    /// both sides prevents a completed late transition from letting release
    /// consume a fresh budget or clear its still-held obligation.
    private func awaitFullScreen(
        _ wanted: Bool,
        of window: WindowReference,
        until limit: UInt64?
    ) async throws -> WindowReference {
        guard Self.mayContinue(until: limit) else { throw CancellationError() }
        let settled: WindowReference
        if let remaining = Self.remainingDuration(until: limit) {
            settled = try await placing.awaitFullScreen(wanted, of: window, within: remaining)
        } else {
            settled = try await placing.awaitFullScreen(wanted, of: window)
        }
        guard Self.mayContinue(until: limit) else { throw CancellationError() }
        return settled
    }

    // MARK: Issues, transitions, recovery

    /// report hands the seat a batch of Issues, folds them into the state
    /// machine, publishes them and starts a recovery episode when the answer is
    /// `recovering`.
    ///
    /// It is public because most Issues are **not** the kit's to detect. The
    /// seat re-reads identity, geometry, the display and the fence, and that is
    /// all it can see; whether the target's own accessibility tree changed, or
    /// whether a verification failed, is the consumer's observation layer, and
    /// this is where that observation enters the seat's state.
    ///
    /// The batch is folded as a batch on purpose: a recoverable Issue arriving
    /// together with a critical one must never soften it, and the precedence
    /// that decides which one wins lives in `SeatStateMachine` rather than at
    /// every call site.
    ///
    /// `cause` is the finer fact behind the batch when one was established, and
    /// it is published with each Issue the cause belongs to and with no other:
    /// a batch carrying a window closure and a display change must not attach
    /// the closure to the display. Nothing decides on it, it is what a report
    /// says.
    public func report(_ issues: [SeatIssue], cause: SeatIssueCause? = nil) {

        guard !issues.isEmpty, state != .failed else { return }

        // A cause of the gate appearing while an observation is outstanding
        // invalidates it: the conditions the observation was taken under are no
        // longer the ones a Command would be admitted under.
        observationIssuer.invalidate(.suspensionRaised)
        outstandingGeometry = nil

        for issue in issues {
            eventChannel.yield(.issueDetected(issue, cause: cause?.issue == issue ? cause : nil))
        }
        turns.recordIssue()

        let next = SeatStateMachine.next(from: state, issues: issues)
        if focusRecovery?.isPaused == true, next != .failed {
            if next == .degraded { focusRecoveryWasDegraded = true }
            transition(to: .waiting, reason: .issues(issues))
            return
        }
        guard next != state else { return }

        if state == .degraded { wasDegradedBeforeRecovery = true }
        transition(to: next, reason: .issues(issues))

        guard next == .recovering else {
            if next == .failed { turns.failAll(with: SeatInterruption(issues: issues)) }
            return
        }

        startRecovery(after: issues)
    }

    private func transition(to next: SeatState, reason: SeatTransitionReason) {

        guard next != state else { return }
        if next == .failed {
            stopFocusRecovery()
            stopWindowFollowing()
        }

        let previous = state
        state = next
        eventChannel.yield(.seatStateChanged(from: previous, to: next, reason: reason))

        // The reason is logged with the transition because a state change on its
        // own says what happened and never why, and the two readings a consumer
        // has to tell apart — an issue and a request — look identical without
        // it. Issue cases carry no text of the person's.
        Self.log.notice("""
            seat \(previous.rawValue, privacy: .public) -> \
            \(next.rawValue, privacy: .public), \
            \(String(describing: reason), privacy: .public)
            """)
    }

    /// How much of a follow pass may run now.
    ///
    /// The third case is the whole reason this is not a boolean: input
    /// suspended for focus stops the seat acting on the world and does not stop
    /// it reading the world. Naming each reason is what turns "the window was
    /// never brought in" into a fact with a cause.
    private enum WindowFollowScope {

        /// Read and move: the ordinary pass.
        case full

        /// Read and settle the registers, move nothing. It is what a seat
        /// suspended for the person's focus may still do.
        case reconciliationOnly(reason: String)

        case standDown(reason: String)

        var isStandDown: Bool {
            if case .standDown = self { return true }
            return false
        }

        /// The reason the full pass is not running, nil when it is.
        var heldBackReason: String? {
            switch self {
                case .full:                            nil
                case .reconciliationOnly(let reason):   reason
                case .standDown(let reason):           reason
            }
        }
    }

    /// `requiringWatch` is false only for `takeInRefusedPreexistingMembers`,
    /// whose members the assignment reader found whether or not the seat
    /// follows: every other stand-down still holds it back.
    private func windowFollowScope(requiringWatch: Bool = true) -> WindowFollowScope {
        if requiringWatch, windowWatch == nil     { return .standDown(reason: "there is no window watch") }
        if isTearingDown                          { return .standDown(reason: "the seat is tearing down") }
        if actionInFlight                         { return .standDown(reason: "a Command is in flight") }
        if adoptionInFlight                       { return .standDown(reason: "an adoption is in flight") }
        if transfersInFlight != 0                 { return .standDown(reason: "a transfer is in flight") }
        if windowFollowPassInFlight               { return .standDown(reason: "a pass is already running") }
        if sensing.userMayBeSwitchingApplications { return .standDown(reason: "the person's own intent is recent") }
        if session.processIdentities.isEmpty      { return .standDown(reason: "the seat holds no process") }

        // The two focus suspensions, and only those two: every other state that
        // refuses Commands refuses the reading with it, as it did before.
        if focusRecovery?.isRestoring == true {
            return .reconciliationOnly(reason: "a focus request is in flight and unverified")
        }
        if state == .waiting, !containmentOnlyFollowWait {
            return .reconciliationOnly(reason: "the seat is waiting for the person")
        }
        if !state.acceptsCommands,
           !containmentOnlyFollowWait,
           !recoverySuccessorFollowMayProceed {
            return .standDown(reason: "the seat is \(state.rawValue)")
        }
        return .full
    }

    /// A newly discovered modal can itself be the one uncontained surface that
    /// suspended the seat. Its existing detected-window transaction is the
    /// qualified way to settle that condition, so this narrowly permits that
    /// transaction while every focus, deliberate-stop and user-intent wait
    /// remains reconciliation-only or stopped.
    var containmentOnlyFollowWait: Bool {
        guard state == .waiting else { return false }
        // `operability()` without an offered observation necessarily reports
        // `.observationMissing`. That fact describes the request we are about
        // to make and must not turn an otherwise containment-only wait into a
        // permanent stand-down.
        let causes = selectionKit.operability().causes.filter { $0 != .observationMissing }
        guard !causes.isEmpty else { return false }
        return causes.allSatisfy {
            if case .containmentNotVerified = $0 { return true }
            return false
        }
    }

    /// The second window-server reading of a newly selected successor is part
    /// of recovering the host that disappeared while opening it. The follower
    /// remains the owner: it still requires `AppWindowInventory`'s two
    /// sightings and therefore cannot adopt a window that happened to be in
    /// the baseline before the assignment. This only permits that reading and
    /// its exact selected candidate while the old target's recovery is the
    /// single `windowUnavailable` episode.
    private var recoverySuccessorFollowMayProceed: Bool {
        guard state == .recovering,
              recoveryTrigger == [.windowUnavailable],
              let selected = selectionKit.selected,
              let member = assignmentKit.inventory.surfaces[selected.surface.windowNumber],
              member.identity == selected.surface,
              member.origin == .bornDuringAssignment,
              session[selected.surface.windowNumber]?.window.reference.identity != selected.surface,
              !sensing.userMayBeSwitchingApplications,
              focusRecovery?.isRestoring != true,
              !inputPauseReasons.contains(.focusRecovery),
              !inputPauseReasons.contains(.focusRecoveryStopped)
        else { return false }
        return true
    }

    /// The recovery episode: wait for whatever is in flight, then read the
    /// window server on a cadence until it agrees with itself twice or the
    /// budget runs out.
    private func startRecovery(after issues: [SeatIssue]) {

        guard recoveryTask == nil,
              let seatGuard,
              let record = session[seatGuard.target.windowNumber]
        else { return }

        // The one refusal that comes before any recovery: an input was posted
        // and nobody established what it did. Recovering would put the seat
        // back to work on a state nobody knows, and the next Command could be
        // the same action twice.
        //
        // A geometry Issue after a verified closure is the one case where
        // something was established: see `closureGeometryEffect`.
        var confirmation = worstConfirmation
        if issues == [.geometryChanged],
           case .hostMoved(let before, let after)? =
               closureGeometryEffect(of: seatGuard.target) {
            confirmation = .observed
            Self.log.notice("""
                window \(seatGuard.target.windowNumber, privacy: .public) moved from \
                \(Int(before.minX), privacy: .public),\(Int(before.minY), privacy: .public) to \
                \(Int(after.minX), privacy: .public),\(Int(after.minY), privacy: .public) pt \
                across a verified closure, at the same size and on the same display: the \
                movement is the known effect, and the dialog is not driven again
                """)
        }
        do {
            try recoveryBudget.begin(
                issues        : issues,
                inputWasPosted: !posted.isEmpty,
                confirmation  : confirmation
            )
        } catch let interruption as SeatInterruption {
            transition(to: .failed, reason: .issues(interruption.issues))
            for issue in interruption.issues {
                eventChannel.yield(.issueDetected(issue, cause: nil))
            }
            turns.failAll(with: interruption)
            return
        } catch {
            transition(to: .failed, reason: .issues([.recoveryExhausted]))
            return
        }

        recoveryEpisode += 1
        recoveryTrigger = issues
        let episode = recoveryEpisode

        recoveryTask = Task { @MainActor [weak self] in
            await self?.runRecovery(episode: episode, record: record, seatGuard: seatGuard)
            guard self?.recoveryEpisode == episode else { return }
            self?.recoveryTask = nil
        }
    }

    private func runRecovery(
        episode  : Int,
        record   : WindowRecord,
        seatGuard: SeatGuard
    ) async {

        // Nothing is relocated while a Command is in flight: the Command was
        // built from coordinates this recovery is about to change. Past the
        // longest a Command can take, the Command counts as `unknown` and the
        // budget above turns that into a failed seat.
        await waitForCommandInFlight()
        guard !Task.isCancelled, episode == recoveryEpisode else { return }

        var plan = WindowRecoveryPlan(
            target        : seatGuard.target,
            expectedOrigin: seatGuard.target.frame.origin,
            displayBounds : sensing.virtualDisplayBounds
        )
        recoveryProgress = plan

        while !Task.isCancelled, episode == recoveryEpisode, state == .recovering {

            await EventLoopWait.sleep(plan.cadence)
            guard !Task.isCancelled, episode == recoveryEpisode, state == .recovering else { return }

            let step = plan.step(
                server        : sensing.windowGeometry(of: record.window.id),
                targetIsActive: sensing.isActive(processID: record.window.reference.processID),
                at            : DispatchTime.now().uptimeNanoseconds
            )
            recoveryProgress = plan

            eventChannel.yield(.recoveryProgressed(episode: episode, step: step))

            switch step {

                case .observe:
                    continue

                case .finish:
                    transition(
                        to    : SeatStateMachine.resolved(
                            from       : state,
                            wasDegraded: wasDegradedBeforeRecovery
                        ),
                        reason: .recovered
                    )
                    return

                case .relocate(let origin):
                    try? placing.move(record.window.reference, to: origin)

                case .resize(let size):
                    // The adaptation, from inside the episode that verifies it:
                    // the readings that follow say whether the write took.
                    do { try placing.resize(record.window.reference, to: size) }
                    catch {
                        Self.log.notice("""
                            window \(record.window.id, privacy: .public) would not be adapted to \
                            \(Int(size.width), privacy: .public) by \
                            \(Int(size.height), privacy: .public) pt: \
                            \(String(describing: error), privacy: .public)
                            """)
                    }

                case .acceptResize(let resized):
                    acceptOperationalGeometry(resized)
                    transition(
                        to    : SeatStateMachine.resolved(
                            from       : state,
                            wasDegraded: wasDegradedBeforeRecovery
                        ),
                        reason: .recovered
                    )
                    return

                case .fail(let issue):
                    eventChannel.yield(.issueDetected(issue, cause: nil))
                    if await handedOverAfterDestruction(of: record) { return }
                    transition(to: .failed, reason: .issues([issue]))
                    turns.failAll(with: SeatInterruption(issues: [issue]))
                    return
            }
        }
    }

    /// Takes a reading the recovery accepted as the window's operational
    /// geometry from now on.
    ///
    /// Three things move together and that is the whole of it: the held record,
    /// which keeps its identity, its provenance and what it owes because the
    /// reading goes in through `withReference`; the guard, which is what every
    /// later comparison is made against; and the observation, which is dropped
    /// so that the coordinates computed over the old frame cannot be handed
    /// back with a Command. The generation the consumer's reference carries
    /// advances with that invalidation, which is what makes an old reference
    /// refused rather than merely stale.
    ///
    /// What the window is owed on its return is not among them.
    private func acceptOperationalGeometry(_ resized: WindowReference) {

        guard let record = session[resized.windowNumber],
              record.window.reference.hasSameIdentity(as: resized)
        else { return }

        session.acceptGeometry(resized)

        if let existing = seatGuard, existing.target.hasSameIdentity(as: resized) {
            seatGuard = SeatGuard(
                target       : resized,
                displayID    : existing.displayID,
                displayBounds: existing.displayBounds
            )
        }
        observationIssuer.invalidate(.geometryChanged)
        outstandingGeometry = nil

        Self.log.notice("""
            window \(resized.windowNumber, privacy: .public) settled at \
            \(Int(resized.frame.width), privacy: .public) by \
            \(Int(resized.frame.height), privacy: .public) pt: it is the operating geometry now, \
            and the coordinates taken before it are refused
            """)
    }

    /// What the seat measured of one window's frame across a dialog closure it
    /// verified, and nil when this is not that situation.
    ///
    /// The frame before comes from the closure transition, which attested it
    /// before the Command went out; the frame after is read now. Nothing on
    /// this path posts anything: a dialog whose closure was verified is not
    /// cancelled a second time to recover a frame, and what the classification
    /// decides is only which recovery the seat may run.
    private func closureGeometryEffect(of target: WindowReference) -> ClosureGeometryEffect? {

        guard let focusRecovery, focusRecovery.closureSurfaceIsGone,
              let before = focusRecovery.closureSurfacesBefore.first(where: {
                  $0.hasSameIdentity(as: target)
              })
        else { return nil }

        return ClosureGeometryEffect.classify(
            before: before,
            after : sensing.windowGeometry(of: target.windowNumber),
            within: sensing.virtualDisplayBounds
        )
    }

    /// The second and last proof that the target was destroyed: a recovery that
    /// started from `.windowUnavailable` spent its whole budget and the window
    /// server still cannot read the window.
    ///
    /// A single missing reading during a Space or a Stage Manager transition is
    /// deliberately not enough, and the budget is what tells the two apart. The
    /// predecessor has to be readable and its process alive before it takes
    /// over, because two windows of one application die together and handing
    /// the seat a second dead window would say the opposite. With none it gets
    /// the failed seat it would have had anyway, since choosing a window nobody
    /// adopted is worse than saying there is nothing left.
    private func handedOverAfterDestruction(of record: WindowRecord) async -> Bool {

        let windowNumber = record.window.id
        guard recoveryTrigger.contains(.windowUnavailable),
              session.currentTargetNumber == windowNumber,
              sensing.windowGeometry(of: windowNumber) == nil,
              let successor = session.predecessor(of: windowNumber),
              let predecessor = session[successor],
              sensing.windowGeometry(of: successor) != nil,
              sensing.isActive(processID: predecessor.window.reference.processID) != nil
        else { return false }

        _ = session.forget(windowNumber)
        if stagedWindowNumber == windowNumber { stagedWindowNumber = nil }
        eventChannel.yield(.windowReleased(windowNumber: windowNumber, outcome: .vanished))
        transition(to: wasDegradedBeforeRecovery ? .degraded : .ready, reason: .recovered)
        await takeOverAfterLostTarget(successor)
        return true
    }

    /// Waits while a Command is in flight, bounded by the longest a Command can
    /// take.
    private func waitForCommandInFlight() async {

        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(WindowRecoveryPlan.maximumCommandDuration.wholeNanoseconds)

        while state == .acting, DispatchTime.now().uptimeNanoseconds < deadline {
            await EventLoopWait.sleep(.milliseconds(10))
        }
    }

    /// The worst thing said about the Commands of this hold: an unconfirmed
    /// Command is `unknown`, and one `unknown` decides the batch.
    private var worstConfirmation: EffectConfirmation {

        if posted.contains(where: { $0.confirmation == nil || $0.confirmation == .unknown }) {
            return .unknown
        }

        return posted.contains { $0.confirmation == .absent } ? .absent : .observed
    }

    deinit { eventChannel.finish() }
}
