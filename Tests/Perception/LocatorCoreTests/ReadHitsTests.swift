import XCTest
@testable import LocatorCore

/// READ-HIT ACCOUNTING (ticket 02). Every store counts its WRITES today — 16,452 sightings, 197
/// experiences — and nothing counted its READS, so "45% of sightings are re-confirmed" could never
/// become "N were consulted, M changed an outcome" and every prune-or-keep argument stayed taste.
///
/// What these tests assert is the EXTERNAL number a reader of the memory view sees: consulted, useful,
/// per store, per app — never which branch inside a read method ran. The gate is asserted too, because
/// a counter that cannot be switched off would be a permanent tax on the scene path.
final class ReadHitsTests: XCTestCase {
    private func countingMemory() -> LocatorMemory {
        LocatorMemory(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("readhits-\(UUID().uuidString)", isDirectory: true),
                      countReads: true)
    }

    private func silentMemory() -> LocatorMemory {
        LocatorMemory(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("readhits-off-\(UUID().uuidString)", isDirectory: true),
                      countReads: false)
    }

    private func hit(_ m: LocatorMemory, _ store: MemoryStore, app: String) -> ReadHit? {
        m.readHits().first { $0.store == store.rawValue && $0.app == app }
    }

    // MARK: the two numbers

    func testAConsultedReadIsCountedForItsStoreAndApp() {
        let m = countingMemory()
        m.recordSightings(app: "slack", items: [("Fritz", "sidebar", 0.1, 0.2)])
        _ = m.sighting(app: "slack", target: "fritz")
        m.flushReadHits()

        let h = hit(m, .sighting, app: "slack")
        XCTAssertEqual(h?.consulted, 1)
        XCTAssertEqual(h?.useful, 0, "consulting is not using — nothing said this answer changed anything")
    }

    /// The distinction the whole ticket exists for: a read that was consulted but changed nothing is
    /// evidence AGAINST keeping the row, and it must not be reported as a hit.
    func testUsefulIsCountedSeparatelyAndOnlyWhenClaimed() {
        let m = countingMemory()
        m.recordSightings(app: "slack", items: [("Fritz", "sidebar", 0.1, 0.2)])
        _ = m.sighting(app: "slack", target: "fritz")
        _ = m.sighting(app: "slack", target: "fritz")
        m.noteUsefulRead(.sighting, app: "slack")
        m.flushReadHits()

        let h = hit(m, .sighting, app: "slack")
        XCTAssertEqual(h?.consulted, 2)
        XCTAssertEqual(h?.useful, 1, "one of the two consultations was claimed as decisive")
    }

    /// A read that finds NOTHING is still a consultation — the question was asked and the memory had no
    /// answer, which is exactly the ratio an "is this store worth keeping?" argument needs.
    func testAMissIsStillAConsultation() {
        let m = countingMemory()
        XCTAssertNil(m.sighting(app: "slack", target: "nobodyhere"))
        m.flushReadHits()
        XCTAssertEqual(hit(m, .sighting, app: "slack")?.consulted, 1)
    }

    func testCountsAreScopedPerApp() {
        let m = countingMemory()
        _ = m.paneScrollable(app: "resolve", role: "content")
        _ = m.paneScrollable(app: "slack", role: "sidebar")
        _ = m.paneScrollable(app: "slack", role: "sidebar")
        m.flushReadHits()

        XCTAssertEqual(hit(m, .scrollPane, app: "resolve")?.consulted, 1)
        XCTAssertEqual(hit(m, .scrollPane, app: "slack")?.consulted, 2)
    }

    // MARK: every read path on every memory

