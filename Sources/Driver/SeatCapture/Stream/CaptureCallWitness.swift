//
//  CaptureCallWitness.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import Foundation

/// CaptureCallWitness distinguishes a coordinator refusal from an Apple call
/// whose callback is still pending. Only the latter owns a framework slot and
/// requires late-result cleanup.
nonisolated final class CaptureCallWitness: @unchecked Sendable {

    private let lock = NSLock()
    private var started = false
    private var completed = false
    private var succeeded = false

    var snapshot: (started: Bool, completed: Bool, succeeded: Bool) {
        lock.lock()
        let value = (started, completed, succeeded)
        lock.unlock()
        return value
    }

    func markStarted() {
        lock.lock()
        started = true
        lock.unlock()
    }

    func markCompleted(succeeded: Bool) {
        lock.lock()
        completed = true
        self.succeeded = succeeded
        lock.unlock()
    }
}
