import XCTest
import Foundation
@testable import LocatorCore

final class KnowledgeBaseTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let t1 = Date(timeIntervalSince1970: 1_700_000_100)

    private func obj(_ key: String, _ text: String?, role: String? = "AXButton",
                     bounds: [Double] = [0.1, 0.2, 0.1, 0.05], source: ObjectSource = .ax) -> ObservedObject {
        ObservedObject(identityKey: key, selfText: text, role: role, source: source,
                       boundsNormalized: bounds, firstSeen: t0, lastSeen: t0)
    }

    // MARK: identity keys

    func testIdentityKeyPrefersIdentifierThenRoleText() {
        XCTAssertEqual(ObservedObject.makeIdentityKey(role: "AXButton", identifier: "export-btn", text: "Export", boundsNormalized: [0,0,0,0]), "id:export-btn")
        XCTAssertEqual(ObservedObject.makeIdentityKey(role: "AXButton", identifier: nil, text: "Export", boundsNormalized: [0,0,0,0]), "AXButton|export")
        // text-less (icon): falls back to a coarse position bucket, robust to sub-cell jitter
        let a = ObservedObject.makeIdentityKey(role: "AXImage", identifier: nil, text: nil, boundsNormalized: [0.123, 0.456, 0.02, 0.02])
        let b = ObservedObject.makeIdentityKey(role: "AXImage", identifier: nil, text: nil, boundsNormalized: [0.119, 0.451, 0.02, 0.02])
        XCTAssertEqual(a, b)                       // same 10×10 bucket
        XCTAssertEqual(a, "AXImage|@1,5")
    }

    // MARK: merge / dedup

    func testAffordanceRoundTripsAndMergeKeepsIt() throws {
        // Round-trips through the stable JSON encoder, and is absent (nil) in legacy JSON → additive field.
        var o = obj("AXButton|export", "Export")
        o.affordance = .link
        let data = try DescriptorStore.makeEncoder().encode(o)
        XCTAssertEqual(try DescriptorStore.makeDecoder().decode(ObservedObject.self, from: data).affordance, .link)

        // A later observation that learns the affordance backfills it onto the known object.
        var inv = WindowInventory(windowTitlePattern: "Edit", lastObserved: t0)
        inv.merge([obj("AXButton|export", "Export")], now: t0)
        XCTAssertNil(inv.objects.first?.affordance)
        var withAff = obj("AXButton|export", "Export"); withAff.affordance = .text
        inv.merge([withAff], now: t1)
        XCTAssertEqual(inv.objects.first { $0.identityKey == "AXButton|export" }?.affordance, .text)
    }

    func testMergeUpdatesKnownAndAppendsNew() {
        var inv = WindowInventory(windowTitlePattern: "Edit", lastObserved: t0)
        inv.merge([obj("AXButton|export", "Export"), obj("AXButton|cancel", "Cancel")], now: t0)
        XCTAssertEqual(inv.objects.count, 2)

        // Re-observe Export at a new position + see a new object → known one bumps count & moves, no dup.
        inv.merge([obj("AXButton|export", "Export", bounds: [0.5, 0.5, 0.1, 0.05]), obj("AXButton|ok", "OK")], now: t1)
        XCTAssertEqual(inv.objects.count, 3)
        let export = inv.objects.first { $0.identityKey == "AXButton|export" }!
        XCTAssertEqual(export.observationCount, 2)
        XCTAssertEqual(export.lastSeen, t1)
        XCTAssertEqual(export.boundsNormalized, [0.5, 0.5, 0.1, 0.05])   // latest position wins
        XCTAssertEqual(export.firstSeen, t0)                            // first-seen preserved
    }

    func testMergeFillsMissingTextFromLaterObservation() {
        var inv = WindowInventory(windowTitlePattern: "W", lastObserved: t0)
        inv.merge([obj("AXImage|@1,5", nil, role: "AXImage")], now: t0)   // icon, no text yet
        inv.merge([obj("AXImage|@1,5", "Save", role: "AXImage")], now: t1) // later OCR gave it text
        XCTAssertEqual(inv.objects.first?.selfText, "Save")
    }

    // MARK: candidate ranking

    func testCandidatesRankExactOverSubstringOverTokenOverlap() {
        var inv = WindowInventory(windowTitlePattern: "W", lastObserved: t0)
        inv.merge([
            obj("a", "Export Selected"),     // token overlap with "export"
            obj("b", "Export"),              // exact
            obj("c", "Re-Export As…"),       // substring contains "export"
            obj("d", "Cancel"),              // no match
        ], now: t0)
        let ranked = inv.candidates(for: "Export")
        XCTAssertEqual(ranked.first?.selfText, "Export")               // exact match ranks first
        XCTAssertEqual(ranked.count, 3)
        XCTAssertEqual(Set(ranked.compactMap(\.selfText)), ["Export", "Export Selected", "Re-Export As…"])
        XCTAssertFalse(ranked.contains { $0.selfText == "Cancel" })    // non-matches excluded
    }

    func testMatchScoreIsTokenBasedNotRawSubstring() {
        // The "Audio 25 → 5" bug: a lone digit must NOT match via normalized-concatenation substring.
        XCTAssertEqual(obj("x", "5").matchScore(query: "Audio 25"), 0)            // disjoint tokens → excluded
        XCTAssertEqual(obj("x", "Audio 25").matchScore(query: "Audio 25"), 3)     // exact
        XCTAssertEqual(obj("x", "Audio 2").matchScore(query: "Audio 25"), 0.5)    // {audio} of {audio,25}
        XCTAssertEqual(obj("x", "Re-Export As…").matchScore(query: "Export"), 2)  // query tokens ⊆ candidate
    }

    func testCandidatesTieBreakByObservationCount() {
        var inv = WindowInventory(windowTitlePattern: "W", lastObserved: t0)
        inv.merge([obj("x", "Save"), obj("y", "Save")], now: t0)
        inv.merge([obj("y", "Save")], now: t1)   // y seen twice
        let ranked = inv.candidates(for: "Save")
        XCTAssertEqual(ranked.first?.identityKey, "y")   // more-observed wins the tie
    }

    // MARK: AppKnowledge

    func testObserveRoutesToWindowAndCountsObjects() {
        var app = AppKnowledge(bundleID: "com.x")
        app.observe(windowTitlePattern: "Main", objects: [obj("a", "A"), obj("b", "B")], now: t0)
        app.observe(windowTitlePattern: "Prefs", objects: [obj("c", "C")], now: t0)
        app.observe(windowTitlePattern: "Main", objects: [obj("a", "A")], now: t1)   // re-observe Main
        XCTAssertEqual(app.windows.count, 2)
        XCTAssertEqual(app.objectCount, 3)
    }

    // MARK: state fingerprint (P2b)

    func testStateFingerprintStableAcrossScrollAndMeters() {
        // Two captures of the SAME Pro Tools state at different scroll positions + a ticking timecode.
        let top = StateFingerprint.make(title: "Edit: GAME • v4", objects: [
            obj("a", "Audio 1", role: nil), obj("b", "Audio 2", role: nil), obj("c", "wave", role: nil),
            obj("d", "00:00:14:11", role: nil), obj("e", "Bus 1-2", role: nil)])
        let scrolled = StateFingerprint.make(title: "Edit: GAME • v5", objects: [   // version digit changed + scrolled
            obj("a", "Audio 27", role: nil), obj("b", "Audio 28", role: nil), obj("c", "wave", role: nil),
            obj("d", "00:01:59:02", role: nil), obj("e", "Bus 1-2", role: nil)])
        XCTAssertTrue(top.matches(scrolled))   // numeric-stripped labels {audio,wave,bus} + role mix are identical
    }

    func testStateFingerprintDistinguishesDifferentStates() {
        let edit = StateFingerprint.make(title: "Edit", objects: [
            obj("a", "Audio 1", role: "AXButton"), obj("b", "wave", role: "AXButton"), obj("c", "Bus 1-2", role: "AXButton")])
        let prefs = StateFingerprint.make(title: "Playback Engine", objects: [
            obj("a", "Sample Rate", role: "AXPopUpButton"), obj("b", "Buffer Size", role: "AXPopUpButton"), obj("c", "OK", role: "AXButton")])
        XCTAssertFalse(edit.matches(prefs))    // different title family + labels + structure
    }

    func testObserveMergesSameStateAcrossScroll() {
        var app = AppKnowledge(bundleID: "com.avid.ProTools")
        let fpA = StateFingerprint.make(title: "Edit", objects: [obj("a", "Audio 1", role: nil), obj("w", "wave", role: nil)])
        let fpB = StateFingerprint.make(title: "Edit", objects: [obj("a", "Audio 9", role: nil), obj("w", "wave", role: nil)])
        app.observe(windowTitlePattern: "Edit", objects: [obj("a", "Audio 1")], now: t0, fingerprint: fpA)
        app.observe(windowTitlePattern: "Edit", objects: [obj("z", "Audio 9")], now: t1, fingerprint: fpB)
        XCTAssertEqual(app.windows.count, 1)   // same state → one node, not forked by scroll
        XCTAssertEqual(app.objectCount, 2)
    }

    // MARK: store round-trip + default-deny allowlist

    func testStoreRoundTripAndBundleListing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kb-\(UUID())")
        let store = KnowledgeStore(directory: dir)
        XCTAssertNil(try store.load(bundleID: "com.x"))   // absent → nil, not an error
        var app = AppKnowledge(bundleID: "com.avid.ProTools")
        app.observe(windowTitlePattern: "Edit", objects: [obj("a", "Audio 3"), obj("b", "Audio 4")], now: t0)
        try store.save(app)
        XCTAssertEqual(try store.load(bundleID: "com.avid.ProTools"), app)   // exact round-trip
        XCTAssertEqual(try store.bundleIDs(), ["com.avid.ProTools"])
    }

    func testAllowlistDefaultsAllowAllAndRestrictIsPerApp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kb-\(UUID())")
        let store = AllowlistStore(directory: dir)
        // Default (no file): every app allowed — the frictionless default.
        XCTAssertTrue(store.load().allows("com.avid.ProTools"))
        XCTAssertTrue(store.load().allowsActive("com.apple.Safari"))
        // `kb restrict` (allowAll=false) → back to per-app opt-in.
        try store.save(Allowlist(bundleIDs: ["com.avid.ProTools"], allowAll: false))
        XCTAssertTrue(store.load().allows("com.avid.ProTools"))
        XCTAssertFalse(store.load().allows("com.apple.Safari"))
        XCTAssertFalse(store.load().allowsActive("com.avid.ProTools"))   // observe ≠ act
    }
}
