//
//  ObservationAdmissionTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import CoreGraphics
import Foundation
import SeatCapture
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

/// The observation and admission half of the seat, exercised on the production
/// path: the assignment nucleus, the selection nucleus, the qualifier, the
/// issuer and the admission, composed exactly as `SeatHost` composes them.
///
/// ## What the controlled collaborators are, and what they are not
///
/// They supply **evidence**, never verdicts: a real `SeatFrame` with a real
/// surface, a surface enumeration that says it is complete, and a clock oracle
/// that answers an age. Every decision below is the production code's. Supplying
/// that evidence here proves the algorithms and proves nothing about macOS. The
/// last row composes no production capture source or clock and shows that those
/// missing capabilities still refuse without inventing evidence.
///
/// Nothing here qualifies a native capability, a clock, a pixel or a menu. No
/// live run, no Host run and no benchmark was performed for any of it.
@MainActor
@Suite("Observation and admission")
struct ObservationAdmissionTests {

    static let click = InputCommand.click(InputLocation(
        screenPoint       : CGPoint(x: 2700, y: 700),
        windowPointFromTop: CGPoint(x: 100, y: 100)
    ))

    /// A second window close enough to the first that its offset frame is still
    /// inside the virtual display: containment is a real check here, and a
    /// window parked far away would fail it for a reason no row is about.
    static let secondWindowNumber = 779

    static func reference(_ windowNumber: Int) -> WindowReference {
        let offset = CGFloat(windowNumber - FakeGeometry.windowNumber) * 60
        return FakeGeometry.reference(
            frame       : FakeGeometry.adoptedWindow.frame.offsetBy(dx: offset, dy: offset),
            windowNumber: windowNumber
        )
    }

    /// A composed seat with one window adopted, and the collaborators a row
    /// reaches into.
    static func composed(
        sensing: FakeSensing = FakeSensing(),
        sender : FakeSender  = FakeSender(),
        source : ControlledObservationSource? = nil,
        clock  : ControlledContentClock? = nil,
        profile: ObservationProfile = .initialLab,
        marker : Int64 = 900
    ) async throws -> (
        seat  : AgentSeat,
        window: AdoptedWindow,
        source: ControlledObservationSource,
        clock : ControlledContentClock,
        sender: FakeSender
    ) {
        let builtSource = source ?? ControlledObservationSource(sensing: sensing)
        let builtClock  = clock  ?? ControlledContentClock()
        let seat = makeSeat(
            sensing: sensing,
            sender : sender,
            marker : marker,
            source : builtSource,
            clock  : builtClock,
            profile: profile
        )
        let window = try await seat.adopt(
            FakeGeometry.reference(frame: FakeGeometry.userSeatWindow.frame),
            platform: AppKitPlatform()
        )
        return (seat, window, builtSource, builtClock, sender)
    }

    // MARK: The reference the kit issues

    @Test("an observation binds identity, selection, geometry and a measured age")
    func aDeliveryBindsItsSituation() async throws {

        let context = try await Self.composed()
        context.clock.ageNanoseconds = 1_000

        let delivery = try await observe(context.seat)
        let identity = try #require(context.window.reference.identity)

        #expect(delivery.reference.recipient == identity)
        #expect(delivery.reference.role == .ordinaryTarget)
        #expect(delivery.reference.geometryVersion == delivery.geometry.version)
        #expect(delivery.contentAge == .qualified(nanoseconds: 1_000))
        #expect(delivery.frame.source == .window(identity))
        #expect(context.seat.coherentState.hasCurrentObservation)
    }

