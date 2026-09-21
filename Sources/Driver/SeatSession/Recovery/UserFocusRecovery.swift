import Foundation
import Dispatch
import CoreGraphics
import SeatCore
import SeatInput

/// One attempt per hold, directed only at the last observed user window. A
/// failed or repeated activation leaves input paused until the user returns.
/// All callbacks and state live on the main actor, including timer teardown.
final class UserFocusRecovery {
    private let sensing: any SeatSensing
    private let gate: InputCommandGate
    private let adopted: () -> [WindowReference]
    private let restore: (WindowReference) throws -> Int32
    private let changed: (UserFocusRecoveryReport) -> Void
    private let now: () -> UInt64
    private let requestTiming: () -> UserFocusRequestTiming
    private let prepareDestination: (WindowReference, [WindowReference]) throws -> Void
    private let isFrontmost: (Int32) -> Bool
    private var requestRefusal: String?
    private var timing = UserFocusRecoveryTiming()

    // One second covers the existing 800 ms delayed menu activation observation.
    // Age starts before AX/WindowServer reads, so slow preparation cannot renew it.
    static let preparationLifetimeNanoseconds: UInt64 = 1_000_000_000
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
    private var destinationPreparation: UInt64 = 0
    private var destination: WindowReference?
    private var candidate: WindowReference?
    private var started: UInt64 = 0
    private var activatingPID: Int32 = 0
    private var code: Int32?
    private var frontmostRestored: UInt64?
    private var attempted = false
    private var allowed = false
    private var timer: Timer?
    private var userSelectedDestination = false
    private(set) var isPaused = false

    init(sensing: any SeatSensing, gate: InputCommandGate,
         adopted: @escaping () -> [WindowReference],
         restore: @escaping (WindowReference) throws -> Int32,
         now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         requestTiming: @escaping () -> UserFocusRequestTiming = { UserFocusRequestTiming() },
         prepareDestination: @escaping (WindowReference, [WindowReference]) throws -> Void = { _, _ in },
         isFrontmost: ((Int32) -> Bool)? = nil,
         changed: @escaping (UserFocusRecoveryReport) -> Void) {
        self.sensing = sensing
        self.gate = gate
        self.adopted = adopted
        self.restore = restore
        self.now = now
        self.requestTiming = requestTiming
        self.prepareDestination = prepareDestination
        self.isFrontmost = isFrontmost ?? { sensing.frontmostProcessID == $0 }
        self.changed = changed
    }

    func beginHold() {
        guard !isPaused else { return }
        invalidatePreparation()
        attempted = false
        allowed = true
        let destinationStart = now()
        rememberUserWindow()
        destinationPreparation = now() &- destinationStart
    }

    func endHold() {
        allowed = false
        invalidatePreparation()
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
        guard !attempted else { return }
        let start = now()
        rememberUserWindow()
        let generation = preparationGeneration
        let targets = adopted()
        guard let destination else { return }
        let identityStart = now()
        // A failed read is an unarmed action, not evidence that it posted input.
        do { try prepareDestination(destination, targets) }
        catch { return }
        let identityDuration = now() &- identityStart
        let processIDs = Set(targets.map(\.processID)).union([destination.processID])
        let snapshot = await sensing.prepareFocusRecoverySnapshot(for: processIDs)
        try Task.checkCancellation()
        guard allowed else { throw InputFailure.inputPaused([.holdEnded]) }
        guard !isPaused else { throw InputFailure.inputPaused([.activationUnverified]) }
        guard sensing.fenceIsActive else { throw InputFailure.inputPaused([.fenceInactive]) }
        guard generation == preparationGeneration,
              now() &- start <= Self.preparationLifetimeNanoseconds,
              sensing.frontmostProcessID == destination.processID,
              !sensing.userMayBeSwitchingApplications,
              adopted() == targets, let snapshot else { return }
        prepared = PreparedAction(snapshot: snapshot, destination: destination,
                                  targets: targets, started: start, duration: now() &- start,
                                  identityDuration: identityDuration)
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
        let targets = adopted()
        guard targets.contains(where: { $0.processID == processID }) else {
            if isPaused {
                if processID == destination?.processID, frontmostRestored == nil {
                    frontmostRestored = now() &- started
                }
                // An application other than the recovery destination was
                // chosen while recovering. Its current window is authoritative.
                if processID != destination?.processID {
                    destination = currentUserWindow()
                    userSelectedDestination = true
                    candidate = nil
                }
                verify()
            } else {
                rememberUserWindow()
            }
            return
        }
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
        emit(.restoring)

        var checkpoint = now()
        timing.pauseAndPublicationNanoseconds = checkpoint &- started
        let action = prepared
        invalidatePreparation()
        // The four ways a preparation can fail to arm this activation are four
        // different situations with four different answers, so each one is
        // named. They used to share one sentence, which told a consumer that
        // something was missing and never which thing.
        let spent          = attempted
        let age            = action.map { detected &- $0.started }
        let expired        = age.map { $0 > Self.preparationLifetimeNanoseconds } ?? false
        let targetsChanged = action.map { $0.targets != targets } ?? false
        let fresh = !spent && action != nil && !expired && !targetsChanged
        let snapshot = fresh ? action?.snapshot : nil
        timing.actionPreparationNanoseconds = action?.duration ?? 0
        timing.preparedIdentityNanoseconds = action?.identityDuration ?? 0
        timing.preparedWindowsNanoseconds = action?.snapshot.windowsNanoseconds ?? 0
        timing.preparedSnapshotAgeNanoseconds = action.map { detected &- $0.started } ?? 0
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
        attempted = true
        if mayRestore, let destination {
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
                    reason = "The one automatic request of this hold was already spent"
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
        guard isPaused else { return }
        timer = Timer(timeInterval: 0.005, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.verify() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func verify() {
        guard isPaused else { return }
        guard sensing.physicalTopologyIsUnchanged, sensing.virtualDisplayIsOnline,
              sensing.fenceIsActive else { return }
        if sensing.frontmostProcessID == destination?.processID, frontmostRestored == nil {
            frontmostRestored = now() &- started
        }
        if let current = currentUserWindow(), let destination,
           current.hasSameIdentity(as: destination) {
            if candidate?.hasSameIdentity(as: current) == true {
                timer?.invalidate()
                timer = nil
                isPaused = false
                // The episode is over, so its one automatic request is over with
                // it. The budget is one request per activation, not one per
                // hold: an application that activates itself twice in one hold
                // is one dialog opening and then another, and the second had no
                // way to ask. A hold spans a whole run in a consumer that holds
                // the seat across Commands, which made the second activation of
                // that run wait for a person who may not be there.
                attempted = false
                gate.resume(.focusRecovery)
                emit(userSelectedDestination ? .userTookControl : .restored)
                return
            }
            candidate = current
        } else { candidate = nil }
        if now() &- started >= 250_000_000, timer?.timeInterval == 0.005 {
            emit(.waitingForUser, detail: requestRefusal ?? "Focus was not verified within 250 ms")
            timer?.invalidate()
            timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.verify() }
            }
            if let timer { RunLoop.main.add(timer, forMode: .common) }
        }
    }

    func userWindowChanged() {
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
        allowed = false
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
