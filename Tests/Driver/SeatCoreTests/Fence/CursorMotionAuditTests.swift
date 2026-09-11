//
//  CursorMotionAuditTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
@testable import SeatCore
import Testing

/// The suite correlates controlled data: no tap is installed and no event is
/// posted. The traces that
/// carry a date in their name are real ones, kept as regressions.
@Suite("Cursor motion audit")
struct CursorMotionAuditTests {

    func makeAudit() -> CursorMotionAudit {
        CursorMotionAudit(marker: 123, point: .zero, timestamp: 100_000_000)
    }

    /// One physical HID movement, delivered at the instant it happened.
    func move(
        _ audit: CursorMotionAudit,
        _ x    : CGFloat,
        time   : UInt64 = 110,
        pid    : Int64 = 0,
        state  : Int64 = 1,
        marker : Int64 = 0
    ) {
        audit.recordInput(
            point: CGPoint(x: x, y: 0), timestamp: time * 1_000_000,
            sourceProcessID: pid, sourceStateID: state, userData: marker,
            isMovement: true, receivedAt: time * 1_000_000
        )
    }

    /// One HID movement that already happened and whose callback arrives later.
    func delayedMove(
        _ audit  : CursorMotionAudit,
        _ x      : CGFloat = 48.6,
        occurred : UInt64 = 119_000_000,
        delivered: UInt64 = 121_000_000,
        pid      : Int64 = 0,
        state    : Int64 = 1,
        marker   : Int64 = 0
    ) {
        audit.recordInput(
            point: CGPoint(x: x, y: 0), timestamp: occurred,
            sourceProcessID: pid, sourceStateID: state, userData: marker,
            isMovement: true, receivedAt: delivered
        )
    }

    func sample(_ audit: CursorMotionAudit, _ x: CGFloat, time: UInt64 = 120) {
        audit.sample(point: CGPoint(x: x, y: 0), timestamp: time * 1_000_000)
    }

    @Test("a still cursor with no input passes")
    func stillCursor() {
        let audit = makeAudit()
        sample(audit, 0)
        #expect(audit.result().passed)
    }

    @Test("a physical movement of 48.6 points is allowed")
    func physicalMovementAllowed() {
        let audit = makeAudit()
        move(audit, 48.6)
        sample(audit, 48.6)
        #expect(audit.result().passed)
        #expect(audit.result().physicalEventCount == 1)
    }

    @Test("a warp of 48.6 points with no input is rejected")
    func warpRejected() {
        let audit = makeAudit()
        sample(audit, 48.6)
        #expect(!audit.result().passed)
    }

    @Test("a physical movement does not authorize a different point")
    func movementDoesNotAuthorizeAnotherPoint() {
        let audit = makeAudit()
        move(audit, 48.6)
        sample(audit, 100)
        #expect(!audit.result().passed)
    }

    @Test("a later event does not justify an earlier warp")
    func laterEventDoesNotJustifyWarp() {
        let audit = makeAudit()
        sample(audit, 48.6)
        move(audit, 48.6, time: 130)
        #expect(!audit.result().passed)
    }

    @Test("a late delivery of an event that preceded the sample is accepted")
    func lateDeliveryAccepted() {
        let audit = makeAudit()
        sample(audit, 48.6)
        move(audit, 48.6, time: 110)
        #expect(audit.result().passed)
    }

    @Test("a warp out and back stays detected")
    func warpAndBackDetected() {
        let audit = makeAudit()
        sample(audit, 48.6)
        sample(audit, 0, time: 130)
        #expect(!audit.result().passed)
    }

    @Test("the driver's own marker never becomes physical input")
    func driverMarkerIsNotPhysical() {
        let audit = makeAudit()
        move(audit, 48.6, marker: 123)
        sample(audit, 48.6)
        #expect(!audit.result().passed)
        #expect(audit.result().driverEventCount == 1)
    }

    @Test("a synthetic event from another process does not authorize movement")
    func otherProcessIsNotPhysical() {
        let audit = makeAudit()
        move(audit, 48.6, pid: 99)
        sample(audit, 48.6)
        #expect(!audit.result().passed)
    }

    @Test("a foreign marker does not authorize movement")
    func foreignMarkerIsNotPhysical() {
        let audit = makeAudit()
        move(audit, 48.6, marker: 321)
        sample(audit, 48.6)
        #expect(!audit.result().passed)
    }

    @Test("a private event source does not authorize movement")
    func privateSourceIsNotPhysical() {
        let audit = makeAudit()
        move(audit, 48.6, state: -1)
        sample(audit, 48.6)
        #expect(!audit.result().passed)
    }

