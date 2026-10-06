//
//  AgentSeatTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

/// The whole seat driven through the fakes: adopt, hold, observe, send, confirm,
/// release, and every refusal in between. No display, no tap, no Accessibility
/// grant, so this runs on any machine and in parallel with everything else.
///
/// Every Command here goes through the production path: the assignment nucleus,
/// the selection nucleus, the qualifier and the admission. What the controlled
/// adapters supply is evidence, not verdicts, and supplying it proves the
/// algorithms and never the system.
@MainActor
@Suite("Agent seat")
struct AgentSeatTests {

    static let click = InputCommand.click(InputLocation(
        screenPoint       : CGPoint(x: 2700, y: 700),
        windowPointFromTop: CGPoint(x: 100, y: 100)
    ))

    /// A seat with a window already adopted, which is the starting point of
    /// everything about acting. Adoption itself is tested separately.
    /// `processID` is how a row that touches `KeyHold` gets a process nobody
    /// else is pressing keys on. The default keeps every other row exactly as
    /// it was.
    static func adopted(
        sensing  : FakeSensing = FakeSensing(),
        placing  : FakePlacing = FakePlacing(),
        sender   : FakeSender  = FakeSender(),
        processID: Int32       = FakeGeometry.targetPID,
        source   : ControlledObservationSource? = nil,
        clock    : ControlledContentClock? = nil,
        profile  : ObservationProfile = .initialLab
    ) async throws -> (seat: AgentSeat, window: AdoptedWindow) {

        sensing.targetPID = processID
        sensing.geometry  = FakeGeometry.reference(
            frame    : FakeGeometry.adoptedWindow.frame,
            processID: processID
        )
        let seat = makeSeat(
            sensing: sensing,
            placing: placing,
            sender : sender,
            source : source,
            clock  : clock,
            profile: profile
        )
        let window = try await seat.adopt(
            FakeGeometry.reference(
                frame    : FakeGeometry.userSeatWindow.frame,
                processID: processID
            ),
            platform: AppKitPlatform()
        )
        return (seat, window)
    }

    // MARK: Keys the Turn is holding

    @Test("alternating adopted windows validates each window against its own identity")
    func alternatingWindowIdentity() async throws {
        let sensing = FakeSensing()
        let (seat, first) = try await Self.adopted(sensing: sensing)
        let reference = FakeGeometry.reference(
            frame       : FakeGeometry.adoptedWindow.frame,
            windowNumber: 778
        )
        sensing.additionalWindows[reference.windowNumber] = reference
        let second = try await seat.adopt(reference, platform: AppKitPlatform())
        let turn = try await seat.acquire()
        for window in [first, second, first] {
            _ = try await seat.switchTarget(to: window)
            let observation = try await observedReference(seat)
            #expect(observation.recipient == window.reference.identity)
            let receipt = try await seat.send(Self.click, observation: observation, turn: turn)
            try seat.confirm(receipt, .observed)
            _ = await seat.concludeObservation()
        }
        try seat.release(turn)
    }