    /// The ticket's first box: EVERY read path increments a consulted counter. Called through the public
    /// API exactly as production does, so a read path that forgets to count fails here.
    func testEveryReadPathCountsItsOwnStore() {
        let m = countingMemory()
        let app = "com.test.readpaths"

        _ = m.sighting(app: app, target: "anything")                                  // sighting
        _ = m.graphContext()                                                          // sighting (all apps)
        _ = m.memberSeed(app: app, target: "anything", visibleCores: ["other"])       // section_member
        _ = m.rowPitch(app: app, family: "sidebar")                                   // section_list
        _ = m.paneScrollable(app: app, role: "content")                               // scroll_pane
        _ = m.panePxPerTick(app: app, role: "content")                                // scroll_pane
        _ = m.paneNoopDirections(app: app, role: "content", axis: "h")                // scroll_pane
        _ = m.wheelPolarity(app: app, axis: "v")                                      // wheel_polarity
        _ = m.wheelPolarityAsked(app: app, axis: "v")                                  // wheel_polarity
        _ = m.recentExperiences()                                                     // experience
        _ = m.recentTimeline(limit: 5)                                                // interaction
        _ = m.activityEvents(sinceHours: 1)                                           // interaction
        // The BRAIN is the one memory that is not a locator.db table (per-app JSON, 10,340 anchors), so
        // its read path books through the public consult API instead of counting itself.
        _ = UIBrain().enrich([], app: app, memory: m)                                 // brain
        m.flushReadHits()

        let byStore = Dictionary(grouping: m.readHits(), by: \.store)
            .mapValues { $0.reduce(0) { $0 + $1.consulted } }
        for store in MemoryStore.allCases {
            XCTAssertGreaterThanOrEqual(byStore[store.rawValue] ?? 0, 1,
                                        "no read path counted a consultation for \(store.rawValue)")
        }
        // The app-scoped stores report the app they were asked about, not a lump total.
        XCTAssertEqual(hit(m, .scrollPane, app: app)?.consulted, 3)
        XCTAssertEqual(hit(m, .wheelPolarity, app: app)?.consulted, 2)
    }

    // MARK: the gate

    /// Counting is behind the env-gated telemetry pattern (`LOCATOR_READ_HITS`), and OFF must mean off:
    /// no ledger rows, so no writes on the scene path either.
    func testWithTheGateOffNothingIsCounted() {
        let m = silentMemory()
        m.recordSightings(app: "slack", items: [("Fritz", "sidebar", 0.1, 0.2)])
        _ = m.sighting(app: "slack", target: "fritz")
        _ = m.paneScrollable(app: "slack", role: "sidebar")
        m.noteUsefulRead(.sighting, app: "slack")
        m.flushReadHits()

        XCTAssertFalse(m.readHitsEnabled)
        XCTAssertTrue(m.readHits().isEmpty, "the gate is off — the ledger must stay empty")
    }

    /// The env var is what a deployed engine is switched with, and the constructor argument is what a
    /// test uses; both must reach the same decision.
    func testTheGateReadsTheEnvironmentWhenNotInjected() {
        XCTAssertTrue(LocatorMemory.readHitsGateOn(env: ["LOCATOR_READ_HITS": "1"], injected: nil))
        XCTAssertTrue(LocatorMemory.readHitsGateOn(env: [:], injected: nil), "ON by default since 2026-09-06")
        XCTAssertFalse(LocatorMemory.readHitsGateOn(env: ["LOCATOR_READ_HITS": "0"], injected: nil), "0 switches it off")
        XCTAssertTrue(LocatorMemory.readHitsGateOn(env: [:], injected: true))
        XCTAssertFalse(LocatorMemory.readHitsGateOn(env: ["LOCATOR_READ_HITS": "1"], injected: false))
    }

    // MARK: the visualiser's data source