    @Test("a disabled tap denies the pass even with a still cursor")
    func disabledTapDeniesPass() {
        let audit = makeAudit()
        sample(audit, 0)
        audit.invalidate("tap disabled")
        #expect(!audit.result().passed)
    }

    @Test("no samples never produces a pass")
    func noSamplesNoPass() {
        #expect(!makeAudit().result().passed)
    }

    @Test("an unavailable position denies the pass")
    func unavailablePositionDeniesPass() {
        let audit = makeAudit()
        audit.sample(point: nil, timestamp: 120_000_000)
        #expect(!audit.result().passed)
    }

    @Test("a physical event before the baseline is ignored")
    func eventBeforeBaselineIgnored() {
        let audit = makeAudit()
        move(audit, 48.6, time: 99)
        sample(audit, 48.6)
        #expect(!audit.result().passed)
    }

    @Test("the last physical position still counts after further samples")
    func lastPositionKeepsCounting() {
        let audit = makeAudit()
        move(audit, 48.6)
        sample(audit, 48.6)
        sample(audit, 48.6, time: 900)
        #expect(audit.result().passed)
    }

    @Test("an old position does not hide a warp after a movement")
    func oldPositionDoesNotHideWarp() {
        let audit = makeAudit()
        move(audit, 48.6)
        sample(audit, 0)
        #expect(!audit.result().passed)
    }

    @Test("a press without movement does not justify a warp")
    func pressWithoutMovement() {
        let audit = makeAudit()
        audit.recordInput(
            point: CGPoint(x: 48.6, y: 0), timestamp: 110_000_000,
            sourceProcessID: 0, sourceStateID: 1, userData: 0,
            isMovement: false, receivedAt: 110_000_000
        )
        sample(audit, 48.6)
        #expect(!audit.result().passed)
    }

    @Test("a trace overflow denies the pass")
    func traceOverflowDeniesPass() {
        let audit = makeAudit()
        for index in 0..<CursorMotionAudit.capacity {
            move(audit, 0, time: UInt64(110 + index))
        }
        sample(audit, 0, time: 10_000)
        #expect(!audit.result().passed)
    }

