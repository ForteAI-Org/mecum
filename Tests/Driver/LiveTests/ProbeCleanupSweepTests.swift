//
//  ProbeCleanupSweepTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import Foundation
import Testing

/// The cleanup verdict of the window inventory probe, offline, through the very
/// code the AppKit fixture uses to produce it.
///
/// No window is created and nothing is closed here: the observations the fixture
/// can make about its own objects are handed in, and what is checked is the only
/// decision that follows from them. A close that was requested is not a surface
/// that went away, and this suite exists so that distinction cannot be lost in a
/// path a unit run never reaches.
@MainActor
struct ProbeCleanupSweepTests {

    static func token(_ order: Int, role: FixtureWindowRole = .phased) -> FixtureWindowToken {
        FixtureWindowToken(identifier: UUID(), role: role, creationOrder: order)
    }

    @Test("a close that was only requested is an unverified residue, never a verified cleanup")
    func aRequestedCloseIsNotAVerifiedRelease() {
        let first  = Self.token(1, role: .neverPresented)
        let second = Self.token(2)

        var sweep = ProbeCleanupSweep()
        sweep.record(.closeRequested(visibleLocally: false, deadlinePassedAfterwards: false),
                     for: first)
        sweep.record(.closeRequested(visibleLocally: false, deadlinePassedAfterwards: false),
                     for: second)
        let record = sweep.result()

        #expect(record.status == .unknownIncomplete,
                "local invisibility after close is not a disappearance from the window server")
        #expect(record.residualTokens == [first, second])
        #expect(record.releasedTokenCount == 2)
        #expect(record.notes.contains { $0.contains("stays unknown") })
        #expect(record.notes.contains { $0.contains("not of surfaces verified") })
    }

    @Test("a window still reporting itself visible makes the cleanup a failure")
    func aVisibleWindowIsAFailure() {
        var sweep = ProbeCleanupSweep()
        sweep.record(.closeRequested(visibleLocally: false, deadlinePassedAfterwards: false),
                     for: Self.token(1))
        sweep.record(.closeRequested(visibleLocally: true, deadlinePassedAfterwards: false),
                     for: Self.token(2))
        let record = sweep.result()

        #expect(record.status == .failed)
        #expect(record.residualTokens.count == 2)
        #expect(record.notes.contains { $0.contains("still reports itself visible") })
    }

    @Test("a cleanup stopped by its deadline is incomplete and says where it stopped")
    func theCleanupDeadlineLeavesAnIncompleteRecord() {
        let untouched   = Self.token(1)
        let interrupted = Self.token(2)
        let crossed     = Self.token(3)

        var sweep = ProbeCleanupSweep()
        sweep.record(.notAttemptedBeforeDeadline, for: untouched)
        sweep.record(.interruptedByDeadline, for: interrupted)
        sweep.record(.closeRequested(visibleLocally: false, deadlinePassedAfterwards: true),
                     for: crossed)
        let record = sweep.result()

        #expect(record.status == .unknownIncomplete)
        #expect(record.residualTokens == [untouched, interrupted, crossed])
        #expect(record.releasedTokenCount == 1, "only one release was actually requested")
        #expect(record.notes.contains { $0.contains("nothing was requested for it") })
        #expect(record.notes.contains { $0.contains("its close was requested") })
        #expect(record.notes.contains { $0.contains("passed while window 3") })
    }

    @Test("a sweep with nothing registered is the only verified cleanup there is")
    func anEmptySweepIsTheOnlyVerifiedOne() {
        let record = ProbeCleanupSweep().result()

        #expect(record.status == .verified)
        #expect(record.residualTokens.isEmpty)
        #expect(record.releasedTokenCount == 0)
        #expect(record.notes.contains { $0.contains("nothing to release") })
    }

    @Test("the errors of the run survive the cleanup record whatever it says")
    func priorErrorsAreNeverMaskedByTheCleanup() {
        var sweep = ProbeCleanupSweep()
        sweep.record(.closeRequested(visibleLocally: true, deadlinePassedAfterwards: false),
                     for: Self.token(1))
        let record = sweep.result().preserving(priorErrors: ["the minimize phase failed"])

        #expect(record.status == .failed, "a cleanup problem must not rewrite itself as unknown")
        #expect(record.priorErrors == ["the minimize phase failed"])
        #expect(record.residualTokens.count == 1)
    }
}
