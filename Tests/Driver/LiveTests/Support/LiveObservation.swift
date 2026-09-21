//
//  LiveObservation.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import Foundation
import SeatCore
import SeatSession

/// What a live row is told when the seat had no observation to give.
///
/// It carries the kit's own reason and adds nothing to it. A live suite that
/// stops here has found a capability this build does not have, which is a real
/// outcome of the run and not a defect of the row.
struct LiveObservationUnavailable: Error, CustomStringConvertible {

    let reason: ObservationUnavailable

    var description: String {
        "the seat refused to observe, so no Command can be addressed: \(reason)"
    }
}

/// Takes one observation through the production path and answers the reference
/// a Command is addressed by, or throws the reason there was none.
///
/// It is a thin wrapper over `AgentSeat.observe()` and deliberately nothing
/// more: it captures nothing of its own, qualifies nothing, and cannot build a
/// reference. On a build where the content clock or the window Still is not
/// qualified, every row using it stops with the capability named instead of
/// sending anything.
///
/// These suites are not run by the offline catalogue. Compiling them is a
/// migration of the callers and is not a live result: nothing here has been
/// executed, and no capability is attested by the fact that it builds.
@MainActor
func liveObservation(_ seat: AgentSeat) async throws -> SeatObservationReference {
    switch await seat.observe() {
        case .success(let delivery): return delivery.reference
        case .failure(let reason):   throw LiveObservationUnavailable(reason: reason)
    }
}
