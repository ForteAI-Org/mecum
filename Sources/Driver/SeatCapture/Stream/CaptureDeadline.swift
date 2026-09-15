//
//  CaptureDeadline.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import Foundation

/// CaptureDeadline carries the one monotonic deadline created at a public
/// operation entry. Passing it through listing, planning and capture prevents
/// each step from silently receiving a fresh timeout.
///
/// The deadline bounds admission and result delivery. It cannot preempt a
/// synchronous operating-system call or make MainActor/Dispatch scheduling
/// real-time; every boundary therefore checks the same monotonic expiry again.
nonisolated struct CaptureDeadline: Sendable {

    let startedAt : UInt64
    let expiresAt : UInt64

    init(timeout: Duration) {
        let start = DispatchTime.now().uptimeNanoseconds
        let sum = start.addingReportingOverflow(timeout.captureNanoseconds)
        startedAt = start
        expiresAt = sum.overflow ? UInt64.max : sum.partialValue
    }

    var remainingNanoseconds: UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        return expiresAt > now ? expiresAt - now : 0
    }

    func check(_ step: CaptureStep) throws {
        guard remainingNanoseconds > 0 else { throw CaptureFailure.timedOut(step) }
    }
}

nonisolated private extension Duration {

    var captureNanoseconds: UInt64 {
        let value = seconds
        guard value > 0 else { return 0 }
        let maximum = Double(UInt64.max)
        guard value < maximum / 1_000_000_000 else { return UInt64.max }
        return UInt64(value * 1_000_000_000)
    }
}
