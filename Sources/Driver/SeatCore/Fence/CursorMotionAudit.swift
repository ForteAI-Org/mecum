//
//  CursorMotionAudit.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import Foundation

/// CursorMotionAudit is a sampled oracle: it correlates the global cursor
/// position with the physical HID input observed by the fence, and reports
/// whether every reading of the cursor is explained by a real hand movement.
/// It posts nothing and rewrites no coordinate.
///
/// It keeps both the instant the event happened and the instant its callback
/// reached the tap, because the two are not atomic with the global cursor read.
/// Every reconciliation still requires an exact HID coordinate: a late callback
/// buys time, never spatial tolerance.
///
/// `recordInput` runs inside the fence callback, whose budget is zero
/// allocations, so both traces are allocated once up front and the observed
/// source identities are kept as values and only formatted in `result()`.
public final class CursorMotionAudit {

    /// Result is the whole audit as fields: a report prints them, a test
    /// asserts on them, and nothing here is a sentence except the mismatch
    /// details, which exist to be read by a person diagnosing a failure.
    public struct Result: Sendable, Equatable {
        
        public let passed                          : Bool
        public let physicalEventCount              : Int
        public let driverEventCount                : Int
        public let otherEventCount                 : Int
        public let sampleCount                     : Int
        public let unexplainedSampleCount          : Int
        public let maximumUnexplainedDistance      : CGFloat
        public let failure                         : String?
        public let observedSources                 : [String]
        public let eventsBeforeBaseline            : Int
        public let firstEventTimestamp             : UInt64?
        public let baselineTimestamp               : UInt64
        public let convertedTimestampCount         : Int
        public let pendingDeliverySampleCount      : Int
        public let delayedCallbackSampleCount      : Int
        public let maximumCallbackDelayMilliseconds: Double
        public let mismatchDetails                 : [String]
        
    }

    private struct PointInTime {
        let point     : CGPoint
        let timestamp : UInt64
        let occurredAt: UInt64?
    }

    /// The identity of an event source, kept as three integers so that
    /// recognizing an already seen source costs no allocation. The string form
    /// is built once, in `result()`.
    private struct SourceIdentity: Equatable {
        let processID: Int64
        let stateID  : Int64
        let hasMarker: Bool
        
    }

    private let marker   : Int64
    private let startTime: UInt64
    
    private var physicalPoints: [PointInTime]
    private var samples       : [PointInTime] = []
    
    private var isSampling         = true
    private var physicalEventCount = 0
    private var driverEventCount   = 0
    private var otherEventCount    = 0
    
    private var failure        : String?
    private var observedSources: [SourceIdentity] = []
    
    private var eventsBeforeBaseline = 0
    
    private var firstEventTimestamp: UInt64?
    
    private var convertedTimestampCount = 0

    /// How many HID points and how many cursor samples one audit can hold. Both
    /// traces are reserved to it in `init`, so the callback never grows an
    /// array; past the limit the audit invalidates itself instead of allocating.
    public static let capacity = 8_192

    /// How many distinct event source identities are kept for the report.
    private static let observedSourceCapacity = 8

    /// macOS 27 trace: the cursor still published the previous HID point
    /// 1.75 ms after the new event. That single point is accepted for at most
    /// 4 ms, and only until a new position has been observed. The same limit
    /// applies to an event that already happened whose callback reaches the tap
    /// just after the global cursor was read.
    public static let deliveryPublicationLimit: UInt64 = 4_000_000

    public init(
        marker   : Int64,
        point    : CGPoint,
        timestamp: UInt64
    ) {
        
        self.marker         = marker
        self.startTime      = timestamp
        self.physicalPoints = [
            PointInTime(point: point, timestamp: timestamp, occurredAt: nil)
        ]
        
        physicalPoints.reserveCapacity(Self.capacity)
        samples.reserveCapacity(Self.capacity)
        observedSources.reserveCapacity(Self.observedSourceCapacity)
        
        if !point.x.isFinite || !point.y.isFinite {
            failure = "initial cursor position unavailable"
        }
    }

    /// invalidate records the first reason the audit cannot conclude. A later
    /// reason does not overwrite it: the first one is the one that happened.
    public func invalidate(_ reason: String) {
        if failure == nil { failure = reason }
    }

