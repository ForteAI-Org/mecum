//
//  StillCaptureReply.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import CoreMedia
import Foundation

/// StillCaptureReply binds sample provenance at the Apple callback. Coalesced
/// waiters receive this same value, including the same callback time and
/// observation revision, instead of inventing one after each executor resumes.
nonisolated struct StillCaptureReply: @unchecked Sendable {
    let sampleBuffer    : CMSampleBuffer
    let receivedAt      : UInt64
    let observedRevision: UInt64
}

/// StillObservationSequence gives direct still samples a process-wide revision.
/// The lock is off the frame stream hot path and advances once per actual Apple
/// sample callback, not once per coalesced caller.
nonisolated final class StillObservationSequence: @unchecked Sendable {

    static let shared = StillObservationSequence()

    private let lock = NSLock()
    private var revision: UInt64 = 0

    private init() {}

    func next() -> UInt64 {
        lock.lock()
        revision &+= 1
        let value = revision
        lock.unlock()
        return value
    }
}