    @Test("the Mach timestamp of the real trace is converted")
    func machTimestampConverted() {
        #expect(CursorMotionAudit.normalizedTimestamp(
            2_519_147_356_447, receivedAt: 104_964_700_000_000,
            numerator: 125, denominator: 3
        ) == 104_964_473_185_291)
    }

    @Test("a timestamp already in nanoseconds is not scaled twice")
    func nanosecondTimestampNotScaled() {
        #expect(CursorMotionAudit.normalizedTimestamp(
            104_964_473_185_291, receivedAt: 104_964_700_000_000,
            numerator: 125, denominator: 3
        ) == 104_964_473_185_291)
    }

    @Test("an ambiguous time domain is refused")
    func ambiguousDomainRefused() {
        #expect(CursorMotionAudit.normalizedTimestamp(
            100, receivedAt: 10_000, numerator: 125, denominator: 3) == nil)
    }

    @Test("a future timestamp is refused")
    func futureTimestampRefused() {
        #expect(CursorMotionAudit.normalizedTimestamp(
            200, receivedAt: 100, numerator: 1, denominator: 1) == nil)
    }

    @Test("a zero timestamp is refused")
    func zeroTimestampRefused() {
        #expect(CursorMotionAudit.normalizedTimestamp(
            0, receivedAt: 100_000_000, numerator: 1, denominator: 1) == nil)
    }

    @Test("a time overflow is refused")
    func timeOverflowRefused() {
        #expect(CursorMotionAudit.normalizedTimestamp(
            UInt64.max, receivedAt: UInt64.max, numerator: 125, denominator: 3) == nil)
    }

    @Test("an expired event is refused")
    func expiredEventRefused() {
        #expect(CursorMotionAudit.normalizedTimestamp(
            1, receivedAt: 6_000_000_000, numerator: 1, denominator: 1) == nil)
    }

    @Test("a delivery 10 ms after the sample does not justify it retroactively")
    func deliveryTooLateDoesNotJustify() {
        let audit = makeAudit()
        sample(audit, 48.6)
        audit.recordInput(
            point: CGPoint(x: 48.6, y: 0), timestamp: 110_000_000,
            sourceProcessID: 0, sourceStateID: 1, userData: 0,
            isMovement: true, receivedAt: 130_000_000
        )
        #expect(!audit.result().passed)
    }

    @Test("an event queued before the baseline but delivered after it counts")
    func queuedBeforeBaselineDeliveredAfter() {
        let audit = makeAudit()
        audit.recordInput(
            point: CGPoint(x: 48.6, y: 0), timestamp: 90_000_000,
            sourceProcessID: 0, sourceStateID: 1, userData: 0,
            isMovement: true, receivedAt: 110_000_000
        )
        sample(audit, 48.6)
        #expect(audit.result().passed)
    }

    @Test("an HID queue does not alter the sample taken before its delivery")
    func queueDoesNotAlterEarlierSample() {
        let audit = makeAudit()
        sample(audit, 0, time: 120)
        audit.recordInput(
            point: CGPoint(x: 48.6, y: 0), timestamp: 110_000_000,
            sourceProcessID: 0, sourceStateID: 1, userData: 0,
            isMovement: true, receivedAt: 130_000_000
        )
        sample(audit, 48.6, time: 140)
        #expect(audit.result().passed)
    }

    @Test("a late HID publication keeps only the previous point")
    func latePublicationKeepsPreviousPoint() {
        let audit = makeAudit()
        move(audit, 20)
        sample(audit, 0, time: 112)
        sample(audit, 20, time: 130)
        #expect(audit.result().passed)
        #expect(audit.result().pendingDeliverySampleCount == 1)
    }

    @Test("a delay beyond 4 ms is not masked")
    func delayBeyondLimitNotMasked() {
        let audit = makeAudit()
        move(audit, 20)
        sample(audit, 0, time: 115)
        #expect(!audit.result().passed)
    }

    @Test("foreign coordinates during the delivery stay rejected")
    func foreignCoordinatesDuringDelivery() {
        let audit = makeAudit()
        move(audit, 20)
        sample(audit, 99, time: 112)
        #expect(!audit.result().passed)
    }

    @Test("going back to the previous point after a confirmation stays a warp")
    func backAfterConfirmationIsWarp() {
        let audit = makeAudit()
        move(audit, 20)
        sample(audit, 20, time: 111)
        sample(audit, 0, time: 112)
        #expect(!audit.result().passed)
    }

    @Test("two consecutive events do not authorize an older point")
    func twoEventsDoNotAuthorizeOlderPoint() {
        let audit = makeAudit()
        move(audit, 20)
        move(audit, 40, time: 111)
        sample(audit, 0, time: 112)
        #expect(!audit.result().passed)
    }

    @Test("the publication delay does not authorize synthetic events")
    func publicationDelayDoesNotAuthorizeSynthetic() {
        let audit = makeAudit()
        move(audit, 20, marker: 123)
        sample(audit, 20, time: 112)
        #expect(!audit.result().passed)
    }

    @Test("the physical Slack trace of 5 September is reproduced")
    func slackTraceReproduced() {
        let audit = CursorMotionAudit(
            marker: 123,
            point: CGPoint(x: 384.91796875, y: 631.91015625),
            timestamp: 106_964_170_000_000
        )
        let trace: [(UInt64, CGFloat, CGFloat)] = [
            (106_964_178_863_000, 431.7421875, 618.25),
            (106_964_186_539_666, 474.6640625, 594.8359375),
            (106_964_193_526_791, 518.625, 559.24609375),
            (106_964_209_407_208, 581.30859375, 474.3125)
        ]
        for (time, x, y) in trace {
            audit.recordInput(
                point: CGPoint(x: x, y: y), timestamp: time,
                sourceProcessID: 0, sourceStateID: 1, userData: 0,
                isMovement: true, receivedAt: time
            )
        }
        audit.sample(point: CGPoint(x: 474.6640625, y: 594.8359375), timestamp: 106_964_195_280_208)
        audit.sample(point: CGPoint(x: 581.30859375, y: 474.3125), timestamp: 106_964_216_069_208)
        #expect(audit.result().passed)
        #expect(audit.result().pendingDeliverySampleCount == 1)
    }

    @Test("a sample before the baseline is refused without underflow")
    func sampleBeforeBaselineRefused() {
        let audit = makeAudit()
        sample(audit, 10, time: 99)
        #expect(!audit.result().passed)
    }

    @Test("the time limit is inclusive and does not stretch by one nanosecond")
    func timeLimitIsInclusive() {
        let inside = makeAudit()
        move(inside, 20)
        sample(inside, 0, time: 114)
        let outside = makeAudit()
        move(outside, 20)
        outside.sample(point: .zero, timestamp: 114_000_001)
        #expect(inside.result().passed)
        #expect(!outside.result().passed)
    }

    @Test("an HID movement that already happened is confirmed by a later callback")
    func delayedCallbackConfirmsSample() {
        let audit = makeAudit()
        sample(audit, 48.6)
        delayedMove(audit)
        let result = audit.result()
        #expect(result.passed)
        #expect(result.delayedCallbackSampleCount == 1)
        #expect(result.maximumCallbackDelayMilliseconds == 2)
        #expect(result.pendingDeliverySampleCount == 0)
    }

    @Test("a physical movement one nanosecond in the future stays rejected")
    func futureMovementRejected() {
        let audit = makeAudit()
        sample(audit, 48.6)
        delayedMove(audit, occurred: 120_000_001)
        #expect(!audit.result().passed)
    }

    @Test("a callback one nanosecond past the limit stays rejected")
    func callbackPastLimitRejected() {
        let audit = makeAudit()
        sample(audit, 48.6)
        delayedMove(audit, delivered: 124_000_001)
        #expect(!audit.result().passed)
    }

    @Test("an event too old stays rejected even with a close callback")
    func eventTooOldRejected() {
        let audit = makeAudit()
        sample(audit, 48.6)
        delayedMove(audit, occurred: 115_999_999)
        #expect(!audit.result().passed)
    }

    @Test("both callback time limits are inclusive")
    func callbackLimitsInclusive() {
        let audit = makeAudit()
        sample(audit, 48.6)
        delayedMove(audit, occurred: 116_000_000, delivered: 124_000_000)
        #expect(audit.result().passed)
        #expect(audit.result().delayedCallbackSampleCount == 1)
    }

    @Test("foreign coordinates are not justified by a late callback")
    func foreignCoordinatesNotJustifiedByCallback() {
        let audit = makeAudit()
        sample(audit, 99)
        delayedMove(audit)
        #expect(!audit.result().passed)
    }

    @Test("a late callback does not widen the spatial tolerance")
    func callbackDoesNotWidenTolerance() {
        let outside = makeAudit()
        sample(outside, 49.1)
        delayedMove(outside)
        let inside = makeAudit()
        sample(inside, 49.09)
        delayedMove(inside)
        #expect(!outside.result().passed)
        #expect(inside.result().passed)
    }

    @Test("a late driver callback is not physical HID")
    func lateDriverCallbackIsNotPhysical() {
        let audit = makeAudit()
        sample(audit, 48.6)
        delayedMove(audit, marker: 123)
        #expect(!audit.result().passed)
        #expect(audit.result().driverEventCount == 1)
    }

    @Test("a late callback from another process is not physical HID")
    func lateOtherProcessCallbackIsNotPhysical() {
        let audit = makeAudit()
        sample(audit, 48.6)
        delayedMove(audit, pid: 99)
        #expect(!audit.result().passed)
        #expect(audit.result().otherEventCount == 1)
    }

    @Test("a late callback with a foreign marker is not physical HID")
    func lateForeignMarkerIsNotPhysical() {
        let audit = makeAudit()
        sample(audit, 48.6)
        delayedMove(audit, marker: 321)
        #expect(!audit.result().passed)
    }

    @Test("a late callback from a private source is not physical HID")
    func latePrivateSourceIsNotPhysical() {
        let audit = makeAudit()
        sample(audit, 48.6)
        delayedMove(audit, state: -1)
        #expect(!audit.result().passed)
    }

    @Test("an event before the baseline does not justify an early reading")
    func eventBeforeBaselineDoesNotJustifyReading() {
        let audit = makeAudit()
        sample(audit, 48.6, time: 101)
        delayedMove(audit, occurred: 99_000_000, delivered: 102_000_000)
        #expect(!audit.result().passed)
    }

    @Test("repeated readings before the delivery stay coherent")
    func repeatedReadingsBeforeDelivery() {
        let audit = makeAudit()
        sample(audit, 48.6)
        sample(audit, 48.6, time: 121)
        delayedMove(audit, delivered: 122_000_000)
        sample(audit, 48.6, time: 123)
        #expect(audit.result().passed)
        #expect(audit.result().delayedCallbackSampleCount == 2)
    }

    @Test("going back to the old point before the callback stays a warp")
    func backToOldPointBeforeCallback() {
        let audit = makeAudit()
        sample(audit, 48.6)
        sample(audit, 0, time: 121)
        delayedMove(audit, delivered: 122_000_000)
        let result = audit.result()
        #expect(!result.passed)
        #expect(result.unexplainedSampleCount == 1)
        #expect(result.maximumUnexplainedDistance == 48.6)
    }

    @Test("going back after a confirmed point was delivered stays a warp")
    func backAfterDeliveredConfirmation() {
        let audit = makeAudit()
        sample(audit, 48.6)
        delayedMove(audit)
        sample(audit, 0, time: 122)
        #expect(!audit.result().passed)
    }

    @Test("two queued callbacks do not authorize a return to a superseded point")
    func twoQueuedCallbacksDoNotAuthorizeReturn() {
        let audit = makeAudit()
        sample(audit, 80)
        sample(audit, 48.6, time: 121)
        delayedMove(audit, 48.6, occurred: 118_000_000, delivered: 122_000_000)
        delayedMove(audit, 80, occurred: 119_000_000, delivered: 123_000_000)
        #expect(!audit.result().passed)
        #expect(audit.result().unexplainedSampleCount == 1)
    }

    @Test("a real movement back that already happened stays allowed")
    func realMovementBackAllowed() {
        let audit = makeAudit()
        sample(audit, 48.6)
        sample(audit, 0, time: 121)
        delayedMove(audit, delivered: 122_000_000)
        delayedMove(audit, 0, occurred: 120_500_000, delivered: 123_000_000)
        #expect(audit.result().passed)
        #expect(audit.result().delayedCallbackSampleCount == 2)
    }

    @Test("the synthetic case built from the Luna report's coordinates")
    func lunaReportCase() {
        // The original report carries no nearby event: these times build the
        // causal case, they do not reconstruct the real evidence.
        let prior = CGPoint(x: 560.77, y: 679.45)
        let next  = CGPoint(x: 690.87, y: 621.09)
        let audit = CursorMotionAudit(marker: 123, point: prior, timestamp: 100_000_000)
        audit.recordInput(
            point: prior, timestamp: 119_000_000, sourceProcessID: 0,
            sourceStateID: 1, userData: 0, isMovement: true, receivedAt: 119_797_000
        )
        audit.sample(point: next, timestamp: 120_000_000)
        audit.recordInput(
            point: next, timestamp: 119_900_000, sourceProcessID: 0,
            sourceStateID: 1, userData: 0, isMovement: true, receivedAt: 120_300_000
        )
        #expect(audit.result().passed)
        #expect(audit.result().delayedCallbackSampleCount == 1)
    }

    @Test("a Mach timestamp is kept for the late correlation too")
    func machTimestampKeptForLateCorrelation() {
        let audit = CursorMotionAudit(marker: 123, point: .zero, timestamp: 100_000_000_000)
        audit.sample(point: CGPoint(x: 48.6, y: 0), timestamp: 100_002_000_000)
        audit.recordInput(
            point: CGPoint(x: 48.6, y: 0), timestamp: 2_400_024_000,
            sourceProcessID: 0, sourceStateID: 1, userData: 0, isMovement: true,
            receivedAt: 100_003_000_000, timebaseNumerator: 125, timebaseDenominator: 3
        )
        let result = audit.result()
        #expect(result.passed)
        #expect(result.convertedTimestampCount == 1)
        #expect(result.delayedCallbackSampleCount == 1)
    }

    @Test("closing the samples still lets the final callback arrive")
    func closingLetsFinalCallbackArrive() {
        let audit = makeAudit()
        sample(audit, 48.6)
        audit.finishSampling()
        #expect(!audit.result().passed)
        delayedMove(audit)
        sample(audit, 999, time: 122)
        #expect(audit.result().passed)
        #expect(audit.result().sampleCount == 1)
    }

    @Test("closing without a physical callback stays a failure")
    func closingWithoutCallbackFails() {
        let audit = makeAudit()
        sample(audit, 48.6)
        audit.finishSampling()
        #expect(!audit.result().passed)
    }

    @Test("a tap invalidated during the closing never produces a pass")
    func invalidatedDuringClosing() {
        let audit = makeAudit()
        sample(audit, 48.6)
        audit.finishSampling()
        delayedMove(audit)
        audit.invalidate("tap disabled during the closing")
        #expect(!audit.result().passed)
    }

    @Test("the mismatch report keeps the coordinates and times of nearby callbacks")
    func mismatchReportKeepsNeighbours() {
        let audit = makeAudit()
        sample(audit, 99)
        delayedMove(audit)
        let result = audit.result()
        #expect(result.mismatchDetails.count == 1)
        #expect(result.mismatchDetails[0].contains("HID[1] (48.60, 0.00)"))
        #expect(result.mismatchDetails[0].contains("event -1.000 ms, callback +1.000 ms"))
    }

    @Test("the observed sources are reported without allocating in the callback")
    func observedSourcesReported() {
        let audit = makeAudit()
        move(audit, 48.6, pid: 99)
        move(audit, 48.6, pid: 99)
        move(audit, 48.6, marker: 321)
        let sources = audit.result().observedSources
        #expect(sources == [
            "PID 99, state 1, marker zero",
            "PID 0, state 1, marker present"
        ])
    }
}