    /// recordInput takes one event from the fence callback. It allocates
    /// nothing: both traces are preallocated, the source identity is stored as
    /// integers, and every rejection path returns without building a string.
    public func recordInput(
        point              : CGPoint,
        timestamp          : UInt64,
        sourceProcessID    : Int64,
        sourceStateID      : Int64,
        userData           : Int64,
        isMovement         : Bool,
        receivedAt         : UInt64,
        timebaseNumerator  : UInt32 = 1,
        timebaseDenominator: UInt32 = 1
    ) {
        
        if userData == marker {
            driverEventCount += 1
            return
        }
        
        recordObservedSource(
            SourceIdentity(
                processID: sourceProcessID,
                stateID  : sourceStateID,
                hasMarker: userData != 0
            )
        )
        
        // Not being our own event is not enough: posts from other processes
        // and private sources are no proof that the person moved the mouse.
        guard sourceProcessID == 0, userData == 0,
              sourceStateID == Int64(CGEventSourceStateID.hidSystemState.rawValue)
        else {
            otherEventCount += 1
            return
        }
        
        guard isMovement else { return }
        
        if firstEventTimestamp == nil {
            firstEventTimestamp = timestamp
        }
        
        guard let normalizedTime = Self.normalizedTimestamp(
            timestamp, receivedAt: receivedAt,
            numerator: timebaseNumerator, denominator: timebaseDenominator
        ) else {
            invalidate("invalid HID timestamp or ambiguous time domain")
            return
        }
        
        if normalizedTime != timestamp { convertedTimestampCount += 1 }
        let deliveryTime = receivedAt
        
        guard deliveryTime >= startTime else {
            eventsBeforeBaseline += 1
            return
        }
        
        guard point.x.isFinite, point.y.isFinite else {
            invalidate("invalid HID coordinates")
            return
        }
        
        guard physicalPoints.count < Self.capacity else {
            invalidate("HID trace past its limit")
            return
        }
        
        physicalEventCount += 1
        physicalPoints.append(
            PointInTime(
                point     : point,
                timestamp : deliveryTime,
                occurredAt: normalizedTime
            )
        )
    }

    /// Keeps the first few distinct source identities for the report. The
    /// linear scan over at most eight values is what keeps the callback free of
    /// allocations: a Set of formatted strings would allocate per event.
    private func recordObservedSource(_ identity: SourceIdentity) {
        
        guard observedSources.count < Self.observedSourceCapacity else {
            return
        }
        
        for known in observedSources where known == identity { return }
        
        observedSources.append(identity)
    }

    /// sample takes one reading of the global cursor. A reading before the
    /// baseline, an unavailable position or an overflowing trace invalidate the
    /// audit: none of them can be told apart from a real anomaly.
    public func sample(
        point    : CGPoint?,
        timestamp: UInt64
    ) {
        
        guard isSampling else { return }
        
        guard timestamp >= startTime else {
            invalidate("cursor sample older than the baseline")
            return
        }
        
        guard let point, point.x.isFinite, point.y.isFinite else {
            invalidate("global cursor position unavailable")
            return
        }
        
        guard samples.count < Self.capacity else {
            invalidate("cursor samples past their limit")
            return
        }
        
        samples.append(
            PointInTime(
                point     : point,
                timestamp : timestamp,
                occurredAt: nil
            )
        )
    }

    /// finishSampling closes the observed interval after the last input and its
    /// settle. The tap stays attached, so the callbacks of the last sample can
    /// still arrive and be reconciled.
    public func finishSampling() {
        isSampling = false
    }

