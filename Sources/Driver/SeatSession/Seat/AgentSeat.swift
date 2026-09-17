//
//  AgentSeat.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import CursorGuard
import Darwin
import Dispatch
import Foundation
import os
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
    public private(set) var seatGuard: SeatGuard?

    private let eventChannel: AsyncStream<SeatEvent>.Continuation

    private let sensing  : any SeatSensing
    private let placing  : any WindowPlacing
    private let sender   : any CommandSending
    private let fence    : CursorFence?
    private let displayID: CGDirectDisplayID
    private let expectedMainDisplayID: CGDirectDisplayID
    private let defaultPlatform      : any InputPlatform

    private let turns: TurnQueue

    private var session            = SeatWindowSession()
    private var transferGeneration : UInt64 = 0
    private var transfersInFlight  = 0
    private var recoveryTrigger    : [SeatIssue] = []
    private var pendingAdoptions: [Int: AdoptedWindow] = [:]
    private var adoptionRestorations: [Int: WindowReleaseOutcome] = [:]
    private var adoptionInFlight = false
    private var isTearingDown = false
    private var adoptionWaiters: [CheckedContinuation<Void, Never>] = []
    private var stagedWindowNumber : Int?
    private var posted             : [PostedCommand] = []
    private var observer           : SeatObserver?
    private var observationSoFar   : SeatObservation?
    private var recoveryBudget     = RecoveryPolicy()
    private var recoveryEpisode    = 0
    private var recoveryTask       : Task<Void, Never>?
    private var wasDegradedBeforeRecovery = false
    private var focusRecovery: UserFocusRecovery?
    private var focusWatch: UserFocusWatch?
    private var focusRecoveryWasDegraded = false
    private var actionInFlight = false

    /// Most recent focus episode, including a failed verification. Readiness
    /// describes the private facility separately from the normal input gate.
    public private(set) var lastFocusRecovery: UserFocusRecoveryReport?
    public private(set) var focusRecoveryReadiness: FacilityReadiness?

    /// Last failed adoption, including cancellation and the verified rollback.
    public private(set) var lastAdoptionFailure: WindowAdoptionFailure?

    /// A failed move still owned by the host until teardown can restore it.
    public var hasPendingWindowRestorations: Bool { !pendingAdoptions.isEmpty }

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

    init(
        sensing              : any SeatSensing,
        placing              : any WindowPlacing,
        sender               : any CommandSending,
        fence                : CursorFence?,
        displayID            : CGDirectDisplayID,
        expectedMainDisplayID: CGDirectDisplayID,
        defaultPlatform      : any InputPlatform = ChromiumPlatform(),
        markers              : @escaping () -> Int64 = { Int64.random(in: 1...Int64.max) }
    ) {
        self.sensing               = sensing
        self.placing               = placing
        self.sender                = sender
        self.fence                 = fence
        self.displayID             = displayID
        self.expectedMainDisplayID = expectedMainDisplayID
        self.defaultPlatform       = defaultPlatform
        self.turns                 = TurnQueue(markers: markers)

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
        _ shortcut: Shortcut,
        phase     : KeyPhase = .press,
        to window : AdoptedWindow,
        turn      : Turn,
        platform  : (any InputPlatform)? = nil
    ) async throws -> InputReceipt {

        let needsLayout: Bool = if case .character = shortcut.key { true } else { false }
        let resolved = try ShortcutResolution.resolve(
            shortcut,
            phase    : phase,
            layout   : needsLayout ? KeyboardLayoutReader.current() : nil,
            owner    : turn.correlationID,
            processID: window.reference.processID
        )
        let traceContext = InputTraceIdentity.submitted(
            command      : resolved.command,
            window       : window.reference,
            correlationID: turn.correlationID
        )
        return try await send(
            resolved.command,
            to              : window,
            turn            : turn,
            platform        : platform,
            layoutGeneration: resolved.layoutGeneration,
            traceContext    : traceContext
        )
    }

    /// sendText delivers a whole string in chunks, re-verifying the recipient
    /// between them.
    ///
    /// The re-verification is not a mechanism added here: each chunk is its own
    /// Command, and the driver re-reads the target window's identity before
    /// building a Command and again immediately before its first event. Cutting
    /// the text into Commands is therefore what makes the recipient checked
    /// between chunks, and this method is the chunking plus the accounting.
    ///
    /// Every cut falls on a grapheme cluster boundary, so no chunk can carry
    /// half of a joined emoji. A single cluster too large for one chunk is
    /// refused before anything is posted.
    ///
    /// What it returns is delivery and never effect. A `.stoppedAfter` outcome
    /// means the chunks already posted are already inside the target and there
    /// is no rollback: it is thrown as `TextDeliveryFailure` **carrying** that
    /// outcome, so a caller cannot see only the error and retry from the start.
    @discardableResult
    public nonisolated func sendText(
        _ text  : String,
        to window: AdoptedWindow,
        turn    : Turn,
        mode    : TextDeliveryMode = .inserted,
        limits  : TextDeliveryLimits = .measured,
        platform: (any InputPlatform)? = nil
    ) async throws -> TextDeliveryOutcome {

        let chunks = try TextChunking.chunks(
            of              : text,
            maximumClusters : limits.maximumClusters,
            maximumCodeUnits: limits.maximumCodeUnits
        )
        let commands = chunks.map { chunk in
            mode == .typed ? InputCommand.text(chunk) : InputCommand.insertText(chunk)
        }

        do {
            let receipts = try await sendSequence(
                commands,
                to      : window,
                turn    : turn,
                platform: platform
            )
            return TextDeliveryOutcome.of(
                chunks       : chunks,
                mode         : mode,
                receipts     : receipts,
                requestedText: text
            )
        } catch let failure as InputSequenceFailure {
            throw TextDeliveryFailure(
                outcome: TextDeliveryOutcome.of(
                    chunks       : chunks,
                    mode         : mode,
                    receipts     : failure.completedReceipts,
                    requestedText: text
                ),
                cause  : failure.cause
            )
        } catch {
            // Nothing came back, so nothing was posted: a refusal of the driver
            // happens before the first event of the first chunk.
            throw TextDeliveryFailure(
                outcome: TextDeliveryOutcome.of(
                    chunks       : chunks,
                    mode         : mode,
                    receipts     : [],
                    requestedText: text
                ),
                cause  : error
            )
        }
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
        let stranded = session.processIDs.reduce(0) { total, processID in
            total + KeyHold.shared.releaseEveryOwner(processID: processID).count
        }
        guard stranded > 0 else { return }
        eventChannel.yield(.issueDetected(.keysNotReleased, cause: nil))
    }

    /// How many keys **this Turn** is still holding across every adopted
    /// window's process.
    ///
    /// Scoped to the Turn and not to the process: another holder's keys on the
    /// same application are that holder's to release, and refusing this release
    /// for them would make one Turn unable to finish because another one is
    /// mid-gesture. The processes are a Set because two windows of one
    /// application are one process and would otherwise be counted twice.
    private func heldKeyCount(of turn: Turn) -> Int {
        session.processIDs.reduce(0) { total, processID in
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

        return try await adoptionTransaction(window, platform: platform, title: title)
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
    @discardableResult
    package func integrateDetectedWindow(
        _ window       : WindowReference,
        platform       : any InputPlatform = ChromiumPlatform(),
        title          : String = "",
        within deadline: Duration = .seconds(2)
    ) async throws -> AdoptedWindow {

        try Task.checkCancellation()
        try checkIdentityIsAttested(of: window)

        guard await awaitCommandBoundary(within: deadline), mayAdmit(window) else {
            throw SessionFailure.seatNotReady(state)
        }
        beginTransfer()
        defer { endTransfer() }

        return try await adoptionTransaction(window, platform: platform, title: title)
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
            && (state == .unavailable || state.acceptsCommands)
            && session[window.windowNumber] == nil
    }

    private func adoptionTransaction(
        _ window: WindowReference,
        platform: any InputPlatform,
        title   : String
    ) async throws -> AdoptedWindow {

        lastAdoptionFailure = nil
        adoptionInFlight = true
        defer {
            adoptionInFlight = false
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
        let bounds = sensing.virtualDisplayBounds
        let origin = CGPoint(
            x: min(max(bounds.minX, bounds.midX - window.frame.width  / 2),
                   max(bounds.minX, bounds.maxX - window.frame.width)),
            y: min(max(bounds.minY, bounds.midY - window.frame.height / 2),
                   max(bounds.minY, bounds.maxY - window.frame.height))
        )

        let pending = AdoptedWindow(reference: window, originalFrame: window.frame, title: title)
        pendingAdoptions[window.windowNumber] = pending
        adoptionRestorations[window.windowNumber] = nil
        do {
            try placing.move(window, to: origin)
            try checkAdoptionMayContinue()

            let placed = try await confirmPlacement(of: window, expectedOrigin: origin, within: bounds)
            let record = WindowRecord(
                window  : AdoptedWindow(
                    reference    : placed,
                    originalFrame: window.frame,
                    title        : title
                ),
                platform: platform,
                // Staged or stashed is read off the size: a window Stage Manager
                // stashed reads as a thumbnail, 90 by 97 points when measured,
                // so the size is what separates the two.
                isStaged: VirtualWindowPlacementCheck.framesMatch(
                    CGRect(origin: .zero, size: placed.frame.size),
                    CGRect(origin: .zero, size: window.frame.size)
                )
            )

            try checkAdoptionMayContinue()
            pendingAdoptions[window.windowNumber] = nil
            let displaced = session.currentTargetNumber
            session.adopt(record)
            if record.isStaged { stagedWindowNumber = record.window.id }

            seatGuard = SeatGuard(
                target       : placed,
                displayID    : displayID,
                displayBounds: bounds
            )

            transition(to: previous == .degraded ? .degraded : .ready, reason: .requested)
            eventChannel.yield(.targetChanged(from: displaced, to: placed, reason: .adopted))
            return record.window

        } catch {
            let observed: CGRect?
            if case .placementNotConfirmed(_, let lastFrame) = error as? DisplayFailure { observed = lastFrame }
            else { observed = sensing.windowGeometry(of: window.windowNumber)?.frame }
            let rollback = await restorePendingAdoption(pending)
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
                expectedSize: record.window.originalFrame.size,
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
        current.window   = AdoptedWindow(
            reference    : staged,
            originalFrame: current.window.originalFrame,
            title        : current.window.title
        )
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

        if stagedWindowNumber == window.id { stagedWindowNumber = nil }

        let outcome = await returnToUserSeat(window, mode)
        let successor = session.forget(window.id)
        eventChannel.yield(.windowReleased(windowNumber: window.id, outcome: outcome))

        // An explicit release is one of the two proofs that the target is gone,
        // and the only place other than an exhausted recovery where a
        // predecessor is chosen. A teardown chooses none: every window is on
        // its way out and restaging one would be work against the person.
        await takeOverAfterLostTarget(successor)
        return outcome
    }

    /// Puts the predecessor back on stage and makes it the target again, after
    /// the current one was proved gone.
    private func takeOverAfterLostTarget(_ successor: Int?) async {

        guard !isTearingDown, let successor, session[successor] != nil else { return }
        do { _ = try await transferTarget(to: successor, reason: .predecessor) }
        catch {
            Self.log.error("""
                the predecessor at Window ID \(successor, privacy: .public) could not take over: \
                \(String(describing: error), privacy: .public)
                """)
        }
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

        session[windowNumber]?.window = AdoptedWindow(
            reference    : reading,
            originalFrame: confirmed.window.originalFrame,
            title        : confirmed.window.title
        )
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

        eventChannel.yield(.targetChanged(from: displaced, to: reading, reason: reason))
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

        let limit = DispatchTime.now().uptimeNanoseconds + UInt64(deadline.wholeNanoseconds)
        while actionInFlight, DispatchTime.now().uptimeNanoseconds < limit {
            await EventLoopWait.sleep(.milliseconds(10))
        }
        return !actionInFlight
    }

    /// The stop the sender honours at command boundaries, when it has one. The
    /// seat reaches it through the sender because the focus recovery path is
    /// installed only for a host that restores user focus, and a window
    /// transfer has to close the gate in both configurations.
    private var commandGate: InputCommandGate? { sender.inputCommandGate }

    /// One cause for however many transfers are open.
    ///
    /// Transfers nest: a window released while another transfer is staging
    /// starts its predecessor's take over from inside that transfer's await. A
    /// set holds one `.windowTransfer` whoever inserted it, so the inner
    /// transfer's end would otherwise reopen input while the outer one is still
    /// moving a window. Counting here and not in the gate keeps the gate's rule
    /// the simple one: closed while any cause stands.
    private func beginTransfer() {
        transfersInFlight += 1
        if transfersInFlight == 1 { commandGate?.pause(.windowTransfer) }
    }

    private func endTransfer() {
        transfersInFlight -= 1
        if transfersInFlight == 0 { commandGate?.resume(.windowTransfer) }
    }

    // MARK: The action

    /// send posts one Command to one adopted window.
    ///
    /// The order is fixed and every step of it is a refusal point: the hold,
    /// the state, the guard on fresh readings, the stage if Stage Manager
    /// stashed the window, then the events. After the last of those an event
    /// has gone out, and an event that went out is never repeated.
    ///
    /// The Receipt comes back with a `SeatObservation` attached, which is the
    /// field a driver alone has to leave nil: the driver posts events and makes
    /// no observation, the seat watches the User Seat and has one.
    @discardableResult
    public nonisolated func send(
        _ command: InputCommand,
        to window: AdoptedWindow,
        turn     : Turn,
        platform : (any InputPlatform)? = nil
    ) async throws -> InputReceipt {

        let traceContext = InputTraceIdentity.submitted(
            command      : command,
            window       : window.reference,
            correlationID: turn.correlationID
        )
        return try await send(
            command,
            to          : window,
            turn        : turn,
            platform    : platform,
            traceContext: traceContext
        )
    }

    private func send(
        _ command       : InputCommand,
        to window       : AdoptedWindow,
        turn            : Turn,
        platform        : (any InputPlatform)?,
        layoutGeneration: UInt64? = nil,
        traceContext suppliedTraceContext: InputTraceContext
    ) async throws -> InputReceipt {

        var traceContext = suppliedTraceContext
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

        let resolved = platform ?? record.platform
        let previous = state
        actionInFlight = true
        transition(to: .acting, reason: .requested)
        defer {
            actionInFlight = false
            restoreActionState(previous, reason: .requested)
        }

        do {
            traceContext.beginQueue(at: DispatchTime.now().uptimeNanoseconds)
            let receipt = try await sender.send(
                command,
                to           : record.window.reference,
                correlationID: turn.correlationID,
                platform     : resolved,
                traceContext : traceContext
            )

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

    /// sendSequence posts several Commands under **one** Preparation: prepared
    /// once, restored once, with the settle paid once.
    ///
    /// The Commands stay atomic one by one and none of them is ever retried.
    /// What a sequence buys is the target's own state, which would otherwise be
    /// taken and given back between every keystroke, which on a typed string is
    /// one full pair of window server round trips per character.
    @discardableResult
    public nonisolated func sendSequence(
        _ commands: [InputCommand],
        to window : AdoptedWindow,
        turn      : Turn,
        platform  : (any InputPlatform)? = nil
    ) async throws -> [InputReceipt] {

        guard !commands.isEmpty else { throw InputFailure.noCommands }

        let traceContexts = commands.map {
            InputTraceIdentity.submitted(
                command      : $0,
                window       : window.reference,
                correlationID: turn.correlationID
            )
        }
        return try await sendSequence(
            commands,
            to           : window,
            turn         : turn,
            platform     : platform,
            traceContexts: traceContexts
        )
    }

    private func sendSequence(
        _ commands: [InputCommand],
        to window : AdoptedWindow,
        turn      : Turn,
        platform  : (any InputPlatform)?,
        traceContexts suppliedTraceContexts: [InputTraceContext]
    ) async throws -> [InputReceipt] {

        var traceContexts = suppliedTraceContexts
        let executionStarted = DispatchTime.now().uptimeNanoseconds
        for index in traceContexts.indices {
            traceContexts[index].beginExecution(at: executionStarted)
        }

        let record: WindowRecord
        do {
            record = try preflight(window, turn: turn, traceContexts: &traceContexts)
        } catch {
            let completedAt = DispatchTime.now().uptimeNanoseconds
            for traceContext in traceContexts {
                sender.recordCompletedTrace(traceContext.completed(at: completedAt))
            }
            throw error
        }
        let resolved = platform ?? record.platform
        let previous = state
        actionInFlight = true
        transition(to: .acting, reason: .requested)
        defer {
            actionInFlight = false
            restoreActionState(previous, reason: .requested)
        }

        do {
            let queueStartedAt = DispatchTime.now().uptimeNanoseconds
            for index in traceContexts.indices {
                traceContexts[index].beginQueue(at: queueStartedAt)
            }
            let receipts = try await sender.sendSequence(
                commands,
                to           : record.window.reference,
                correlationID: turn.correlationID,
                platform     : resolved,
                traceContexts: traceContexts
            )

            return receipts.map { finish($0, returningTo: previous) }

        } catch let failure as InputSequenceFailure {
            let completed = failure.completedReceipts.map { finish($0, returningTo: previous) }
            if failure.progress?.neededRecovery != nil,
               !completed.contains(where: \.hasUnrestoredPreparation) {
                report([.preparationNotRestored])
            }
            restoreActionState(previous, reason: .cancelled)
            throw InputSequenceFailure(
                completedReceipts: completed,
                cause            : failure.cause,
                progress         : failure.progress,
                cleanupCause     : failure.cleanupCause
            )
        } catch let failure as InputPreparationFailure {
            if failure.progress.neededRecovery != nil {
                report([.preparationNotRestored])
            }
            restoreActionState(previous, reason: .cancelled)
            throw failure
        } catch {
            restoreActionState(previous, reason: .cancelled)
            throw error
        }
    }

    // MARK: The contextual menu

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
    /// Leaving them for the caller would also strand the hold, because an
    /// action that refuses after posting hands back an error and no Receipt to
    /// answer with, and a hold that cannot be given back is a seat that is
    /// finished. What the item did **inside** the target is a further question
    /// and it stays the caller's, answered on the caller's own next Command.
    @discardableResult
    public func useContextMenu(
        openedAt location: InputLocation,
        of window        : AdoptedWindow,
        turn             : Turn,
        within deadline  : Duration = .milliseconds(1500),
        choosing choose  : (ContextMenu) -> CGPoint? = { _ in nil }
    ) async throws -> ContextMenuReceipt {

        var openingTrace = InputTraceIdentity.submitted(
            command      : .click(location, button: .right),
            window       : window.reference,
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
        let target   = record.window.reference
        let previous = state
        actionInFlight = true
        transition(to: .acting, reason: .requested)
        defer {
            actionInFlight = false
            restoreActionState(previous, reason: .requested)
        }

        guard sensing.menuWindows(ownedBy: target.processID).isEmpty else {
            restoreActionState(previous, reason: .cancelled)
            throw SessionFailure.contextMenuAlreadyOpen(processID: target.processID)
        }

        let postedAt = ContinuousClock.now
        let opening : InputReceipt
        do {
            openingTrace.beginQueue(at: DispatchTime.now().uptimeNanoseconds)
            opening = witnessed(
                try await sender.send(
                    .click(location, button: .right),
                    to           : target,
                    correlationID: turn.correlationID,
                    platform     : record.platform,
                    traceContext : openingTrace
                )
            )
        } catch {
            restoreActionState(previous, reason: .cancelled)
            throw error
        }

        var appeared: WindowReference?
        _ = await EventLoopWait.until(
            {
                appeared = self.sensing.menuWindows(ownedBy: target.processID).first
                return appeared != nil
            },
            timeout : deadline,
            interval: .milliseconds(30)
        )
        guard let appeared else {
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
            if let late = sensing.menuWindows(ownedBy: target.processID).first {
                report([.contextMenuLeftOpen])
                throw SessionFailure.contextMenuNotClosed(
                    menuWindowNumber: late.windowNumber,
                    processID       : target.processID
                )
            }
            throw SessionFailure.contextMenuNeverOpened(
                windowNumber: target.windowNumber,
                within      : deadline
            )
        }
        let menu = ContextMenu(
            window       : appeared,
            appearedAfter: postedAt.duration(to: .now)
        )

        var chosenPoint  : CGPoint?
        var choosing     : InputReceipt?
        var choiceFailure: (any Error)?

        if let point = choose(menu) {
            chosenPoint = point
            do {
                // Routed to the **menu's** window and not to the target's, and
                // posted through a platform that prepares nothing: a
                // Preparation applied now would close the menu before the click
                // reached it.
                choosing = witnessed(
                    try await sender.send(
                        .click(try pointInside(menu, at: point), button: .left),
                        to           : menu.window,
                        correlationID: turn.correlationID,
                        platform     : AppKitPlatform()
                    )
                )
            } catch {
                choiceFailure = error
            }
        }

        let closedBy = await close(menu, of: target, turn: turn, itemWasChosen: chosenPoint != nil)

        // A selected command may activate the target after the menu fades.
        // Keep observing through that delay, including for identified items.
        if chosenPoint != nil {
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

        guard let closedBy else {
            report([.contextMenuLeftOpen])
            throw SessionFailure.contextMenuNotClosed(
                menuWindowNumber: menu.window.windowNumber,
                processID       : target.processID
            )
        }
        if let choiceFailure { throw choiceFailure }

        return ContextMenuReceipt(
            menu       : menu,
            opening    : opening,
            chosenPoint: chosenPoint,
            choosing   : choosing,
            closedBy   : closedBy
        )
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
    private func pointInside(
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
    private func close(
        _ menu       : ContextMenu,
        of target    : WindowReference,
        turn         : Turn,
        itemWasChosen: Bool
    ) async -> ContextMenuReceipt.Closure? {

        // Any menu of the target, not only the one that was opened. Clicking an
        // item that carries a submenu closes the parent and opens a **new**
        // window at the same level, so a check against the original Window ID
        // would read "closed" with a submenu still on the screen. Nothing else
        // of the target's can be here: the action refused to start if one was.
        func isOpen() -> Bool {
            !sensing.menuWindows(ownedBy: target.processID).isEmpty
        }

        // Choosing an item dismisses the menu, which is the ordinary ending. The
        // wait is not padding: the dismissal is the target's own animation and
        // not an answer to the click, measured at 457 ms on a native target and
        // under 400 ms on a browser, so the budget is the larger of those plus
        // half again. Too short and a menu that closed by itself is closed a
        // second time by a Preparation cycle nobody needed.
        if itemWasChosen,
           await EventLoopWait.until(
               { !isOpen() }, timeout: .milliseconds(700), interval: .milliseconds(30)
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
        if await EventLoopWait.until(
            { !isOpen() }, timeout: .milliseconds(500), interval: .milliseconds(30)
        ) {
            return .preparationCycle
        }

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
        if await EventLoopWait.until(
            { !isOpen() }, timeout: .milliseconds(500), interval: .milliseconds(30)
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

        recoveryTask?.cancel()
        recoveryTask = nil
        transition(to: .failed, reason: .issues(issues))
        turns.failAll(with: SeatInterruption(issues: issues))
    }

    /// Lets every window go, best effort, and answers what happened to each.
    /// Used by the host's teardown, including the fail-closed one, where the
    /// point is the report: the person has to be told which windows did not
    /// make it back.
    func releaseAllWindows(_ mode: ReleaseMode) async -> [Int: WindowReleaseOutcome] {

        reportStrandedKeys()
        isTearingDown = true
        if adoptionInFlight {
            await withCheckedContinuation { adoptionWaiters.append($0) }
        }
        var outcomes = adoptionRestorations
        for id in pendingAdoptions.keys.sorted() {
            guard let window = pendingAdoptions[id] else { continue }
            outcomes[id] = await restorePendingAdoption(window).outcome
        }
        pendingAdoptions.removeAll()
        adoptionRestorations.removeAll()

        for window in adoptedWindows {
            outcomes[window.id] = await release(window, mode)
        }

        return outcomes
    }

    // MARK: The preflight

    /// Everything that has to be true before an event goes out, in the order it
    /// has to be true in.
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

        // Recovery follows the requested adopted window. The display baseline
        // remains the one already recorded by the seat.
        if let baseline = seatGuard {
            seatGuard = SeatGuard(
                target       : record.window.reference,
                displayID    : baseline.displayID,
                displayBounds: baseline.displayBounds
            )
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

        guard record.isStaged else {
            // The window is a Stage Manager thumbnail. Posting into a thumbnail
            // sends the events to coordinates the window does not occupy, so
            // this is a refusal and not a silent stage: staging is half a
            // second of animation and the caller has to know it happened.
            report([.windowStashed])
            throw SeatInterruption(issues: [.windowStashed])
        }

        beginObservationIfNeeded(for: record, turn: turn)
        return record
    }

    private func preflight(
        _ window     : AdoptedWindow,
        turn         : Turn,
        traceContexts: inout [InputTraceContext]
    ) throws -> WindowRecord {

        guard var first = traceContexts.first else {
            throw InputFailure.noCommands
        }
        defer {
            traceContexts[0] = first

            let measured = first.windowVerification
            for index in traceContexts.indices.dropFirst() {
                guard let start = measured.startedAtNanoseconds,
                      let end = measured.completedAtNanoseconds
                else { continue }
                traceContexts[index].recordWindowVerification(from: start, through: end)
            }
        }
        return try preflight(window, turn: turn, traceContext: &first)
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

    /// Install only through a host configured for recovery. The private writer
    /// never receives an arbitrary caller-selected user window.
    func enableFocusRecovery(driver: InputDriver, allowUnvalidatedBuild: Bool, usesKeyRecords: Bool = false) throws {
        let restorer = try UserFocusRestorer(allowUnvalidatedBuild: allowUnvalidatedBuild, usesKeyRecords: usesKeyRecords)
        focusRecoveryReadiness = restorer.readiness
        let recovery = UserFocusRecovery(sensing: sensing, gate: driver.commandGate,
            adopted: { [weak self] in self?.adoptedWindows.map(\.reference) ?? [] },
            restore: { try restorer.restore($0) },
            requestTiming: { restorer.timing },
            prepareDestination: { try restorer.prepare($0, targets: $1) },
            isFrontmost: { restorer.isFrontmost(processID: $0) },
            changed: { [weak self] report in self?.focusRecoveryChanged(report) })
        focusRecovery = recovery
        driver.commandGate.setPreparation { [weak self, weak recovery] correlationID in
            guard let self, let recovery else { throw InputFailure.inputPaused }
            @MainActor func checkAction() throws {
                guard self.focusRecovery === recovery, self.actionInFlight, self.state == .acting,
                      self.turns.current?.correlationID == correlationID else { throw InputFailure.inputPaused }
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

    func stopFocusRecovery() {
        focusWatch?.stop()
        focusWatch = nil
        focusRecovery?.stop()
        focusRecovery = nil
    }

    private func focusRecoveryChanged(_ report: UserFocusRecoveryReport) {
        lastFocusRecovery = report
        eventChannel.yield(.userFocusRecoveryChanged(report))
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
        case .waitingForUser, .cancelled:
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
    private func confirmPlacement(
        of window     : WindowReference,
        expectedOrigin: CGPoint,
        within bounds : CGRect
    ) async throws -> WindowReference {

        var previous: WindowReference?
        var last    : WindowReference?
        var didAttemptStage = false

        for _ in 0..<20 {
            try checkAdoptionMayContinue()
            await EventLoopWait.step(.milliseconds(100))
            try checkAdoptionMayContinue()

            guard let reading = sensing.windowGeometry(of: window.windowNumber) else {
                previous = nil
                continue
            }

            last = reading

            guard reading.hasSameIdentity(as: window) else {
                throw SeatInterruption(issues: [.identityChanged])
            }

            if !didAttemptStage,
               reading.frame.width < window.frame.width - 2 || reading.frame.height < window.frame.height - 2 {
                didAttemptStage = true
                let requested = window.replacingFrame(
                    CGRect(origin: expectedOrigin, size: window.frame.size)
                )
                _ = try await placing.stage(
                    requested,
                    expectedSize: window.frame.size,
                    within      : bounds
                )
                try checkAdoptionMayContinue()
                previous = nil
                continue
            }

            if let previous,
               VirtualWindowPlacementCheck.framesMatch(previous.frame, reading.frame),
               bounds.contains(reading.frame) {
                return reading
            }

            previous = reading
        }

        throw DisplayFailure.placementNotConfirmed(
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
    private func restorePendingAdoption(_ window: AdoptedWindow) async -> (outcome: WindowReleaseOutcome, error: (any Error)?) {
        var writeError: (any Error)?
        guard sensing.isActive(processID: window.reference.processID) != nil else { return (.vanished, writeError) }
        guard sensing.physicalTopologyIsUnchanged else { return (.refused, writeError) }
        var previousMatched = false
        var requested = false
        for _ in 0..<10 {
            guard sensing.isActive(processID: window.reference.processID) != nil else { return (.vanished, writeError) }
            guard sensing.physicalTopologyIsUnchanged else { return (.refused, writeError) }
            if let reading = sensing.windowGeometry(of: window.id) {
                guard reading.hasSameIdentity(as: window.reference) else { return (.refused, writeError) }
                let matches: Bool
                do { matches = try originalFrameMatches(window, server: reading) }
                catch { writeError = error; return (.refused, writeError) }
                if matches, previousMatched { return (.returned, writeError) }
                previousMatched = matches
                if !matches, !requested {
                    requested = true
                    do { try placing.move(window.reference, to: window.originalFrame.origin) }
                    catch { writeError = error }
                }
            } else { previousMatched = false }
            await EventLoopWait.step(.milliseconds(100))
        }
        return (.refused, writeError)
    }

    /// A thumbnail outside the virtual display cannot expose its body's frame.
    /// In that case require the same server identity, unchanged topology and
    /// the exact AX body at the original physical origin. Callers require two
    /// consecutive matches; an AX frame alone never confirms a virtual move.
    private func originalFrameMatches(
        _ window: AdoptedWindow,
        server  : WindowReference
    ) throws -> Bool {
        guard server.hasSameIdentity(as: window.reference),
              sensing.physicalTopologyIsUnchanged else { return false }
        if VirtualWindowPlacementCheck.framesMatch(server.frame, window.originalFrame) { return true }
        let frame = server.frame
        guard frame.width > 0, frame.height > 0,
              frame.width < window.originalFrame.width - 2,
              frame.height < window.originalFrame.height - 2,
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
        _ mode  : ReleaseMode
    ) async -> WindowReleaseOutcome {

        guard mode == .returnToUserSeat else { return .leftOnVirtualDisplay }

        guard sensing.isActive(processID: window.reference.processID) != nil else {
            return .vanished
        }

        let bounds = sensing.virtualDisplayBounds

        var previousMatched = false
        for _ in 0..<3 {
            guard sensing.physicalTopologyIsUnchanged else { return .refused }
            do {
                if !previousMatched { try placing.move(window.reference, to: window.originalFrame.origin) }
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

            await EventLoopWait.step(.milliseconds(150))

            guard let reading = sensing.windowGeometry(of: window.id) else {
                previousMatched = false
                if sensing.isActive(processID: window.reference.processID) == nil { return .vanished }
                continue
            }

            do {
                let matches = try originalFrameMatches(window, server: reading)
                if matches && previousMatched { return .returned }
                previousMatched = matches
            } catch { return .refused }
        }

        return .refused
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
    public func report(_ issues: [SeatIssue]) {

        guard !issues.isEmpty, state != .failed else { return }

        for issue in issues { eventChannel.yield(.issueDetected(issue, cause: nil)) }
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
        if next == .failed { stopFocusRecovery() }

        let previous = state
        state = next
        eventChannel.yield(.seatStateChanged(from: previous, to: next, reason: reason))

        Self.log.info("""
            seat \(previous.rawValue, privacy: .public) -> \
            \(next.rawValue, privacy: .public)
            """)
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
        do {
            try recoveryBudget.begin(
                issues        : issues,
                inputWasPosted: !posted.isEmpty,
                confirmation  : worstConfirmation
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

        var plan = WindowRecoveryPlan(
            target        : seatGuard.target,
            expectedOrigin: seatGuard.target.frame.origin,
            displayBounds : sensing.virtualDisplayBounds
        )

        while !Task.isCancelled, state == .recovering {

            await EventLoopWait.sleep(plan.cadence)
            guard !Task.isCancelled, state == .recovering else { return }

            let step = plan.step(
                server        : sensing.windowGeometry(of: record.window.id),
                targetIsActive: sensing.isActive(processID: record.window.reference.processID)
            )

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

                case .fail(let issue):
                    eventChannel.yield(.issueDetected(issue, cause: nil))
                    if await handedOverAfterDestruction(of: record) { return }
                    transition(to: .failed, reason: .issues([issue]))
                    turns.failAll(with: SeatInterruption(issues: [issue]))
                    return
            }
        }
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