    func testTheSnapshotTheMemoryViewReadsCarriesBothNumbers() throws {
        let m = countingMemory()
        _ = m.paneScrollable(app: "resolve", role: "content")
        m.noteUsefulRead(.scrollPane, app: "resolve")
        m.flushReadHits()

        let json = try XCTUnwrap(m.snapshotJSON().data(using: .utf8))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let rows = try XCTUnwrap(obj["readHits"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first { ($0["store"] as? String) == "scroll_pane" })
        XCTAssertEqual(row["app"] as? String, "resolve")
        XCTAssertEqual(row["consulted"] as? Int, 1)
        XCTAssertEqual(row["useful"] as? Int, 1)
    }

    /// The dashboard reads the ledger every 3 seconds. If that read counted, the page would inflate the
    /// very number it displays — a measurement instrument that reports its own weight.
    func testReadingTheDashboardDoesNotCountAsAConsultation() {
        let m = countingMemory()
        _ = m.paneScrollable(app: "resolve", role: "content")
        m.flushReadHits()
        let before = hit(m, .scrollPane, app: "resolve")?.consulted

        for _ in 0..<5 { _ = m.snapshotJSON() }
        _ = m.readHits()
        m.flushReadHits()

        XCTAssertEqual(hit(m, .scrollPane, app: "resolve")?.consulted, before)
        XCTAssertEqual(m.readHits().count, 1, "no store gained a row from the dashboard looking at it")
    }

    // MARK: the buffer (why the scene path pays no write per read)

    /// Reads are aggregated in memory and flushed on a cadence — a reach makes ~30 consultations and
    /// must not turn them into 30 WAL commits. The cadence is the ledger's own decision, tested here
    /// without a database in the way.
    func testTheLedgerBatchesUntilItsIntervalElapses() {
        let ledger = ReadHitLedger(on: true, interval: 60)
        XCTAssertNil(ledger.note(store: .sighting, app: "slack", useful: false),
                     "nothing to write yet — the interval has not elapsed")
        XCTAssertNil(ledger.note(store: .sighting, app: "slack", useful: false))
        XCTAssertNil(ledger.note(store: .sighting, app: "slack", useful: true))
        let batch = ledger.drain()
        XCTAssertEqual(batch.count, 1, "one row per (store, app), not one per read")
        XCTAssertEqual(batch.first?.consulted, 2)
        XCTAssertEqual(batch.first?.useful, 1)
        XCTAssertTrue(ledger.drain().isEmpty, "a drained delta is never written twice")
    }

    func testTheLedgerHandsOverABatchOnceItsIntervalHasElapsed() {
        let ledger = ReadHitLedger(on: true, interval: 0)
        let batch = ledger.note(store: .experience, app: nil, useful: false)
        XCTAssertEqual(batch?.count, 1)
        XCTAssertEqual(batch?.first?.app, LocatorMemory.anyApp, "an unscoped read is booked to the machine row")
        XCTAssertTrue(ledger.drain().isEmpty, "the handed-over batch left the buffer")
    }

    func testTheLedgerCountsNothingWhenOff() {
        let ledger = ReadHitLedger(on: false, interval: 0)
        XCTAssertNil(ledger.note(store: .sighting, app: "slack", useful: false))
        XCTAssertTrue(ledger.drain().isEmpty)
    }
}

/// The MARK SITES — where a consumer claims a consultation changed what the engine did. These assert the
/// external number ("did this store earn a hit?"), never which branch produced it, and they are the tests
/// that keep `useful` from drifting back into "the memory answered", which is what `consulted` already
/// says.
final class ReadHitMarkSiteTests: XCTestCase {
    private func countingMemory() -> LocatorMemory {
        LocatorMemory(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("readhits-mark-\(UUID().uuidString)", isDirectory: true),
                      countReads: true)
    }

    private func hit(_ m: LocatorMemory, _ store: MemoryStore, app: String) -> ReadHit? {
        m.flushReadHits()
        return m.readHits().first { $0.store == store.rawValue && $0.app == app }
    }

    /// A remembered sign that DISAGREES with the assumed default changes every event the burst posts.
    func testARememberedWheelSignThatChangesTheBurstIsAHit() {
        let m = countingMemory()
        m.recordWheelPolarity(app: "resolve", axis: "v", upSign: -WheelPolarity.assumedUpSign)
        XCTAssertEqual(WheelPolarity.upSign(app: "resolve", memory: m), -WheelPolarity.assumedUpSign)
        XCTAssertEqual(hit(m, .wheelPolarity, app: "resolve")?.useful, 1)
    }

    /// A remembered sign that AGREES with the default posts byte-identical events — consulted, not used.
    func testARememberedWheelSignThatAgreesWithTheDefaultIsNotAHit() {
        let m = countingMemory()
        m.recordWheelPolarity(app: "slack", axis: "v", upSign: WheelPolarity.assumedUpSign)
        XCTAssertEqual(WheelPolarity.upSign(app: "slack", memory: m), WheelPolarity.assumedUpSign)
        let h = hit(m, .wheelPolarity, app: "slack")
        XCTAssertGreaterThanOrEqual(h?.consulted ?? 0, 1)
        XCTAssertEqual(h?.useful, 0, "agreeing with the default is not changing an outcome")
    }

