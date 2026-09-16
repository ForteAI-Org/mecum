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
        guard allowed, !isPaused else { throw InputFailure.inputPaused }
        invalidatePreparation()
        guard sensing.fenceIsActive else { throw InputFailure.inputPaused }
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
        guard allowed, !isPaused, sensing.fenceIsActive else { throw InputFailure.inputPaused }
        guard generation == preparationGeneration,
              now() &- start <= Self.preparationLifetimeNanoseconds,
              sensing.frontmostProcessID == destination.processID,
              !sensing.userMayBeSwitchingApplications,
              adopted() == targets, let snapshot else { return }
        prepared = PreparedAction(snapshot: snapshot, destination: destination,
                                  targets: targets, started: start, duration: now() &- start,
                                  identityDuration: identityDuration)
    }

    private func invalidatePreparation() {
        preparationGeneration &+= 1
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
        gate.pause()
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
        let fresh = !attempted && action.map {
            detected &- $0.started <= Self.preparationLifetimeNanoseconds && $0.targets == targets
        } == true
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
            timing.requestFinishedNanoseconds = now() &- started
            requestRefusal = refusal
            if let refusal { emit(.waitingForUser, detail: refusal) }
        } else {
            let reason: String
            if !fresh { reason = "No fresh prepared action or attempt available" }
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
            else if !visibleValid { reason = "A prepared target window is outside the virtual display" }
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
                gate.resume()
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
        gate.pause()
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