    @Test("a Turn that is still holding a key cannot be given back")
    func releaseRefusesWhileKeysAreHeld() async throws {
        let (seat, window) = try await Self.adopted(
            processID: FakeGeometry.distinctProcessID()
        )
        let turn = try await seat.acquire()
        let processID = window.reference.processID
        defer { _ = KeyHold.shared.releaseAll(owner: turn.correlationID, processID: processID) }

        KeyHold.shared.press(
            KeyHold.HeldKey(virtualKey: 56),
            owner    : turn.correlationID,
            processID: processID
        )

        // The same safe point invariant as an unconfirmed Command, one step
        // further: a held key is state inside another application, and the next
        // holder would inherit it without being told.
        #expect(throws: SessionFailure.keysStillHeld(count: 1)) {
            try seat.release(turn)
        }
    }

    @Test("the Turn comes back once what it pressed has been released")
    func releaseSucceedsAfterTheKeysAreUp() async throws {
        let (seat, window) = try await Self.adopted(
            processID: FakeGeometry.distinctProcessID()
        )
        let turn = try await seat.acquire()
        let processID = window.reference.processID

        KeyHold.shared.press(
            KeyHold.HeldKey(virtualKey: 56),
            owner    : turn.correlationID,
            processID: processID
        )
        #expect(KeyHold.shared.release(
            virtualKey: 56,
            owner     : turn.correlationID,
            processID : processID
        ))

        try seat.release(turn)
    }

    @Test("another Turn's keys do not keep this one from being given back")
    func releaseIgnoresAnotherHoldersKeys() async throws {
        let (seat, window) = try await Self.adopted(
            processID: FakeGeometry.distinctProcessID()
        )
        let turn = try await seat.acquire()
        let processID = window.reference.processID
        let stranger: Int64 = -991
        defer { _ = KeyHold.shared.releaseAll(owner: stranger, processID: processID) }

        // Refusing for somebody else's keys would make one Turn unable to
        // finish because another one is mid gesture.
        KeyHold.shared.press(
            KeyHold.HeldKey(virtualKey: 55),
            owner    : stranger,
            processID: processID
        )

        try seat.release(turn)
    }

    @Test("a seat going terminal with keys still down says so and forgets them")
    func terminalSeatReportsStrandedKeys() async throws {
        let (seat, window) = try await Self.adopted(
            processID: FakeGeometry.distinctProcessID()
        )
        let turn = try await seat.acquire()
        let processID = window.reference.processID

        var issues: [SeatIssue] = []
        let listening = Task { @MainActor in
            for await event in seat.events {
                if case .issueDetected(let issue, _) = event { issues.append(issue) }
            }
        }
        defer { listening.cancel() }

        KeyHold.shared.press(
            KeyHold.HeldKey(virtualKey: 55),
            owner    : turn.correlationID,
            processID: processID
        )

        // `release` refuses a Turn holding keys, which covers the ordinary
        // case. This is the other one: there is no Turn left to refuse, so the
        // only honest answer is to say it out loud.
        seat.failFromHost([.displayChanged])

        for _ in 0 ..< 20 { await Task.yield() }
        #expect(issues.contains(.keysNotReleased))
        // The bookkeeping is cleared, because nobody will ever send the ups.
        // The target may still hold the key, and the kit cannot fix that from a
        // failed seat, which is exactly why the Issue exists.
        #expect(KeyHold.shared.held(processID: processID).isEmpty)
    }

    @Test("a reported cause is published with its own Issue and with no other")
    func reportedCauseTravelsWithItsIssue() async throws {
        let (seat, _) = try await Self.adopted(
            processID: FakeGeometry.distinctProcessID()
        )

        var published: [(SeatIssue, SeatIssueCause?)] = []
        let listening = Task { @MainActor in
            for await event in seat.events {
                if case .issueDetected(let issue, let cause) = event {
                    published.append((issue, cause))
                }
            }
        }
        defer { listening.cancel() }

        // The batch carries a window closure and a display change. Attaching
        // the closure to the display would be the misreport, so it does not.
        seat.report(
            [.windowUnavailable, .displayChanged],
            cause: .windowClosure(.absentFromReading)
        )

        for _ in 0 ..< 20 { await Task.yield() }
        #expect(published.first { $0.0 == .windowUnavailable }?.1
            == .windowClosure(.absentFromReading))
        #expect(published.first { $0.0 == .displayChanged }?.1 == nil)
        #expect(SeatIssueCause.windowClosure(.absentFromReading).issue == .windowUnavailable)
        #expect(!ClosureEvidence.absentFromReading.provesClosure)
    }

    @Test("a seat going terminal with nothing held stays quiet about keys")
    func terminalSeatWithNoKeysIsQuiet() async throws {
        let (seat, _) = try await Self.adopted(
            processID: FakeGeometry.distinctProcessID()
        )

        var issues: [SeatIssue] = []
        let listening = Task { @MainActor in
            for await event in seat.events {
                if case .issueDetected(let issue, _) = event { issues.append(issue) }
            }
        }
        defer { listening.cancel() }

        seat.failFromHost([.displayChanged])

        for _ in 0 ..< 20 { await Task.yield() }
        #expect(!issues.contains(.keysNotReleased))
    }

    // MARK: Adoption

    @Test("a succession stopped after posting preserves its receipts and cannot be silently replayed")
    func partialSuccessionRequiresConfirmation() async throws {
        let sender = FakeSender()
        let (seat, _) = try await Self.adopted(sender: sender)
        let turn = try await seat.acquire()

        let first = try await seat.send(
            Self.click,
            observation: try await observedReference(seat),
            turn       : turn
        )
        // The second Command of the consumer's own succession is refused. The
        // first one already went out, so its Receipt stands and the Turn cannot
        // be given back until somebody says what it did.
        let second = try await observedReference(seat)
        sender.error = InputFailure.inputPaused([.focusRecovery])
        await #expect(throws: InputFailure.inputPaused([.focusRecovery])) {
            try await seat.send(Self.click, observation: second, turn: turn)
        }

        #expect(seat.unconfirmedCommandCount == 1)
        #expect(throws: SessionFailure.unconfirmedCommands(count: 1)) { try seat.release(turn) }
        try seat.confirm(first, .unknown)
        try seat.release(turn)
    }

    @Test("a focus interruption delivered during send survives its completion")
    func completionPreservesWaiting() async throws {
        let sender = FakeSender()
        let (seat, _) = try await Self.adopted(sender: sender)
        let turn = try await seat.acquire()
        sender.onSend = { _ in seat.report([.targetActivated]) }
        let receipt = try await seat.send(
            Self.click,
            observation: try await observedReference(seat),
            turn       : turn
        )
        #expect(seat.state == .waiting)
        let next = try await observedReference(seat)
        await #expect(throws: SessionFailure.seatNotReady(.waiting)) {
            try await seat.send(Self.click, observation: next, turn: turn)
        }
        #expect(sender.sent.count == 1)
        try seat.confirm(receipt, .unknown)
        try seat.release(turn)
    }

    @Test("a failed preparation cleanup degrades without inventing a posted command")
    func failedPreparationCleanupDegrades() async throws {
        let sender = FakeSender()
        sender.error = InputPreparationFailure(
            progress: InputProgress(
                completedSteps              : [.activation],
                failedStep                  : .keyWindowFirst,
                failedStepMayHaveTakenEffect: true,
                cleanup                     : .failed(code: -17)
            ),
            cause       : InputFailure.preparationFailed(step: .keyWindowFirst, code: -9),
            cleanupCause: InputFailure.restoreFailed(code: -17)
        )
        let (seat, _) = try await Self.adopted(sender: sender)
        let turn = try await seat.acquire()
        let observation = try await observedReference(seat)

        await #expect(throws: InputPreparationFailure.self) {
            try await seat.send(Self.click, observation: observation, turn: turn)
        }

        #expect(seat.state == .degraded)
        #expect(seat.unconfirmedCommandCount == 0)
        try seat.release(turn)
    }

    @Test("adopt moves the window, confirms it twice and leaves the seat ready")
    func adoptConfirms() async throws {

        let placing = FakePlacing()
        let (seat, window) = try await Self.adopted(placing: placing)

        #expect(placing.moves.count == 1)
        #expect(seat.state == .ready)
        #expect(window.originalFrame == FakeGeometry.userSeatWindow.frame)
        #expect(seat.seatGuard?.target.hasSameIdentity(as: FakeGeometry.adoptedWindow) == true)
        #expect(seat.adoptedWindows.count == 1)
        #expect(seat.isStaged(window))
    }

    @Test("adopt refuses when the window server never confirms the placement")
    func adoptNeverConfirmed() async throws {

        let sensing = FakeSensing()
        sensing.geometry = nil

        let seat = makeSeat(sensing: sensing)

        await #expect(throws: (any Error).self) {
            try await seat.adopt(FakeGeometry.userSeatWindow)
        }
        #expect(seat.state == .failed)
        #expect(seat.hasPendingWindowRestorations)
    }

    // MARK: The hold

    @Test("a command without a turn is refused before anything goes out")
    func turnRequired() async throws {

        let sender = FakeSender()
        let (seat, _) = try await Self.adopted(sender: sender)
        let observation = try await observedReference(seat)

        await #expect(throws: SessionFailure.turnRequired) {
            try await seat.send(Self.click, observation: observation, turn: Turn(
                generation              : 1,
                seatChangedSinceLastHold: false,
                correlationID           : 1
            ))
        }
        #expect(sender.sent.isEmpty)
    }

    @Test("a command on a seat that is not ready is refused, with the state as the answer")
    func seatNotReady() async throws {

        let sensing = FakeSensing()
        let sender  = FakeSender()
        let (seat, _) = try await Self.adopted(sensing: sensing, sender: sender)

        let turn = try await seat.acquire()

        // The person went into the application: the seat waits, with no
        // deadline, and refuses rather than queueing.
        sensing.targetIsActive = true
        seat.report([.targetActivated])
        #expect(seat.state == .waiting)

        let observation = try await observedReference(seat)
        await #expect(throws: SessionFailure.seatNotReady(.waiting)) {
            try await seat.send(Self.click, observation: observation, turn: turn)
        }
        #expect(sender.sent.isEmpty)
    }

    @Test("the turn's marker is the one every event is stamped with")
    func markerTravels() async throws {

        let sender = FakeSender()
        let (seat, _) = try await Self.adopted(sender: sender)

        let turn    = try await seat.acquire()
        let receipt = try await seat.send(
            Self.click,
            observation: try await observedReference(seat),
            turn       : turn
        )

        #expect(sender.sent.count == 1)
        #expect(sender.sent[0].correlationID == turn.correlationID)
        #expect(receipt.eventCount == 2)
        #expect(seat.state == .ready)
    }

    @Test("the receipt comes back with an observation, which a driver alone leaves nil")
    func receiptCarriesAnObservation() async throws {

        let (seat, _) = try await Self.adopted()
        let turn    = try await seat.acquire()
        let receipt = try await seat.send(
            Self.click,
            observation: try await observedReference(seat),
            turn       : turn
        )

        #expect(receipt.observation != nil)
    }

    // MARK: Confirmation and the anti replay invariant

    @Test("releasing the hold is refused while a command is unconfirmed")
    func releaseRefusedWithAnUnknown() async throws {

        let (seat, _) = try await Self.adopted()
        let turn = try await seat.acquire()
        _ = try await seat.send(
            Self.click,
            observation: try await observedReference(seat),
            turn       : turn
        )

        #expect(seat.unconfirmedCommandCount == 1)
        #expect(throws: SessionFailure.unconfirmedCommands(count: 1)) {
            try seat.release(turn)
        }
        #expect(seat.currentTurn == turn)
    }

    @Test("an explicit unknown still releases: the caller answered, and the answer is remembered")
    func explicitUnknownReleases() async throws {

        let (seat, _) = try await Self.adopted()
        let turn    = try await seat.acquire()
        let receipt = try await seat.send(
            Self.click,
            observation: try await observedReference(seat),
            turn       : turn
        )

        try seat.confirm(receipt, .unknown)
        try seat.release(turn)

        #expect(seat.currentTurn == nil)
    }

    @Test("confirming closes the command and lets the hold go")
    func confirmThenRelease() async throws {

        let (seat, _) = try await Self.adopted()
        let turn    = try await seat.acquire()
        let receipt = try await seat.send(
            Self.click,
            observation: try await observedReference(seat),
            turn       : turn
        )

        try seat.confirm(receipt, .observed)
        #expect(seat.unconfirmedCommandCount == 0)

        try seat.release(turn)
        #expect(seat.unconfirmedCommandCount == 0)
    }

    @Test("a confirmation out of order is refused instead of matched by guesswork")
    func confirmOutOfOrder() async throws {

        let (seat, _) = try await Self.adopted()
        let turn = try await seat.acquire()

        let first = try await seat.send(
            Self.click,
            observation: try await observedReference(seat),
            turn       : turn
        )
        let second = try await seat.send(
            Self.click,
            observation: try await observedReference(seat),
            turn       : turn
        )

        #expect(first != second)
        #expect(throws: SessionFailure.receiptOutOfOrder) {
            try seat.confirm(second, .observed)
        }

        try seat.confirm(first, .observed)
        try seat.confirm(second, .observed)
        try seat.release(turn)
    }

    @Test("confirming with nothing pending is refused")
    func nothingToConfirm() async throws {

        let (seat, _) = try await Self.adopted()
        let turn    = try await seat.acquire()
        let receipt = try await seat.send(
            Self.click,
            observation: try await observedReference(seat),
            turn       : turn
        )

        try seat.confirm(receipt, .observed)
        #expect(throws: SessionFailure.nothingToConfirm) {
            try seat.confirm(receipt, .observed)
        }
    }

    @Test("a succession the consumer orchestrates stamps every Command with its Turn")
    func successionSharesTheTurnsMarker() async throws {

        let sender = FakeSender()
        let (seat, _) = try await Self.adopted(sender: sender)

        let turn = try await seat.acquire()
        for _ in 0 ..< 3 {
            _ = try await seat.send(
                Self.click,
                observation: try await observedReference(seat),
                turn       : turn
            )
        }

        #expect(sender.sent.count == 3)
        #expect(Set(sender.sent.map(\.correlationID)) == [turn.correlationID])
    }

    // MARK: The issues, and who owns them

    @Test("a critical seat issue fails the seat and throws the waiters out")
    func criticalIssueFailsTheSeat() async throws {

        let (seat, _) = try await Self.adopted()
        let turn = try await seat.acquire()

        let waiting = Task { @MainActor in try await seat.acquire() }
        await Task.yield()

        seat.report([.identityChanged])
        #expect(seat.state == .failed)

        await #expect(throws: SeatInterruption.self) { try await waiting.value }
        _ = turn
    }

    @Test("a host issue fails the seat, and the seat does not decide it for itself")
    func hostIssueFailsTheSeat() async throws {

        let (seat, _) = try await Self.adopted()
        seat.failFromHost([.displayChanged])

        #expect(seat.state == .failed)
        await #expect(throws: SessionFailure.seatNotReady(.failed)) { _ = try await seat.acquire() }
    }

    @Test("a seat that stops for good keeps why: its Issues and the causes the host found")
    func aFailedSeatKeepsWhy() async throws {

        let (seat, _) = try await Self.adopted()
        #expect(seat.failureIssues.isEmpty && seat.failureCauses.isEmpty)
        seat.failFromHost([.displayChanged], causes: [.watchdog(.physicalDisplayAdded)])

        #expect(seat.failureIssues == [.displayChanged])
        #expect(seat.failureCauses == [.watchdog(.physicalDisplayAdded)])
        seat.failFromHost([.fenceUnavailable])
        #expect(seat.failureCauses == [.watchdog(.physicalDisplayAdded)], "a second report does not rewrite why")
    }

    @Test("a window issue leaves the seat usable: the stage failed, not the seat")
    func windowIssueLeavesTheSeatUsable() async throws {

        let (seat, _) = try await Self.adopted()
        seat.report([.windowStashed])

        #expect(seat.state == .ready)
    }

    @Test("a preparation the target refused to give back degrades the seat and keeps it acting")
    func unrestoredPreparationDegrades() async throws {

        let sender = FakeSender()
        sender.reportsUnrestoredPreparation = true

        let (seat, _) = try await Self.adopted(sender: sender)
        let turn    = try await seat.acquire()
        let receipt = try await seat.send(
            Self.click,
            observation: try await observedReference(seat),
            turn       : turn
        )

        #expect(receipt.hasUnrestoredPreparation)
        #expect(seat.state == .degraded)

        // Degraded still acts: what degraded it is not what the Command needs.
        _ = try await seat.send(
            Self.click,
            observation: try await observedReference(seat),
            turn       : turn
        )
        #expect(sender.sent.count == 2)
    }

    @Test("the admission runs on a reused window id and refuses before any event")
    func admissionCatchesIdentity() async throws {

        let sensing = FakeSensing()
        let sender  = FakeSender()
        let (seat, _) = try await Self.adopted(sensing: sensing, sender: sender)

        let turn = try await seat.acquire()
        let observation = try await observedReference(seat)

        // The window died and the id was handed to somebody else between the
        // observation and the send, which is the case a check taken a second
        // earlier cannot see.
        sensing.geometry = FakeGeometry.reference(
            frame    : FakeGeometry.adoptedWindow.frame,
            processID: 1
        )

        await #expect(throws: ObservationAdmissionRefusal.geometryChanged) {
            try await seat.send(Self.click, observation: observation, turn: turn)
        }
        #expect(sender.sent.isEmpty)
    }

    @Test("a target that became active refuses the command and waits")
    func preflightCatchesActivation() async throws {

        let sensing = FakeSensing()
        let sender  = FakeSender()
        let (seat, _) = try await Self.adopted(sensing: sensing, sender: sender)

        let turn = try await seat.acquire()
        let observation = try await observedReference(seat)
        sensing.targetIsActive = true

        await #expect(throws: SeatInterruption.self) {
            try await seat.send(Self.click, observation: observation, turn: turn)
        }
        #expect(sender.sent.isEmpty)
        #expect(seat.state == .waiting)
    }

    @Test("a dead fence refuses the command: no seat invariant survives it")
    func preflightCatchesTheFence() async throws {

        let sensing = FakeSensing()
        let sender  = FakeSender()
        let (seat, _) = try await Self.adopted(sensing: sensing, sender: sender)

        let turn = try await seat.acquire()
        let observation = try await observedReference(seat)
        sensing.fenceIsActive = false

        await #expect(throws: SeatInterruption.self) {
            try await seat.send(Self.click, observation: observation, turn: turn)
        }
        #expect(sender.sent.isEmpty)
        #expect(seat.state == .failed)
    }

    @Test("waiting leaves only when the person leaves the application, on a heartbeat")
    func waitingLeavesOnTheHeartbeat() async throws {

        let sensing = FakeSensing()
        let (seat, _) = try await Self.adopted(sensing: sensing)

        sensing.targetIsActive = true
        seat.report([.targetActivated])
        #expect(seat.state == .waiting)

        // Beats while the person is still in the application change nothing:
        // there is no timeout that gives up on them.
        for _ in 0..<5 {
            seat.heartbeat()
            #expect(seat.state == .waiting)
        }

        sensing.targetIsActive = false
        seat.heartbeat()
        #expect(seat.state == .ready)
    }

    @Test("a process that died while the seat waited is critical")
    func waitingOnADeadProcess() async throws {

        let sensing = FakeSensing()
        let (seat, _) = try await Self.adopted(sensing: sensing)

        sensing.targetIsActive = true
        seat.report([.targetActivated])

        sensing.targetIsActive = nil
        seat.heartbeat()

        #expect(seat.state == .failed)
    }

    // MARK: Release

    @Test("releasing a window puts it back at its original frame")
    func releaseReturnsTheWindow() async throws {

        let sensing = FakeSensing()
        let placing = FakePlacing()
        placing.onMove = { origin in
            sensing.geometry = FakeGeometry.userSeatWindow.replacingFrame(
                CGRect(origin: origin, size: FakeGeometry.windowSize)
            )
        }

        let (seat, window) = try await Self.adopted(sensing: sensing, placing: placing)
        let outcome = await seat.release(window, .returnToUserSeat)

        #expect(outcome == .returned)
        #expect(placing.moves.last == FakeGeometry.userSeatWindow.frame.origin)
        #expect(seat.adoptedWindows.isEmpty)
    }

    @Test("leaving a window on the virtual display writes nothing")
    func releaseLeavesTheWindow() async throws {

        let placing = FakePlacing()
        let (seat, window) = try await Self.adopted(placing: placing)

        let before  = placing.moves.count
        let outcome = await seat.release(window, .leaveOnVirtualDisplay)

        #expect(outcome == .leftOnVirtualDisplay)
        #expect(placing.moves.count == before)
    }

    @Test("releasing a window whose process is gone is reported, not an error")
    func releaseAVanishedWindow() async throws {

        let sensing = FakeSensing()
        let (seat, window) = try await Self.adopted(sensing: sensing)

        sensing.targetIsActive = nil
        let outcome = await seat.release(window)

        #expect(outcome == .vanished)
    }

    @Test("a reference the consumer assembled is not authority")
    func fabricatedReferenceIsRefused() async throws {

        let sender = FakeSender()
        let (seat, _) = try await Self.adopted(sender: sender)
        let other = makeSeat()
        let turn  = try await seat.acquire()

        // A well formed value issued by another seat. There is no public
        // initializer at all, so this is the closest a consumer can come to
        // building one, and it still matches nothing here.
        let foreign = SeatObservationReference(
            issuer                : other.observationIssuer.token,
            instance              : FakeGeometry.identity().process,
            surface               : FakeGeometry.identity(),
            selectionGeneration   : 1,
            geometryVersion       : GeometryObservationVersion(
                observerGeneration: 1,
                sequence          : 1
            ),
            observedFrame         : FakeGeometry.adoptedWindow.frame,
            role                  : .ordinaryTarget,
            barrier               : 1,
            contentAge            : .qualified(nanoseconds: 0),
            deliveredAtNanoseconds: 0
        )
        await #expect(throws: ObservationAdmissionRefusal.foreignReference) {
            try await seat.send(Self.click, observation: foreign, turn: turn)
        }
        #expect(sender.sent.isEmpty)
    }

    @Test("a driver refusal leaves no unconfirmed command behind: nothing was posted")
    func aRefusedSendLeavesNothingPending() async throws {

        let sender = FakeSender()
        sender.error = InputFailure.preparationFailed(step: .activation, code: -1)

        let (seat, _) = try await Self.adopted(sender: sender)
        let turn = try await seat.acquire()
        let observation = try await observedReference(seat)

        await #expect(throws: InputFailure.self) {
            try await seat.send(Self.click, observation: observation, turn: turn)
        }

        #expect(seat.unconfirmedCommandCount == 0)
        try seat.release(turn)
    }
}
