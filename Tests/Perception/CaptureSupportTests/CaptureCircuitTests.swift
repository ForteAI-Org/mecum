import XCTest
import Foundation
@testable import CaptureSupport

/// The capture circuit breaker: after N consecutive failures it opens (fast-fail, so a wedged/denied
/// ScreenCaptureKit stops spawning orphaned tasks + leaked continuations in the long-lived engine),
/// then a single half-open probe tests recovery, and a success closes it.
final class CaptureCircuitTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func mkCircuit(trip: Int = 3, cooldown: TimeInterval = 30, file: String? = nil) -> CaptureGate.Circuit {
        CaptureGate.Circuit(trip: trip, cooldown: cooldown,
                            breakerFile: file ?? (NSTemporaryDirectory() + "brk-\(UUID().uuidString)"))
    }

    func testClosedWhileFailuresBelowTrip() {
        let c = mkCircuit()
        XCTAssertTrue(c.allow(now: t0))
        c.record(success: false, now: t0)      // 1
        c.record(success: false, now: t0)      // 2
        XCTAssertTrue(c.allow(now: t0), "still closed below the trip count")
    }

    func testOpensOnTripAndFastFailsDuringCooldown() {
        let c = mkCircuit()
        for _ in 0..<3 { c.record(success: false, now: t0) }   // trip
        XCTAssertFalse(c.allow(now: t0.addingTimeInterval(1)), "open → no attempt (no new op task/leak)")
        XCTAssertFalse(c.allow(now: t0.addingTimeInterval(29)), "still open before cooldown elapses")
    }

    func testHalfOpenProbeReopensImmediatelyOnFailure() {
        let c = mkCircuit()
        for _ in 0..<3 { c.record(success: false, now: t0) }
        let after = t0.addingTimeInterval(31)
        XCTAssertTrue(c.allow(now: after), "cooldown elapsed → half-open probe permitted")
        // A single failed probe re-opens instantly (streak was never reset) — under serialized capture
        // that means one probe per cooldown, so orphans accrue at ~1/cooldown, not ~1/timeout.
        c.record(success: false, now: after)
        XCTAssertFalse(c.allow(now: after.addingTimeInterval(1)), "re-opened after the failed probe")
        XCTAssertFalse(c.allow(now: after.addingTimeInterval(29)), "and stays open for another cooldown")
    }

    func testSuccessClosesAndResets() {
        let c = mkCircuit()
        for _ in 0..<3 { c.record(success: false, now: t0) }
        let after = t0.addingTimeInterval(31)
        XCTAssertTrue(c.allow(now: after))                   // half-open probe
        c.record(success: true, now: after)                 // probe succeeded → closed
        XCTAssertTrue(c.allow(now: after), "closed — normal operation resumes")
        // and the failure count reset: two fresh failures don't re-trip
        c.record(success: false, now: after); c.record(success: false, now: after)
        XCTAssertTrue(c.allow(now: after), "counter reset by the success; below trip again")
    }

    func testInterleavedSuccessKeepsItClosed() {
        let c = mkCircuit()
        c.record(success: false, now: t0)
        c.record(success: false, now: t0)
        c.record(success: true, now: t0)     // resets the streak
        c.record(success: false, now: t0)
        c.record(success: false, now: t0)
        XCTAssertTrue(c.allow(now: t0), "no 3 consecutive failures → never opened")
    }
    func testOpenStateIsSharedAcrossCircuitsViaFile() {
        // Two circuits sharing the breaker file model two engine processes: when ONE trips the breaker,
        // the OTHER must also fast-fail (so a fleet of engines doesn't keep re-hammering a wedged replayd).
        let shared = NSTemporaryDirectory() + "brk-shared-\(UUID().uuidString)"
        let engineA = mkCircuit(file: shared)
        let engineB = mkCircuit(file: shared)
        for _ in 0..<3 { engineA.record(success: false, now: t0) }   // A trips
        XCTAssertFalse(engineB.allow(now: t0.addingTimeInterval(1)), "B backs off too — shared open state")
        engineA.record(success: true, now: t0.addingTimeInterval(40)) // A recovers (after cooldown/probe)
        XCTAssertTrue(engineB.allow(now: t0.addingTimeInterval(41)), "B resumes once the fleet is healthy")
    }
}