    /// Remembering that the question was already ASKED skips a deliberate nudge and the scene build that
    /// reads it — the biggest single saving in this ledger.
    func testRememberingThatTheWheelWasAlreadyMeasuredIsAHit() {
        let m = countingMemory()
        m.recordWheelPolarityUnreadable(app: "premiere", axis: "v")
        XCTAssertTrue(WheelPolarity.isKnown(app: "premiere", memory: m))
        XCTAssertEqual(hit(m, .wheelPolarity, app: "premiere")?.useful, 1)
    }

    func testNeverHavingMeasuredTheWheelIsAConsultationAndNothingMore() {
        let m = countingMemory()
        XCTAssertFalse(WheelPolarity.isKnown(app: "nothing.known", memory: m))
        let h = hit(m, .wheelPolarity, app: "nothing.known")
        XCTAssertEqual(h?.consulted, 1)
        XCTAssertEqual(h?.useful, 0)
    }
}

/// The BRAIN's read hits — the largest store (10,340 anchors, 20% named, zero deliberately named) and
/// the one whose payoff the audit could not measure at all. A consultation is one `enrich` (one scene),
/// and it is useful only when the brain changed the scene the agent reads.
final class BrainReadHitTests: XCTestCase {
    private func countingMemory() -> LocatorMemory {
        LocatorMemory(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("readhits-brain-\(UUID().uuidString)", isDirectory: true),
                      countReads: true)
    }

    private func hit(_ m: LocatorMemory, app: String) -> ReadHit? {
        m.flushReadHits()
        return m.readHits().first { $0.store == MemoryStore.brain.rawValue && $0.app == app }
    }

    private let app = "com.test.brain"

    private func unlabeledControl() -> SceneElement {
        SceneElement(id: "ctl", kind: "control", label: "(unlabeled)",
                     pos: [0.2, 0.3, 0.04, 0.02], state: nil, unlabeled: true)
    }

    /// A remembered NAME on an anonymous control is the brain's headline contribution: the element goes
    /// from "(unlabeled)" to addressable, which is a different scene than perception alone produced.
    func testARecalledNameIsABrainReadThatChangedTheScene() {
        let m = countingMemory()
        let el = unlabeledControl()
        // labelSource "llm" is what lets a DELIBERATE name hold its position claim over an anonymous
        // detection — the naming ledger's whole point, and the channel the audit found never used.
        let anchor = UIObjectAnchor(anchorKey: "a1", kind: "control", label: "Mute", labelSource: "llm",
                                    boundsTypical: el.pos, seenCount: 4,
                                    firstSeen: Date(timeIntervalSince1970: 1), lastSeen: Date(timeIntervalSince1970: 2))
        let brain = UIBrain(objects: [anchor])

        let out = brain.enrich([el], app: app, memory: m)
        XCTAssertEqual(out.first?.label, "Mute")
        XCTAssertEqual(out.first?.recalled, true)
        let h = hit(m, app: app)
        XCTAssertEqual(h?.consulted, 1, "one scene, one consultation — not one per element")
        XCTAssertEqual(h?.useful, 1)
    }

    func testABrainWithNothingToSayIsConsultedAndNothingMore() {
        let m = countingMemory()
        let out = UIBrain().enrich([unlabeledControl()], app: app, memory: m)
        XCTAssertEqual(out.first?.label, "(unlabeled)")
        let h = hit(m, app: app)
        XCTAssertEqual(h?.consulted, 1)
        XCTAssertEqual(h?.useful, 0)
    }

    /// The offline caller (a fixture pipeline, a unit test) enriches without naming an app, and
    /// must leave the ledger alone.
    func testEnrichingWithoutNamingAnAppCountsNothing() {
        let m = countingMemory()
        _ = UIBrain().enrich([unlabeledControl()], memory: m)
        m.flushReadHits()
        XCTAssertTrue(m.readHits().isEmpty)
    }
}
