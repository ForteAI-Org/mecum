//
//  SeatStateMachineTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import SeatCore
@testable import SeatSession
import Testing

/// The transition table of spec section 5, row by row. Every one of these is a
/// pure function call: the table is what is under
/// test, not the timing around it.
@Suite("Seat state machine")
struct SeatStateMachineTests {

    static let hostCritical: [SeatIssue] = [.displayChanged, .fenceUnavailable]

    static let seatCritical: [SeatIssue] = [
        .processUnavailable, .identityChanged, .cursorInterference,
        .ambiguousEffect, .recoveryExhausted,
    ]

    static let recoverable: [SeatIssue] = [.windowUnavailable, .geometryChanged, .snapshotChanged]

    @Test("a host issue fails the seat", arguments: hostCritical)
    func hostIssueFails(_ issue: SeatIssue) {
        #expect(SeatStateMachine.next(from: .ready, issues: [issue]) == .failed)
        #expect(issue.level == .host)
    }

    @Test("a critical seat issue fails the seat", arguments: seatCritical)
    func seatIssueFails(_ issue: SeatIssue) {
        #expect(SeatStateMachine.next(from: .ready, issues: [issue]) == .failed)
        #expect(issue.level == .seat)
    }

    @Test("a recoverable window issue recovers", arguments: recoverable)
    func recoverableRecovers(_ issue: SeatIssue) {
        #expect(SeatStateMachine.next(from: .ready, issues: [issue]) == .recovering)
    }

    @Test("the target becoming active waits, with no deadline anywhere in the type")
    func targetActivatedWaits() {
        #expect(SeatStateMachine.next(from: .ready, issues: [.targetActivated]) == .waiting)
        #expect(SeatStateMachine.next(from: .acting, issues: [.targetActivated]) == .waiting)
    }

    @Test("a missing preview degrades and keeps acting")
    func monitorDegrades() {
        #expect(SeatStateMachine.next(from: .ready, issues: [.monitorUnavailable]) == .degraded)
        #expect(SeatState.degraded.acceptsCommands)
    }

    @Test("a preparation the target refused to give back degrades")
    func unrestoredPreparationDegrades() {
        #expect(SeatStateMachine.next(from: .ready, issues: [.preparationNotRestored]) == .degraded)
        #expect(!SeatIssue.preparationNotRestored.isCritical)
        #expect(SeatIssue.preparationNotRestored.level == .seat)
    }

    @Test("a failed stage is a window issue and leaves the seat where it was")
    func windowStashedLeavesSeat() {
        #expect(SeatStateMachine.next(from: .ready, issues: [.windowStashed]) == .ready)
        #expect(SeatIssue.windowStashed.level == .window)
    }

    /// The load-bearing row: a batch arrives whole, and the recoverable half of
    /// it must never soften the critical half.
    @Test("a recoverable issue in the same batch as a critical one does not soften it")
    func criticalWinsInABatch() {
        #expect(SeatStateMachine.next(
            from  : .ready,
            issues: [.windowUnavailable, .targetActivated, .identityChanged]
        ) == .failed)
    }

    @Test("waiting wins over recovering, because the person is in the application")
    func waitingWinsOverRecovering() {
        #expect(SeatStateMachine.next(
            from  : .ready,
            issues: [.geometryChanged, .targetActivated]
        ) == .waiting)
    }

    @Test("failed is terminal: no issue and no absence of issues brings it back")
    func failedIsTerminal() {
        #expect(SeatStateMachine.next(from: .failed, issues: []) == .failed)
        #expect(SeatStateMachine.next(from: .failed, issues: [.targetActivated]) == .failed)
        #expect(SeatStateMachine.resolved(from: .failed, wasDegraded: false) == .failed)
    }

    @Test("an empty batch changes nothing", arguments: SeatState.allCases)
    func emptyBatchIsQuiet(_ state: SeatState) {
        #expect(SeatStateMachine.next(from: state, issues: []) == state)
    }

    @Test("a resolved recovery returns to ready, or stays degraded if something is still missing")
    func resolvedReturns() {
        #expect(SeatStateMachine.resolved(from: .recovering, wasDegraded: false) == .ready)
        #expect(SeatStateMachine.resolved(from: .recovering, wasDegraded: true) == .degraded)
    }

    @Test("only ready and degraded accept commands")
    func commandsAreRefusedEverywhereElse() {
        let accepting = SeatState.allCases.filter(\.acceptsCommands)
        #expect(Set(accepting) == Set([.ready, .degraded]))
    }
}
