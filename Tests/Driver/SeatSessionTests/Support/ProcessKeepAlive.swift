//
//  ProcessKeepAlive.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/09/2026.
//

import Foundation

/// One main-queue block that always reschedules itself, so a tier that is only
/// waiting still has something the drain loop waits for.
///
/// An `async` main drains the **main dispatch queue** and ends the program when
/// that queue has nothing left. Serialized, this bundle has exactly one test
/// running at a time, and a row that does nothing but wait out a recovery
/// budget was enough: `destroyedTargetWithNoPredecessor` started, the process
/// called `exit(0)`, and the bundle's summary went with it, exit status zero
/// and no failure reported. The tier's own bundle count is what caught it.
///
/// This is the remedy `AppKitPump` already uses in the Host tier and the one
/// ADR 0008 leaves to the test tier: "a task that keeps waking up while it
/// waits on anything else". It has to be `asyncAfter` and not `Task.sleep`, for
/// the reason `EventLoopWait.sleep` documents: a sleeping task lives on the
/// concurrency runtime's own timer, which the drain loop does not count, while
/// a timer source on the main queue is exactly what it waits for.
@MainActor
enum ProcessKeepAlive {

    private static var hasStarted = false

    /// Started before the first fake Seat can pump adoption or capture, and
    /// by recovery waits that may run without constructing a Seat.
    static func start() {
        guard !hasStarted else { return }
        hasStarted = true
        tick()
    }

    private static func tick() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { tick() }
    }
}
