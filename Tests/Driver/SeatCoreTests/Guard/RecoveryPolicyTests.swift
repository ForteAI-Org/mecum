//
//  RecoveryPolicyTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

@testable import SeatCore
import Testing

/// The recovery budget, the precedence of critical over recoverable, and the
/// anti replay rule.
@Suite("Recovery policy")
struct RecoveryPolicyTests {

    static let recoverable: [SeatIssue] = [
        .targetActivated, .windowUnavailable, .geometryChanged, .snapshotChanged
    ]

    static let critical: [SeatIssue] = [
        .displayChanged, .fenceUnavailable, .processUnavailable, .identityChanged, .cursorInterference
    ]

    @Test("a recoverable issue before any input opens one episode", arguments: recoverable)
    func recoveryBeforeInput(_ issue: SeatIssue) throws {
        var policy = RecoveryPolicy()
        try policy.begin(issues: [issue], inputWasPosted: false, confirmation: .unknown)
        #expect(policy.attempts == 1)
    }

    @Test("a critical issue stops the seat without spending an episode", arguments: critical)
    func criticalStops(_ issue: SeatIssue) {
        var policy = RecoveryPolicy()
        #expect(throws: SeatInterruption.self) {
            try policy.begin(issues: [issue], inputWasPosted: false, confirmation: .unknown)
        }
        #expect(policy.attempts == 0)
        do {
            try policy.begin(issues: [issue], inputWasPosted: false, confirmation: .unknown)
            Issue.record("a critical issue was not stopped")
        } catch let interruption as SeatInterruption {
            #expect(interruption.isCritical)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("an observed effect allows recovery without duplicating anything")
    func observedEffectAllowsRecovery() throws {
        var policy = RecoveryPolicy()
        try policy.begin(issues: [.targetActivated], inputWasPosted: true, confirmation: .observed)
        #expect(policy.attempts == 1)
    }

    @Test("a verified absence allows recovery and a later resend")
    func absentEffectAllowsRecovery() throws {
        var policy = RecoveryPolicy()
        try policy.begin(issues: [.targetActivated], inputWasPosted: true, confirmation: .absent)
        #expect(policy.attempts == 1)
    }

    @Test("an uncertain effect never authorizes a replay")
    func uncertainEffectFails() {
        var policy = RecoveryPolicy()
        do {
            try policy.begin(issues: [.targetActivated], inputWasPosted: true, confirmation: .unknown)
            Issue.record("an uncertain input was replayed")
        } catch let interruption as SeatInterruption {
            #expect(interruption.issues == [.ambiguousEffect])
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("recoveries are bounded")
    func recoveriesAreBounded() throws {
        var policy = RecoveryPolicy()
        for _ in 0..<RecoveryPolicy.maximumEpisodes {
            try policy.begin(issues: [.geometryChanged], inputWasPosted: false, confirmation: .observed)
        }
        do {
            try policy.begin(issues: [.geometryChanged], inputWasPosted: false, confirmation: .observed)
            Issue.record("recoveries were unbounded")
        } catch let interruption as SeatInterruption {
            #expect(interruption.issues == [.recoveryExhausted])
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("a critical issue wins over a recoverable one in the same batch")
    func criticalWinsOverRecoverable() {
        var policy = RecoveryPolicy()
        do {
            try policy.begin(issues: [.targetActivated, .fenceUnavailable],
                inputWasPosted: false, confirmation: .observed)
            Issue.record("a critical issue was hidden by a recoverable one")
        } catch let interruption as SeatInterruption {
            #expect(interruption.isCritical)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

/// The critical and recoverable split, and the host, seat and window ownership
/// that section 5 of the spec derives the state transitions from.
@Suite("Seat issues")
struct SeatIssueTests {

    @Test("the recoverable issues are exactly the ones a seat can come back from")
    func recoverableSplit() {
        let recoverable = Set(SeatIssue.allCases.filter { !$0.isCritical })
        #expect(recoverable == [
            .targetActivated, .windowUnavailable, .geometryChanged,
            .snapshotChanged, .monitorUnavailable, .windowStashed,
            .preparationNotRestored
        ])
    }

    @Test("host issues take every seat down, seat issues do not")
    func issueOwnership() {
        #expect(SeatIssue.allCases.filter { $0.level == .host }
            == [.displayChanged, .fenceUnavailable, .monitorUnavailable])
        #expect(SeatIssue.allCases.filter { $0.level == .window } == [.windowStashed])
        #expect(SeatIssue.processUnavailable.level == .seat)
        #expect(SeatIssue.ambiguousEffect.level == .seat)
    }

    @Test("the monitor going away degrades the host instead of failing it")
    func monitorIsRecoverable() {
        #expect(!SeatIssue.monitorUnavailable.isCritical)
        #expect(SeatIssue.monitorUnavailable.level == .host)
    }
}
