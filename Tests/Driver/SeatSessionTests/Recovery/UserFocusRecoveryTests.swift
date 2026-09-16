import CoreGraphics
import Foundation
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

@Suite("User focus recovery")
@MainActor
struct UserFocusRecoveryTests {
    private static func reference(
        processID   : Int32,
        windowNumber: Int,
        frame       : CGRect
    ) -> WindowReference {
        WindowReference(
            identity: WindowIdentity(
                process: ProcessIdentity(
                    processID       : processID,
                    serialNumberHigh: 1,
                    serialNumberLow : UInt32(bitPattern: processID)
                ),
                windowNumber     : windowNumber,
                ownerConnectionID: processID &+ 1_000
            ),
            frame: frame
        )
    }

    private static let user = reference(
        processID   : 99,
        windowNumber: 801,
        frame       : CGRect(x: 100, y: 100, width: 600, height: 500)
    )
    private static let other = reference(
        processID   : 100,
        windowNumber: 802,
        frame       : CGRect(x: 110, y: 110, width: 600, height: 500)
    )

    @Test("notification provenance survives verification without changing the recovery gate")
    func notificationProvenance() async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        fixture.sensing.frontmostProcessID = FakeGeometry.targetPID
        fixture.recovery.activationChanged(to: FakeGeometry.targetPID,
            source: .workspaceNotification, receivedAt: fixture.time - 300)
        fixture.returnUser()
        #expect(fixture.reports.last?.timing.activationSource == .workspaceNotification)
        #expect(fixture.reports.last?.timing.notificationReceivedAtUptimeNanoseconds == fixture.time - 300)
        #expect(fixture.reports.last?.outcome == .restored)
        fixture.recovery.stop()
    }

    @Test("the gate closes before restoration and needs two matching focus readings")
    func closesBeforeRestoring() async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        fixture.activateTarget()
        #expect(fixture.requested == [Self.user])
        #expect(fixture.gate.isPaused)
        #expect(throws: InputFailure.inputPaused) { try fixture.gate.check() }
        fixture.sensing.frontmostProcessID = Self.user.processID
        fixture.sensing.focusedUserWindow = Self.other
        fixture.recovery.verify()
        #expect(fixture.gate.isPaused, "An active app is not proof of the correct focused window")
        fixture.sensing.focusedUserWindow = Self.user
        fixture.recovery.verify()
        #expect(fixture.gate.isPaused)
        fixture.recovery.verify()
        #expect(!fixture.gate.isPaused)
        #expect(fixture.reports.last?.outcome == .restored)
        fixture.recovery.stop()
    }

    @Test("a removed, physical target, uncertain user gesture or missing destination cannot be restored",
          arguments: 0..<5)
    func refusesUnsafeDestination(_ variant: Int) async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        switch variant {
        case 0:
            fixture.sensing.additionalWindows[Self.user.windowNumber] = nil
            fixture.sensing.focusRecoverySnapshot = nil
        case 1:
            fixture.sensing.focusRecoverySnapshot = FocusRecoverySnapshot(topologyIsValid: true,
                virtualBounds: FakeGeometry.virtual, physicalBounds: [FakeGeometry.physical],
                windows: [Self.user, FakeGeometry.reference(frame: Self.user.frame)])
        case 2: fixture.sensing.userMayBeSwitchingApplications = true
        case 3: fixture.sensing.userWindowIsPhysical = false
        default: fixture.sensing.physicalTopologyIsUnchanged = false
        }
        try await fixture.recovery.prepareBeforeAction()
        fixture.activateTarget()
        #expect(fixture.requested.isEmpty)
        #expect(fixture.gate.isPaused)
        #expect(fixture.reports.last?.outcome == .waitingForUser)
        fixture.recovery.stop()
    }

    @Test("failed verification and repeated activation stay paused without retrying")
    func noRetry() async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        fixture.activateTarget()
        fixture.time += 300_000_000
        fixture.recovery.verify()
        #expect(fixture.reports.last?.outcome == .waitingForUser)
        #expect(fixture.gate.isPaused)
        fixture.returnUser()
        try await fixture.recovery.prepareBeforeAction()
        fixture.activateTarget()
        #expect(fixture.requested.count == 1)
        #expect(fixture.gate.isPaused)
        fixture.returnUser()
        #expect(!fixture.gate.isPaused)
        fixture.recovery.stop()
    }

    @Test("the latest user application replaces the cached destination")
    func followsUser() async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        fixture.sensing.frontmostProcessID = Self.other.processID
        fixture.sensing.focusedUserWindow = Self.other
        fixture.recovery.activationChanged(to: Self.other.processID)
        try await fixture.recovery.prepareBeforeAction()
        fixture.activateTarget()
        #expect(fixture.requested == [Self.other])
        fixture.recovery.stop()
    }

    @Test("a user switch during recovery wins, with no second activation request")
    func userWinsDuringRecovery() async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        fixture.activateTarget()
        fixture.sensing.frontmostProcessID = Self.other.processID
        fixture.sensing.focusedUserWindow = Self.other
        fixture.recovery.activationChanged(to: Self.other.processID)
        fixture.recovery.verify()
        #expect(fixture.reports.last?.outcome == .userTookControl)
        #expect(fixture.requested == [Self.user])
        #expect(!fixture.gate.isPaused)
        fixture.recovery.stop()
    }

    @Test("stopping invalidates a pending recovery and never reopens its gate")
    func teardown() async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        fixture.activateTarget()
        fixture.recovery.stop()
        fixture.returnUser()
        #expect(fixture.gate.isPaused)
        #expect(fixture.reports.last?.outcome == .cancelled)
    }

    @Test("an idle target activation is left to the user")
    func idle() {
        let fixture = Harness()
        fixture.activateTarget()
        #expect(fixture.requested.isEmpty)
        #expect(!fixture.gate.isPaused)
        fixture.recovery.stop()
    }

    @Test("a shared reading retains every destination and virtual-window guard", arguments: 0..<9)
    func batchedReadings(_ variant: Int) async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        var windows = [Self.user, FakeGeometry.adoptedWindow]
        var physical = [CGRect(x: 0, y: 0, width: 1800, height: 1000)]
        switch variant {
        case 1:
            windows.append(FakeGeometry.reference(frame: Self.user.frame, windowNumber: 999))
        case 2:
            windows[0] = Self.reference(
                processID   : 123,
                windowNumber: Self.user.windowNumber,
                frame       : Self.user.frame
            )
        case 3: windows.removeLast()
        case 4: windows[0] = Self.user.replacingFrame(.zero)
        case 5: physical = []
        case 7: windows.removeFirst()
        case 8: fixture.sensing.fenceIsActive = false
        default: break
        }
        fixture.sensing.focusRecoverySnapshot = FocusRecoverySnapshot(
            topologyIsValid: variant != 6,
            virtualBounds: FakeGeometry.virtual,
            physicalBounds: physical,
            windows: windows)
        if variant == 8 {
            await #expect(throws: InputFailure.inputPaused) { try await fixture.recovery.prepareBeforeAction() }
        } else { try await fixture.recovery.prepareBeforeAction() }
        fixture.activateTarget()
        #expect(fixture.requested.count == (variant == 0 ? 1 : 0))
        #expect(fixture.gate.isPaused)
        if variant != 0 {
            #expect(fixture.reports.last?.timing.requestFinishedNanoseconds == 0)
        }
        fixture.recovery.stop()
    }

    @Test("activation without a prepared action waits instead of scanning windows")
    func missingPreparationWaits() {
        let fixture = Harness()
        fixture.recovery.beginHold()
        fixture.activateTarget()
        #expect(fixture.requested.isEmpty)
        #expect(fixture.gate.isPaused)
        #expect(fixture.sensing.snapshotReadCount == 0)
        fixture.recovery.stop()
    }

    @Test("activation consumes prepared readings without another window enumeration")
    func preparedReadingsLeaveUrgentPath() async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        #expect(fixture.sensing.snapshotReadCount == 1)
        fixture.sensing.focusRecoverySnapshot = nil
        fixture.activateTarget()
        #expect(fixture.requested == [Self.user])
        #expect(fixture.sensing.snapshotReadCount == 1)
        fixture.recovery.stop()
    }

    @Test("an expired preparation pauses with no fallback scan or activation")
    func expiration() async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        fixture.time += UserFocusRecovery.preparationLifetimeNanoseconds + 1
        fixture.activateTarget()
        #expect(fixture.requested.isEmpty)
        #expect(fixture.gate.isPaused)
        #expect(fixture.sensing.snapshotReadCount == 1)
        fixture.recovery.stop()
    }

    @Test("a user window notification invalidates a completed preparation")
    func changedWindow() async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        fixture.recovery.userWindowChanged()
        fixture.activateTarget()
        #expect(fixture.requested.isEmpty)
        #expect(fixture.gate.isPaused)
        fixture.recovery.stop()
    }

    @Test("late preparation cannot survive a changed hold, user, teardown, target set or cancellation",
          arguments: 0..<7)
    func latePreparation(_ variant: Int) async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        var resume: CheckedContinuation<FocusRecoverySnapshot?, Never>?
        let snapshot = fixture.sensing.preparedSnapshot
        fixture.sensing.snapshotPreparation = {
            await withCheckedContinuation { resume = $0 }
        }
        let task = Task { try await fixture.recovery.prepareBeforeAction() }
        while resume == nil { await Task.yield() }
        switch variant {
        case 0: fixture.recovery.endHold(); fixture.recovery.beginHold()
        case 1:
            fixture.sensing.frontmostProcessID = Self.other.processID
            fixture.sensing.focusedUserWindow = Self.other
            fixture.recovery.activationChanged(to: Self.other.processID)
        case 2: fixture.recovery.stop()
        case 3: fixture.recovery.userWindowChanged()
        case 4: fixture.targets.append(Self.other)
        case 5: task.cancel()
        default: fixture.sensing.fenceIsActive = false
        }
        resume?.resume(returning: snapshot)
        let result = await task.result
        if variant == 2 || variant == 5 || variant == 6 {
            if case .success = result { Issue.record("Cancelled preparation must refuse posting") }
        }
        fixture.activateTarget()
        #expect(fixture.requested.isEmpty)
        fixture.recovery.stop()
    }

    @Test("current topology and user intent still veto a prepared request", arguments: 0..<3)
    func liveGuards(_ variant: Int) async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        switch variant {
        case 0: fixture.sensing.physicalTopologyIsUnchanged = false
        case 1: fixture.sensing.virtualDisplayIsOnline = false
        default: fixture.sensing.userMayBeSwitchingApplications = true
        }
        fixture.activateTarget()
        #expect(fixture.requested.isEmpty)
        #expect(fixture.gate.isPaused)
        #expect(fixture.sensing.snapshotReadCount == 1)
        fixture.recovery.stop()
    }

    @Test("identity reads happen before input; a missing identity leaves recovery unarmed", arguments: [false, true])
    func preparedIdentity(_ missing: Bool) async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        fixture.identityUnavailable = missing
        try await fixture.recovery.prepareBeforeAction()
        #expect(fixture.preparedDestinations == (missing ? [] : [Self.user]))
        fixture.identityUnavailable = true
        fixture.activateTarget()
        #expect(fixture.requested == (missing ? [] : [Self.user]))
        #expect(fixture.preparedDestinations == (missing ? [] : [Self.user]))
        fixture.recovery.stop()
    }

    @Test("the direct front-process witness decides; a refusal survives verification timeout", arguments: [false, true])
    func directFrontWitness(_ matches: Bool) async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        fixture.frontOverride = matches
        // The notification and NSWorkspace cache need not agree yet. The
        // injected WindowServer witness is authoritative for this last guard.
        fixture.recovery.activationChanged(to: FakeGeometry.targetPID)
        #expect(fixture.requested == (matches ? [Self.user] : []))
        if !matches {
            let detail = fixture.reports.last?.detail
            #expect(detail == "The front process no longer matches the activating target")
            fixture.sensing.frontmostProcessID = FakeGeometry.targetPID
            fixture.sensing.focusedUserWindow = nil
            fixture.time += 300_000_000
            fixture.recovery.verify()
            #expect(fixture.reports.last?.detail == detail)
        }
        fixture.recovery.stop()
    }

    @Test("a disabled fence blocks input and resumption, without delaying focus-only restoration")
    func fenceCheckedAtInputBoundaries() async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        fixture.sensing.fenceIsActive = false
        await #expect(throws: InputFailure.inputPaused) { try await fixture.recovery.prepareBeforeAction() }
        fixture.sensing.fenceIsActive = true
        try await fixture.recovery.prepareBeforeAction()
        fixture.sensing.fenceIsActive = false
        fixture.activateTarget()
        #expect(fixture.requested == [Self.user])
        fixture.returnUser()
        #expect(fixture.gate.isPaused, "No command may resume with an inactive fence")
        fixture.sensing.fenceIsActive = true
        fixture.returnUser()
        #expect(!fixture.gate.isPaused)
        fixture.recovery.stop()
    }

    @Test("a focused user window may extend beyond a physical screen without entering the virtual display",
          arguments: 0..<6)
    func partiallyVisibleUserWindow(_ variant: Int) async throws {
        let fixture = Harness()
        let physical = CGRect(x: 0, y: 0, width: 1512, height: 982)
        var frame = CGRect(x: 316, y: 58, width: 1571, height: 852)
        var physicalBounds = [physical]
        switch variant {
        case 1: frame.origin.x = -316
        case 2:
            physicalBounds.append(CGRect(x: 1512, y: 0, width: 1512, height: 982))
        case 3: frame.origin.x = 1512
        case 4: frame.origin = CGPoint(x: 1600, y: 58)
        case 5: frame.size.height = 1200
        default: break
        }
        let user = Self.user.replacingFrame(frame)
        let virtual = CGRect(x: 1512, y: 982, width: 2560, height: 1440)
        let target = FakeGeometry.reference(
            frame: CGRect(x: 2192, y: 1288, width: 1200, height: 828)
        )
        fixture.targets = [target]
        fixture.sensing.virtualDisplayBounds = virtual
        fixture.sensing.additionalWindows[user.windowNumber] = user
        fixture.sensing.focusedUserWindow = user
        fixture.sensing.focusRecoverySnapshot = FocusRecoverySnapshot(topologyIsValid: true,
            virtualBounds: virtual, physicalBounds: physicalBounds, windows: [user, target])
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        fixture.activateTarget()
        if variant < 3 {
            #expect(fixture.requested == [user])
            fixture.sensing.frontmostProcessID = user.processID
            fixture.sensing.focusedUserWindow = user
            fixture.recovery.verify()
            fixture.recovery.verify()
            #expect(fixture.reports.last?.outcome == .restored)
            #expect(!fixture.gate.isPaused)
        } else {
            #expect(fixture.requested.isEmpty)
            #expect(fixture.gate.isPaused)
        }
        fixture.recovery.stop()
    }

    @Test("an incomplete window list pauses recovery without blaming the displays")
    func incompleteWindowDiagnostic() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        fixture.sensing.focusRecoverySnapshot = FocusRecoverySnapshot(
            topologyIsValid      : true,
            virtualBounds        : FakeGeometry.virtual,
            physicalBounds       : [FakeGeometry.physical],
            windows              : [Self.user, FakeGeometry.adoptedWindow],
            windowsAreComplete   : false,
            firstUnresolvedWindow: 2
        )
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        fixture.activateTarget()
        #expect(fixture.requested.isEmpty)
        #expect(fixture.gate.isPaused)
        #expect(fixture.reports.last?.detail.contains("window list is incomplete at Window ID 2") == true)
        #expect(fixture.reports.last?.detail.contains("topology") == false)
    }

    @Test("a snapshot scoped to another process cannot authorize restoration")
    func wrongSnapshotScope() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        fixture.sensing.focusRecoverySnapshot = FocusRecoverySnapshot(
            topologyIsValid  : true,
            virtualBounds    : FakeGeometry.virtual,
            physicalBounds   : [FakeGeometry.physical],
            windows          : [Self.user, FakeGeometry.adoptedWindow],
            coveredProcessIDs: [Self.user.processID]
        )
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        fixture.activateTarget()
        #expect(fixture.requested.isEmpty)
        #expect(fixture.gate.isPaused)
    }

    @Test("a physical dialog of another adopted application prevents restoration")
    func otherAdoptedProcessHasPhysicalWindow() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        let second = Self.reference(
            processID   : 5555,
            windowNumber: 901,
            frame       : FakeGeometry.adoptedWindow.frame
        )
        let dialog = Self.reference(
            processID   : second.processID,
            windowNumber: 902,
            frame       : Self.user.frame
        )
        fixture.targets.append(second)
        fixture.sensing.focusRecoverySnapshot = FocusRecoverySnapshot(
            topologyIsValid: true,
            virtualBounds  : FakeGeometry.virtual,
            physicalBounds : [FakeGeometry.physical],
            windows        : [Self.user, FakeGeometry.adoptedWindow, second, dialog]
        )
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        fixture.activateTarget()
        #expect(fixture.requested.isEmpty)
        #expect(fixture.gate.isPaused)
        #expect(fixture.reports.last?.detail == "A prepared target window is outside the virtual display")
    }

    @MainActor
    private final class Harness {
        let sensing = FakeSensing()
        let gate = InputCommandGate()
        var targets = [FakeGeometry.adoptedWindow]
        var preparedDestinations: [WindowReference] = []
        var frontOverride: Bool?
        var identityUnavailable = false
        var requested: [WindowReference] = []
        var reports: [UserFocusRecoveryReport] = []
        var time: UInt64 = 1_000_000_000
        lazy var recovery = UserFocusRecovery(sensing: sensing, gate: gate,
            adopted: { [unowned self] in targets },
            restore: { [unowned self] window in
                #expect(gate.isPaused, "The restoration call must never precede the input stop")
                requested.append(window)
                return 0
            }, now: { [unowned self] in time },
            prepareDestination: { [unowned self] destination, targets in
                if identityUnavailable { throw InputFailure.inputPaused }
                #expect(targets == self.targets)
                preparedDestinations.append(destination)
            },
            isFrontmost: { [unowned self] in frontOverride ?? (sensing.frontmostProcessID == $0) },
            changed: { [unowned self] in reports.append($0) })

        init() {
            sensing.additionalWindows = [userWindow.windowNumber: userWindow, otherWindow.windowNumber: otherWindow]
            sensing.focusedUserWindow = userWindow
            sensing.focusRecoverySnapshot = FocusRecoverySnapshot(topologyIsValid: true,
                virtualBounds: FakeGeometry.virtual, physicalBounds: [FakeGeometry.physical],
                windows: [userWindow, otherWindow, FakeGeometry.adoptedWindow])
        }
        private var userWindow: WindowReference { UserFocusRecoveryTests.user }
        private var otherWindow: WindowReference { UserFocusRecoveryTests.other }

        func activateTarget() {
            sensing.frontmostProcessID = FakeGeometry.targetPID
            sensing.focusedUserWindow = FakeGeometry.adoptedWindow
            recovery.activationChanged(to: FakeGeometry.targetPID)
        }
        func returnUser() {
            sensing.frontmostProcessID = userWindow.processID
            sensing.focusedUserWindow = userWindow
            recovery.verify()
            recovery.verify()
        }
    }
}
