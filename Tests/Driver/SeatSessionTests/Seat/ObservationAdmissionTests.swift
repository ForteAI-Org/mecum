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
/// that evidence here proves the algorithms and proves nothing about macOS: the
/// shipped adapters still report an incomplete enumeration, refuse the menu
/// surface and leave the content age unknown, and the last row of this suite is
/// the one that shows it.
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

    // MARK: What this build has not qualified

    @Test("the shipped adapters observe nothing, and say which evidence is missing")
    func theShippedCompositionRefusesWithTheGapNamed() async throws {

        // No controlled collaborator at all: the surface reader, the capture
        // source and the clock are the ones a real `SeatHost` would compose.
        let sensing = FakeSensing()
        let seat = AgentSeat(
            sensing              : sensing,
            placing              : FakePlacing(),
            sender               : FakeSender(),
            fence                : nil,
            displayID            : 7,
            expectedMainDisplayID: FakeGeometry.mainDisplayID,
            markers              : { 902 }
        )
        _ = try await seat.adopt(
            FakeGeometry.reference(frame: FakeGeometry.userSeatWindow.frame),
            platform: AppKitPlatform()
        )
        seat.refreshTargetReadings()

        switch await seat.observe() {
            case .success:
                Issue.record(
                    Comment(rawValue: "the shipped adapters qualified an observation. Nothing on this build "
                        + "supports that: the enumeration is incomplete and the content clock "
                        + "is unqualified.")
                )
            case .failure(let reason):
                // Either honest answer is the point: a gap that is named, never
                // an invented fact. Which one it is depends on the reading, and
                // neither of them is a qualification of anything.
                switch reason {
                    case .suspended, .capabilityUnqualified, .noSelectedTarget, .notAssigned:
                        break
                    default:
                        Issue.record(Comment(rawValue: "the shipped composition refused as \(reason), "
                            + "which does not name a missing piece of evidence"))
                }
        }
        #expect(!seat.coherentState.hasCurrentObservation)
    }
}
