import XCTest
@testable import LocatorCore

/// Issue 16. The two refusals are the feature; the diff is the same-day judgment ticket 02 asks for.
final class HarnessReportTests: XCTestCase {

    private func stamp(binary: Date, sources: Date?) -> HarnessReport.BinaryStamp {
        .init(sha256: "abc123", mtime: binary, sourcesNewest: sources)
    }
    private func report(plane: HarnessReport.Plane = .replay, perturbed: Bool = false,
                        binary: Date = Date(timeIntervalSince1970: 2_000), sources: Date? = Date(timeIntervalSince1970: 1_000),
                        metrics: [String: HarnessReport.Metric] = [:], sha: String = "abc123") -> HarnessReport {
        .init(plane: plane, takes: ["t1"],
              binary: .init(sha256: sha, mtime: binary, sourcesNewest: sources),
              perturbed: perturbed, metrics: metrics)
    }
    private func ms(_ p95: Double, n: Int = 100) -> HarnessReport.Metric {
        .init(p50: p95 * 0.6, p95: p95, unit: "ms", n: n)
    }

    // MARK: STALE

    func testSourcesNewerThanTheBinaryIsStale() {
        XCTAssertTrue(stamp(binary: Date(timeIntervalSince1970: 1_000),
                            sources: Date(timeIntervalSince1970: 2_000)).isStale)
        XCTAssertFalse(stamp(binary: Date(timeIntervalSince1970: 2_000),
                             sources: Date(timeIntervalSince1970: 1_000)).isStale)
    }

    func testOutsideACheckoutNothingIsStale() {
        // No Sources/ to compare against is not evidence of staleness — it is absence of evidence.
        XCTAssertFalse(stamp(binary: Date(), sources: nil).isStale)
    }

    func testAStaleReportIsRefusedAsABaselineAndSaysWhy() throws {
        let r = report(binary: Date(timeIntervalSince1970: 1_000), sources: Date(timeIntervalSince1970: 2_000))
        let refusal = try XCTUnwrap(r.baselineRefusal)
        XCTAssertTrue(refusal.contains("STALE"), refusal)
    }

    // MARK: PERTURBED (ADR 0010)

    func testAPerturbedTakeIsRefusedEntryToABaselineAndNamesTheReason() {
        let refusal = try? XCTUnwrap(report(perturbed: true).baselineRefusal)
        XCTAssertNotNil(refusal)
        XCTAssertTrue(refusal!.contains("perturbed"), refusal!)
        XCTAssertTrue(refusal!.contains("--film"), "the refusal must name what caused it: \(refusal!)")
    }

    func testPerturbedOutranksEverythingElse() {
        // A perturbed take that is ALSO fresh is still refused — the reason is the recording, not the age.
        let r = report(perturbed: true, binary: Date(timeIntervalSince1970: 9_000), sources: Date(timeIntervalSince1970: 1))
        XCTAssertTrue(r.baselineRefusal?.contains("perturbed") == true)
    }

    func testALiveProbeIsNeverAGate() {
        // ADR 0011: the probe is a milestone measurement. Fresh, unperturbed, and still refused.
        let refusal = report(plane: .probe).baselineRefusal
        XCTAssertTrue(refusal?.contains("milestone") == true, refusal ?? "nil")
    }

    func testACleanReplayReportIsAdmitted() {
        XCTAssertNil(report(plane: .replay).baselineRefusal)
    }

    // MARK: the diff

    func testTwoReportsDiffIntoMovedNumbers() {
        let before = report(metrics: ["ocr_ms": ms(100), "segment_ms": ms(45), "section_ms": ms(22)], sha: "old")
        let after  = report(metrics: ["ocr_ms": ms(150), "segment_ms": ms(45), "section_ms": ms(20)], sha: "new")
        let d = ReportDiff.between(before, after)

        let moved = d.moved(threshold: 10)   // section_ms 22→20 is a real 9% move; only ocr clears 10%
        XCTAssertEqual(moved.map(\.metric), ["ocr_ms"], "only ocr moved more than 10%")
        let ocr = try? XCTUnwrap(moved.first)
        XCTAssertEqual(ocr?.delta, 50)
        XCTAssertEqual(ocr?.pctChange ?? 0, 50, accuracy: 0.001)
        XCTAssertTrue(d.markdownTable().contains("ocr_ms"))
    }

    func testTheDiffComparesP95BecauseThatIsTheGatesShape() {
        let m = HarnessReport.Metric(value: 1, p50: 2, p95: 3, unit: "ms", n: 10)
        XCTAssertEqual(m.headline, 3)
        XCTAssertEqual(HarnessReport.Metric(value: 7, unit: "share", n: 10).headline, 7)
    }

    func testAMetricPresentInOnlyOneReportIsAlwaysNews() {
        let before = report(metrics: ["ocr_ms": ms(100)])
        let after  = report(metrics: ["ocr_ms": ms(100), "brain_enrich_ms": ms(12)])
        let rows = ReportDiff.between(before, after).moved(threshold: 1000)
        XCTAssertEqual(rows.map(\.metric), ["brain_enrich_ms"],
                       "a metric that appeared survives any threshold — it has no percentage to compare")
    }

    func testTheDiffCarriesSampleSizes() {
        let before = report(metrics: ["ocr_ms": ms(100, n: 3)])
        let after  = report(metrics: ["ocr_ms": ms(200, n: 400)])
        let row = try? XCTUnwrap(ReportDiff.between(before, after).moved().first)
        XCTAssertEqual(row?.nBefore, 3)
        XCTAssertEqual(row?.nAfter, 400)
        XCTAssertTrue(ReportDiff.between(before, after).markdownTable().contains("3→400"))
    }

    func testDiffingAcrossPlanesIsFlagged() {
        let d = ReportDiff.between(report(plane: .replay), report(plane: .probe))
        XCTAssertTrue(d.notes.contains { $0.contains("planes differ") })
    }

    func testTheSameBinaryIsFlaggedSoMovementIsNotBlamedOnCode() {
        let d = ReportDiff.between(report(sha: "same"), report(sha: "same"))
        XCTAssertTrue(d.notes.contains { $0.contains("same binary sha") })
    }

    func testARefusedReportPoisonsTheDiffVisibly() {
        let d = ReportDiff.between(report(), report(perturbed: true))
        XCTAssertTrue(d.notes.contains { $0.hasPrefix("after:") && $0.contains("perturbed") })
    }

    // MARK: round trip

    func testAReportRoundTripsThroughJSON() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("2026-09-11-replay.json")
        let r = report(metrics: ["rounds_per_task": .init(value: 4.5, unit: "rounds", n: 5)])
        try r.write(to: url)
        let once = try HarnessReport.read(url)
        try once.write(to: url)
        XCTAssertEqual(try HarnessReport.read(url), once, "a report must be a fixed point of read→write")
        XCTAssertEqual(once.metrics, r.metrics)
        try? FileManager.default.removeItem(at: dir)
    }
}
