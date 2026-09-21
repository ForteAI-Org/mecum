//
//  ObservationHarness.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import Foundation
import SeatCapture
import SeatCore
@testable import SeatSession

/// A clock oracle that answers a qualified age, for exercising the paths the
/// shipped `UnqualifiedContentClock` refuses.
///
/// Qualifying a clock here is a statement about this test and about nothing else:
/// no traced oracle relates ScreenCaptureKit's sample clock to
/// `mach_absolute_time` on this build, and the shipped path still answers unknown
/// and still refuses every Command that carries such an observation.
final class ControlledContentClock: ContentClockQualifying, @unchecked Sendable {

    var isQualified = true

    /// The age every sample is reported at.
    var ageNanoseconds: UInt64 = 0

    /// A doubt to answer instead of an age, for the unknown paths.
    var doubt: ContentAgeDoubt?

    func contentAge(of frame: SeatFrame, atNanoseconds now: UInt64) -> FrameContentAge {
        if let doubt { return .unknown(doubt) }
        guard isQualified else { return .unknown(.clockNotQualified) }
        return .qualified(nanoseconds: ageNanoseconds)
    }
}

/// The failure a test helper throws when the seat had no observation to give, so
/// an assertion reads the reason instead of a missing optional.
struct ObservationWasUnavailable: Error, CustomStringConvertible {

    let reason: ObservationUnavailable

    var description: String { "the seat had no observation: \(reason)" }
}

/// Takes one observation through the production path, or throws the reason there
/// was none.
///
/// The extra reading is the second agreeing one a surface needs before it is
/// verified: the seat folds where it already takes readings, and a suite that
/// adopts and observes in the same turn would otherwise be asking about a surface
/// that has been seen exactly once.
@MainActor
@discardableResult
func observe(_ seat: AgentSeat) async throws -> SeatObservationDelivery {

    seat.refreshTargetReadings()
    switch await seat.observe() {
        case .success(let delivery): return delivery
        case .failure(let reason):   throw ObservationWasUnavailable(reason: reason)
    }
}

/// The Observation Reference of one fresh observation, which is what a Command
/// is addressed by.
@MainActor
func observedReference(_ seat: AgentSeat) async throws -> SeatObservationReference {
    try await observe(seat).reference
}