    @Test("an observation completes the second reading of a newly discovered surface")
    func observationCompletesNewSurfaceVerification() async throws {

        let sensing = FakeSensing()
        let context = try await Self.composed(
            sensing: sensing,
            profile: try Self.loadedSuiteObservationProfile()
        )
        let auxiliary = Self.reference(Self.secondWindowNumber)
        sensing.additionalWindows[auxiliary.windowNumber] = auxiliary

        switch await context.seat.observe() {
            case .success:
                break
            case .failure(.suspended(let causes)):
                Issue.record(Comment(rawValue: "the observation refused a surface that needed only its "
                    + "second agreeing reading: \(causes)"))
            case .failure(let reason):
                // Capture evidence is outside this regression. Reaching the
                // source proves readiness admitted the request.
                #expect(reason != .noSelectedTarget)
        }
        #expect(!context.source.requested.isEmpty,
                "readiness must settle before a Still is requested")
    }

    @Test("an observation rereads one transient incomplete inventory")
    func observationRereadsTransientIncompleteInventory() async throws {

        let sensing = FakeSensing()
        let reader  = ControlledSurfaceReader(sensing: sensing)
        reader.completenessReadings = [
            .complete(provenance: .qualifiedSurfaceEnumeration),
            .incomplete(reason: "the first AX pass was incomplete"),
            .complete(provenance: .qualifiedSurfaceEnumeration)
        ]
        let source = ControlledObservationSource(sensing: sensing)
        let seat = makeSeat(
            sensing: sensing,
            reader : reader,
            source : source,
            clock  : ControlledContentClock(),
            profile: try Self.loadedSuiteObservationProfile()
        )
        _ = try await seat.adopt(
            FakeGeometry.reference(frame: FakeGeometry.userSeatWindow.frame),
            platform: AppKitPlatform()
        )

        switch await seat.observe() {
            case .success:
                break
            case .failure(.suspended(let causes)):
                Issue.record(Comment(rawValue: "the restored inventory remained suspended: \(causes)"))
            case .failure(let reason):
                #expect(reason != .noSelectedTarget)
        }
        #expect(!source.requested.isEmpty,
                "the second complete inventory must admit the Still request")
    }

    /// Keeps these readiness regressions deterministic when the complete test
    /// product runs many MainActor suites concurrently. Production continues to
    /// use the five second `initialLab` capture budget.
    private static func loadedSuiteObservationProfile() throws -> ObservationProfile {
        try ObservationProfile.configured(
            frameAgeLimitNanoseconds  : 120_000_000_000,
            captureDeadlineNanoseconds:  60_000_000_000,
            captureAttempts           : 2,
            menuInteractionNanoseconds: 180_000_000_000,
            menuCleanupNanoseconds    :   2_000_000_000
        )
    }

    @Test("a complete Command consumes its observation, so the next one needs a new one")
    func aBarrierFollowsEveryCommand() async throws {

        let context = try await Self.composed()
        let turn = try await context.seat.acquire()

        let observation = try await observedReference(context.seat)
        let receipt = try await context.seat.send(
            Self.click,
            observation: observation,
            turn       : turn
        )
        #expect(!context.seat.coherentState.hasCurrentObservation)
        #expect(context.seat.coherentState.lastInvalidation == .commandCompleted)

        await #expect(throws: ObservationAdmissionRefusal.noCurrentObservation(.commandCompleted)) {
            try await context.seat.send(Self.click, observation: observation, turn: turn)
        }
        #expect(context.sender.sent.count == 1, "the refused Command posted nothing")

        try context.seat.confirm(receipt, .observed)
        try context.seat.release(turn)
    }

    @Test("the barrier travels into the capture request, so a post Command Still is its own")
    func theBarrierReachesTheCaptureRequest() async throws {

        let context = try await Self.composed()
        let turn = try await context.seat.acquire()

        let receipt = try await context.seat.send(
            Self.click,
            observation: try await observedReference(context.seat),
            turn       : turn
        )
        _ = try await observedReference(context.seat)

        #expect(context.source.barriers.count == 2)
        #expect(context.source.barriers[0] != context.source.barriers[1],
                "a request made after a Command must not share the earlier request's key")

        try context.seat.confirm(receipt, .unknown)
        try context.seat.release(turn)
    }

    @Test("a return from A to B to A does not revive the first A's observation")
    func aReturnDoesNotReviveTheOldObservation() async throws {

        let sensing = FakeSensing()
        let context = try await Self.composed(sensing: sensing)
        let second  = Self.reference(Self.secondWindowNumber)
        sensing.additionalWindows[second.windowNumber] = second
        let other = try await context.seat.adopt(second, platform: AppKitPlatform())

        let first = try await context.seat.switchTarget(to: context.window)
        let turn  = try await context.seat.acquire()
        let onFirstA = try await observedReference(context.seat)

        _ = try await context.seat.switchTarget(to: other)
        _ = try await context.seat.switchTarget(to: first)

        await #expect(throws: ObservationAdmissionRefusal.noCurrentObservation(.targetChanged)) {
            try await context.seat.send(Self.click, observation: onFirstA, turn: turn)
        }
        // And the same window observed again is a different reference, under a
        // later selection generation.
        let onSecondA = try await observedReference(context.seat)
        #expect(onSecondA != onFirstA)
        #expect(onSecondA.selectionGeneration > onFirstA.selectionGeneration)
        #expect(context.sender.sent.isEmpty)
        try context.seat.release(turn)
    }

    // MARK: The age of the content

    @Test("an age nothing could measure refuses the Command, with the doubt named")
    func anUnknownAgeRefusesInput() async throws {

        let context = try await Self.composed()
        context.clock.doubt = .clockNotQualified

        switch await context.seat.observe() {
            case .success:
                Issue.record("a sample with no measurable age was qualified")
            case .failure(let reason):
                #expect(reason == .evidenceInsufficient(.absent(.contentClockNotQualified)))
        }
        #expect(!context.seat.coherentState.hasCurrentObservation)
    }

    @Test("content older than the configured finite limit refuses the Command")
    func anExpiredAgeRefusesInput() async throws {

        let tight = try ObservationProfile.configured(
            frameAgeLimitNanoseconds  : 1_000,
            captureDeadlineNanoseconds: 5_000_000_000,
            captureAttempts           : 2,
            menuInteractionNanoseconds: 180_000_000_000,
            menuCleanupNanoseconds    : 2_000_000_000
        )
        let context = try await Self.composed(profile: tight)
        context.clock.ageNanoseconds = 2_000

        let turn = try await context.seat.acquire()
        let observation = try await observedReference(context.seat)

        do {
            _ = try await context.seat.send(Self.click, observation: observation, turn: turn)
            Issue.record("a Frame past the configured limit was admitted")
        } catch let refusal as ObservationAdmissionRefusal {
            guard case .frameTooOld(_, let limit) = refusal else {
                Issue.record("the refusal was \(refusal) and not the age limit")
                try context.seat.release(turn)
                return
            }
            #expect(limit == 1_000)
        }
        #expect(context.sender.sent.isEmpty)
        try context.seat.release(turn)
    }

    // MARK: Evidence that is absent, and evidence that contradicts itself

    @Test("a sample of another window is invalid evidence and issues nothing")
    func aSampleOfAnotherWindowIsRefused() async throws {

        let context = try await Self.composed()
        let second  = Self.reference(Self.secondWindowNumber)
        context.source.answersWrongIdentity = second.identity

        switch await context.seat.observe() {
            case .success:
                Issue.record("a Frame of another window was accepted for this one")
            case .failure(let reason):
                #expect(reason == .evidenceInsufficient(.invalid(.identityMismatch)))
        }
    }

    @Test("geometry a coordinate transform is undefined on is invalid evidence")
    func malformedGeometryIsRefused() async throws {

        let context = try await Self.composed()
        context.source.answersMalformedGeometry = true

        switch await context.seat.observe() {
            case .success:
                Issue.record("a Frame whose geometry cannot carry a coordinate was accepted")
            case .failure(let reason):
                #expect(reason == .evidenceInsufficient(.invalid(.geometryMalformed)))
        }
    }

    @Test("an ability without evidence is refused before any capture is attempted")
    func anUnqualifiedCapabilityRefusesBeforeAnyEffect() async throws {

        let context = try await Self.composed()
        context.source.supported.remove(.windowStill)

        switch await context.seat.observe() {
            case .success:
                Issue.record("an unqualified capability produced an observation")
            case .failure(let reason):
                #expect(reason == .capabilityUnqualified(.windowStill))
        }
        #expect(context.source.requested.isEmpty, "nothing was asked of the capture path")
    }

    // MARK: The capture budget

    @Test("attempts are finite and share one deadline, and a spent budget is explicit")
    func theCaptureBudgetIsFinite() async throws {

        let context = try await Self.composed()
        context.source.failuresBeforeSuccess = 1

        _ = try await observe(context.seat)
        #expect(context.source.requested.count == 2, "the second attempt is inside the same request")

        // Spending both attempts ends the request instead of trying again.
        let exhausted = try await Self.composed(marker: 901)
        exhausted.source.failuresBeforeSuccess = 5
        switch await exhausted.seat.observe() {
            case .success:
                Issue.record("a request that never captured produced an observation")
            case .failure(let reason):
                #expect(reason == .captureFailed(reason: "controlled attempt refused"))
        }
        #expect(exhausted.source.requested.count == 2, "the attempts were not renewed")
    }

    @Test("a capture that returns after the target moved is dropped, not issued")
    func aLateCaptureHasNoAuthority() async throws {

        let sensing = FakeSensing()
        let context = try await Self.composed(sensing: sensing)
        let second  = Self.reference(Self.secondWindowNumber)
        sensing.additionalWindows[second.windowNumber] = second
        let other = try await context.seat.adopt(second, platform: AppKitPlatform())
        _ = try await context.seat.switchTarget(to: context.window)

        context.seat.refreshTargetReadings()
        context.source.duringCapture = { [seat = context.seat] in
            _ = try? await seat.switchTarget(to: other)
        }

        switch await context.seat.observe() {
            case .success:
                Issue.record("a capture of the previous selection became the current observation")
            case .failure(let reason):
                guard case .suspended(let causes) = reason else {
                    Issue.record("the late capture was refused as \(reason)")
                    return
                }
                let superseded = causes.contains { cause in
                    guard case .observationSuperseded = cause else { return false }
                    return true
                }
                #expect(superseded)
        }
        #expect(!context.seat.coherentState.hasCurrentObservation)
    }

    // MARK: The Monitor, which is a different question

    @Test("an isolated Monitor fault costs the preview and leaves valid input working")
    func anIsolatedMonitorFaultDoesNotCloseTheGate() async throws {

        let context = try await Self.composed()
        context.seat.reportMonitorHealth(.isolatedFault(lastImageIsStale: true))

        #expect(context.seat.coherentState.monitor == .isolatedFault(lastImageIsStale: true))
        #expect(!context.seat.coherentState.suspensions.contains(.monitorSharedFault))

        let turn = try await context.seat.acquire()
        let receipt = try await context.seat.send(
            Self.click,
            observation: try await observedReference(context.seat),
            turn       : turn
        )
        try context.seat.confirm(receipt, .observed)
        try context.seat.release(turn)
    }

    @Test("a shared Monitor fault closes the gate and invalidates the observation")
    func aSharedMonitorFaultClosesTheGate() async throws {

        let context = try await Self.composed()
        let turn = try await context.seat.acquire()
        let observation = try await observedReference(context.seat)

        context.seat.reportMonitorHealth(.sharedFault)
        #expect(context.seat.coherentState.suspensions.contains(.monitorSharedFault))
        #expect(context.seat.coherentState.operationalTarget == nil)

        await #expect(throws: (any Error).self) {
            try await context.seat.send(Self.click, observation: observation, turn: turn)
        }
        #expect(context.sender.sent.isEmpty)

        switch await context.seat.observe() {
            case .success:
                Issue.record("a shared fault still produced an observation")
            case .failure(let reason):
                #expect(reason == .suspended([.monitorSharedFault]))
        }
        try context.seat.release(turn)
    }

    // MARK: The coherent state

    @Test("state updates are versioned inside one lifecycle and end on an explicit cancel")
    func stateUpdatesAreVersionedAndCancellable() async throws {

        let context = try await Self.composed()
        let subscription = context.seat.subscribeToState()
        let first = subscription.current

        let collected = Holder<[SeatCoherentState]>([])
        let reader = Task { @MainActor in
            for await state in subscription.updates { collected.value.append(state) }
        }
        defer { reader.cancel() }

        _ = try await observedReference(context.seat)
        for _ in 0 ..< 20 { await Task.yield() }

        let latest = try #require(collected.value.last)
        #expect(latest.revision > first.revision)
        #expect(latest.lifecycle == first.lifecycle)
        #expect(latest.hasCurrentObservation)
        #expect(collected.value.map(\.revision) == collected.value.map(\.revision).sorted())

        subscription.cancel()
        for _ in 0 ..< 20 { await Task.yield() }
        let afterCancel = collected.value.count
        _ = try await observedReference(context.seat)
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(collected.value.count == afterCancel, "a cancelled subscription is not fed")
    }

    @Test("giving every window back revokes input authority and ends the observation")
    func stoppingRevokesTheObservation() async throws {

        let context = try await Self.composed()
        _ = try await observedReference(context.seat)

        _ = await context.seat.releaseAllWindows(.returnToUserSeat)

        #expect(!context.seat.coherentState.hasCurrentObservation)
        #expect(context.seat.coherentState.instance == nil)
        switch await context.seat.observe() {
            case .success: Issue.record("a released seat still observed")
            case .failure: break
        }
    }

    // MARK: The budgets, and the text the consumer orchestrates

    @Test("a budget that is not finite and positive is refused instead of defaulted")
    func aNonPositiveBudgetIsRefused() {

        #expect(throws: ObservationProfileRefusal.frameAgeLimitNotPositive) {
            _ = try ObservationProfile.configured(
                frameAgeLimitNanoseconds  : 0,
                captureDeadlineNanoseconds: 5_000_000_000,
                captureAttempts           : 2,
                menuInteractionNanoseconds: 180_000_000_000,
                menuCleanupNanoseconds    : 2_000_000_000
            )
        }
        #expect(throws: ObservationProfileRefusal.captureAttemptsNotPositive) {
            _ = try ObservationProfile.configured(
                frameAgeLimitNanoseconds  : 120_000_000_000,
                captureDeadlineNanoseconds: 5_000_000_000,
                captureAttempts           : 0,
                menuInteractionNanoseconds: 180_000_000_000,
                menuCleanupNanoseconds    : 2_000_000_000
            )
        }
        #expect(ObservationProfile.initialLab.frameAgeLimitNanoseconds == 120_000_000_000)
        #expect(ObservationProfile.initialLab.captureDeadlineNanoseconds == 5_000_000_000)
        #expect(ObservationProfile.initialLab.captureAttempts == 2)
        #expect(ObservationProfile.initialLab.menuInteractionNanoseconds == 180_000_000_000)
        #expect(ObservationProfile.initialLab.menuCleanupNanoseconds == 2_000_000_000)
    }

    @Test("cutting a string into Commands posts nothing and grants no authority")
    func textCommandsAreADecisionAndNotASend() async throws {

        let context = try await Self.composed()
        let commands = try AgentSeat.textCommands(of: "ciao")

        #expect(commands == [.insertText("ciao")])
        #expect(context.sender.sent.isEmpty, "cutting a string is not a send")
    }

    // MARK: The operating target and the application's own transitions

    @Test("the application's own move to another window takes the seat's target with it")
    func applicationTransitionMovesTheOperatingTarget() async throws {

        let sensing = FakeSensing()
        let reader  = ControlledSurfaceReader(sensing: sensing)
        let seat    = makeSeat(sensing: sensing, marker: 903, reader: reader)
        let first   = try await seat.adopt(
            FakeGeometry.reference(frame: FakeGeometry.userSeatWindow.frame),
            platform: AppKitPlatform()
        )
        let reference = Self.reference(Self.secondWindowNumber)
        sensing.additionalWindows[reference.windowNumber] = reference
        let second   = try await seat.adopt(reference, platform: AppKitPlatform())
        let identity = try #require(first.reference.identity)

        // A fold with no transition in it leaves the seat's own choice alone.
        // This is the one that used to walk the target back onto the window the
        // consumer had just moved away from.
        seat.refreshTargetReadings()
        #expect(seat.currentTarget?.id == second.id)

        // The application brings its other window forward on its own, which is
        // what a dialog opening and closing looks like from outside.
        reader.recency = [RecencyClaim(
            surface              : identity,
            signal               : .returnedToFront,
            provenance           : .qualifiedFrontOrderAttestation,
            origin               : .application(provenance: .qualifiedRaiseAttribution),
            observedAtNanoseconds: DispatchTime.now().uptimeNanoseconds
        )]
        seat.refreshTargetReadings()

        #expect(seat.currentTarget?.id == first.id)
        #expect(seat.seatGuard?.target.hasSameIdentity(as: first.reference) == true)
        #expect(!seat.coherentState.hasCurrentObservation,
                "a target the seat followed invalidates the observation of the previous one")

        // The same claim read again is the same transition, not a new one.
        reader.recency = []
        _ = try await seat.switchTarget(to: second)
        seat.refreshTargetReadings()
        #expect(seat.currentTarget?.id == second.id)
    }

    @Test("a window the application stopped scoping stops blocking the seat")
    func aWithdrawnSurfaceStopsBlockingTheSeat() async throws {

        let sensing = FakeSensing()
        let reader  = ControlledSurfaceReader(sensing: sensing)
        let seat    = makeSeat(sensing: sensing, marker: 904, reader: reader)
        let first   = try await seat.adopt(
            FakeGeometry.reference(frame: FakeGeometry.userSeatWindow.frame),
            platform: AppKitPlatform()
        )
        let reference = Self.reference(Self.secondWindowNumber)
        sensing.additionalWindows[reference.windowNumber] = reference
        let dialog = try await seat.adopt(reference, platform: AppKitPlatform())

        // The application closes the dialog: it stops listing it, while the
        // window server keeps a visible surface for it. It is the seat's target,
        // and reading it is what used to suspend the seat for good.
        reader.windowNumbers = [first.id]
        seat.refreshTargetReadings()
        #expect(seat.selectionKit.operability().isOperational == false,
                "an absence on its own proves nothing and still blocks")

        reader.withdrawn = [try #require(dialog.reference.identity)]
        seat.refreshTargetReadings()

        #expect(seat.selectionKit.selected?.surface.windowNumber == first.id,
                "the selection goes back to the window that is still there")
        #expect(seat.currentTarget?.id == first.id)
    }

    // MARK: What this build has not qualified

    @Test("the direct default composition observes nothing and names the missing evidence")
    func directDefaultCompositionRefusesWithTheGapNamed() async throws {

        // No controlled collaborator at all. This is the direct initializer's
        // fail-closed default, not the qualified composition made by SeatHost.
        let sensing = FakeSensing()
        let seat = AgentSeat(
            sensing              : sensing,
            placing              : FakePlacing(),
            sender               : FakeSender(),
            fence                : nil,
            displayID            : 7,
            expectedMainDisplayID: FakeGeometry.mainDisplayID,
            markers              : { 902 },
            observationProfile   : try Self.loadedSuiteObservationProfile()
        )
        _ = try await seat.adopt(
            FakeGeometry.reference(frame: FakeGeometry.userSeatWindow.frame),
            platform: AppKitPlatform()
        )
        seat.refreshTargetReadings()

        switch await seat.observe() {
            case .success:
                Issue.record(
                    Comment(rawValue: "the direct composition qualified an observation even though its "
                        + "capture source and content clock are unqualified.")
                )
            case .failure(let reason):
                // Either honest answer is the point: a gap that is named, never
                // an invented fact. Which one it is depends on the reading, and
                // neither of them is a qualification of anything.
                switch reason {
                    case .suspended, .capabilityUnqualified, .noSelectedTarget, .notAssigned:
                        break
                    default:
                        Issue.record(Comment(rawValue: "the direct default composition refused as \(reason), "
                            + "which does not name a missing piece of evidence"))
                }
        }
        #expect(!seat.coherentState.hasCurrentObservation)
    }
}
