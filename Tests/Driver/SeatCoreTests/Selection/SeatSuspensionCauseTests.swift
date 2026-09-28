//
//  SeatSuspensionCauseTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

@testable import SeatCore
import Testing

/// The consumer's projection of a suspension: a containment block reaches a
/// person, and an agent, as a clause they can act on, never as a Swift case.
@Suite("A suspension as a consumer reads it")
struct SeatSuspensionCauseTests {

    @Test("a window left open outside the seat reads as what it is and what clears it")
    func aContainmentBlockReadsAsAClause() {
        let cause = SeatSuspensionCause(.containmentNotVerified(blocks: [
            .surfaceOutsideSeat(windowNumber: 38030),
            .effectRefused(
                windowNumber: 38030,
                refusal     : .adapterNotQualified(reason: UnqualifiedSurfaceEffector.defaultReason)
            ),
            .surfaceDeadlineExpired(
                windowNumber      : 38030,
                elapsedNanoseconds: 1_102_585_208
            ),
        ]))
        #expect(cause == .containmentNotVerified(blocks: [
            "window 38030 of the application is open on the person's screen, outside the seat, "
                + "and closing it there clears this",
            "window 38030 could not be moved into the seat: no way to move it is qualified on this build",
            "window 38030 was not contained within 1.1 s",
        ]))
    }
}