    /// result correlates the two traces. Every sample must be explained by the
    /// last HID point known at its instant, by the previous point still being
    /// published, or by a movement that had already happened whose callback
    /// arrived late. Anything else is an unexplained cursor movement.
    public func result() -> Result {
        
        let orderedPoints = physicalPoints.sorted { $0.timestamp < $1.timestamp }
        
        var pointIndex = 0
        var unexplainedCount = 0
        var maximumDistance: CGFloat = 0
        var confirmedPointIndex = 0
        var pendingDeliveryCount = 0
        var delayedCallbackCount = 0
        var mismatchDetails: [String] = []
        
        for sample in samples.sorted(by: { $0.timestamp < $1.timestamp }) {
            
            while pointIndex + 1 < orderedPoints.count,
                  orderedPoints[pointIndex + 1].timestamp <= sample.timestamp {
                pointIndex += 1
            }
            
            let expected = orderedPoints[pointIndex].point
            let distance = hypot(sample.point.x - expected.x, sample.point.y - expected.y)
            
            // A position already confirmed by a global read cannot move back
            // just because the matching callback is still queued.
            let confirmedDistance = hypot(
                sample.point.x - orderedPoints[confirmedPointIndex].point.x,
                sample.point.y - orderedPoints[confirmedPointIndex].point.y
            )
            
            if distance < 0.5, pointIndex >= confirmedPointIndex || confirmedDistance < 0.5 {
                confirmedPointIndex = max(confirmedPointIndex, pointIndex)
                continue
            }
            
            if pointIndex > 0, confirmedPointIndex < pointIndex,
               sample.timestamp - orderedPoints[pointIndex].timestamp <= Self.deliveryPublicationLimit {
                
                let previous = orderedPoints[pointIndex - 1].point
                if hypot(sample.point.x - previous.x, sample.point.y - previous.y) < 0.5 {
                    confirmedPointIndex = max(confirmedPointIndex, pointIndex - 1)
                    pendingDeliveryCount += 1
                    continue
                }
            }
            
            // The CGEvent timestamp says when the movement happened; receivedAt
            // says when the run loop ran the tap. A late callback is accepted
            // inside the same publication limit, for a movement that already
            // happened, recent and with exact coordinates. A future movement
            // never justifies a warp.
            var matchingDelayedCallback: Int?
            var candidateIndex = max(pointIndex + 1, confirmedPointIndex)
            while candidateIndex < orderedPoints.count {
                
                let candidate = orderedPoints[candidateIndex]
                guard candidate.timestamp > sample.timestamp else {
                    candidateIndex += 1
                    continue
                }
                
                if candidate.timestamp - sample.timestamp > Self.deliveryPublicationLimit {
                    break
                }
                
                if let occurredAt = candidate.occurredAt,
                   occurredAt >= startTime, occurredAt <= sample.timestamp,
                   sample.timestamp - occurredAt <= Self.deliveryPublicationLimit,
                   hypot(sample.point.x - candidate.point.x, sample.point.y - candidate.point.y) < 0.5 {
                    matchingDelayedCallback = candidateIndex
                    break
                }
                candidateIndex += 1
            }
            
            if let matchingDelayedCallback {
                confirmedPointIndex = max(confirmedPointIndex, matchingDelayedCallback)
                delayedCallbackCount += 1
                continue
            }
            
            // A correspondence that was not proven stays a failure.
            unexplainedCount += 1
            let unexplainedDistance = confirmedPointIndex > pointIndex
                ? max(distance, confirmedDistance) : distance
            maximumDistance = max(maximumDistance, unexplainedDistance)
            
            if mismatchDetails.count < 4 {
                let age = Double(sample.timestamp - orderedPoints[pointIndex].timestamp) / 1_000_000
                
                var detail = String(format:
                    "sample (%.2f, %.2f) at %llu ns, last HID (%.2f, %.2f), received %.3f ms earlier",
                    sample.point.x, sample.point.y, sample.timestamp, expected.x, expected.y, age)
                
                if confirmedPointIndex > pointIndex {
                    let confirmed = orderedPoints[confirmedPointIndex].point
                    detail += String(format: "\n  Position already confirmed (%.2f, %.2f)", confirmed.x, confirmed.y)
                }
                
                // Nearby coordinates and times diagnose the cause without
                // pouring the whole trace into the consumer's report.
                for index in max(0, pointIndex - 2)...min(orderedPoints.count - 1, pointIndex + 2) {
                    
                    let neighbor = orderedPoints[index]
                    let deliveryDelta = (Double(neighbor.timestamp) - Double(sample.timestamp)) / 1_000_000
                    let eventDelta = neighbor.occurredAt.map {
                        String(format: "%.3f", (Double($0) - Double(sample.timestamp)) / 1_000_000)
                    } ?? "baseline"
                    detail += String(format: "\n  HID[%d] (%.2f, %.2f), event %@ ms, callback %+.3f ms from the sample",
                        index, neighbor.point.x, neighbor.point.y, eventDelta, deliveryDelta)
                }
                mismatchDetails.append(detail)
            }
        }
        return Result(
            passed: failure == nil && !samples.isEmpty && unexplainedCount == 0,
            physicalEventCount: physicalEventCount,
            driverEventCount: driverEventCount,
            otherEventCount: otherEventCount,
            sampleCount: samples.count,
            unexplainedSampleCount: unexplainedCount,
            maximumUnexplainedDistance: maximumDistance,
            failure: failure,
            observedSources: observedSources.map {
                "PID \($0.processID), state \($0.stateID), marker \($0.hasMarker ? "present" : "zero")"
            },
            eventsBeforeBaseline: eventsBeforeBaseline,
            firstEventTimestamp: firstEventTimestamp,
            baselineTimestamp: startTime,
            convertedTimestampCount: convertedTimestampCount,
            pendingDeliverySampleCount: pendingDeliveryCount,
            delayedCallbackSampleCount: delayedCallbackCount,
            maximumCallbackDelayMilliseconds: orderedPoints.compactMap { point -> Double? in
                guard let occurredAt = point.occurredAt else { return nil }
                return Double(point.timestamp - occurredAt) / 1_000_000
            }.max() ?? 0,
            mismatchDetails: mismatchDetails
        )
    }

    /// CGEventTimestamp is documented in nanoseconds; in the macOS 27 tap on
    /// Apple Silicon we also observed Mach ticks. Only the domain that places
    /// the event in the five seconds before its delivery is accepted. The
    /// threshold recognizes the clock, it does not widen the spatial tolerance.
    public static func normalizedTimestamp(
        _ timestamp: UInt64,
        receivedAt: UInt64,
        numerator: UInt32,
        denominator: UInt32
    ) -> UInt64? {
        guard timestamp > 0, numerator > 0, denominator > 0 else { return nil }
        let product = timestamp.multipliedFullWidth(by: UInt64(numerator))
        guard product.high < UInt64(denominator) else { return nil }
        let scaled = UInt64(denominator).dividingFullWidth(product).quotient
        func recent(_ value: UInt64) -> Bool {
            value <= receivedAt && receivedAt - value <= 5_000_000_000
        }
        if scaled == timestamp { return recent(timestamp) ? timestamp : nil }
        switch (recent(timestamp), recent(scaled)) {
        case (true, false): return timestamp
        case (false, true): return scaled
        default: return nil
        }
    }
}
