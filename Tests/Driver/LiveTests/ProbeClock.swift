//
//  ProbeClock.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import Dispatch
import Foundation

/// ProbeClock is the monotonic source every interval and deadline of this probe
/// is read from. Injected so the deadline and the sample cap are exercised
/// offline in a test that takes no real time, and monotonic so a change of the
/// wall clock during a run cannot extend or cut a phase.
@MainActor
protocol ProbeClock {

    var nowNanoseconds: UInt64 { get }
}

/// MonotonicProbeClock is the machine's uptime clock, which does not go
/// backwards and does not follow the wall clock.
@MainActor
struct MonotonicProbeClock: ProbeClock {

    var nowNanoseconds: UInt64 { DispatchTime.now().uptimeNanoseconds }
}
