//
//  CaptureRequestMetrics.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import Foundation

/// CaptureRequestMetrics is one process-wide reading of capture admission and
/// framework pressure.
///
/// A pending framework call has no duration sample yet. Its execution remains
/// unknown until the real Apple completion arrives, even when every caller has
/// timed out or cancelled. `completedFrameworkExecution` therefore covers
/// exactly `completedFrameworkCalls`, never the calls still pending.
/// `cumulativeAdmissionWait` covers coordinator admission only; neither field
/// includes public-entry actor waits, listing plans, or frame decoding.
nonisolated public struct CaptureRequestMetrics: Sendable, Equatable {

    public let pendingFrameworkCalls       : Int
    public let peakPendingFrameworkCalls   : Int
    public let queuedFrameworkCalls        : Int
    public let retainedWaiters             : Int
    public let peakRetainedWaiters         : Int
    public let rejectedRequests            : UInt64
    public let coalescedRequests           : UInt64
    public let timedOutRequests            : UInt64
    public let cancelledRequests           : UInt64
    public let lateResults                 : UInt64
    public let discardedResults            : UInt64
    public let admittedFrameworkCalls      : UInt64
    public let completedFrameworkCalls     : UInt64
    public let cumulativeAdmissionWait     : Duration
    public let completedFrameworkExecution : Duration
}

/// captureRequestMetrics reads process-wide counters without starting capture.
nonisolated public func captureRequestMetrics() -> CaptureRequestMetrics {
    CaptureFrameworkCoordinator.shared.metrics
}

nonisolated extension Duration {

    static func captureNanoseconds(clamping value: UInt64) -> Duration {
        .nanoseconds(Int64(min(value, UInt64(Int64.max))))
    }
}
