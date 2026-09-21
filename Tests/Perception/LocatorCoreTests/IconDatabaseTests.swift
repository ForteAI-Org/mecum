import XCTest
import CoreGraphics
@testable import LocatorCore

final class IconDatabaseTests: XCTestCase {
    func testHammingDistanceOnHexHashes() {
        XCTAssertEqual(IconHash.distance("00", "00"), 0)
        XCTAssertEqual(IconHash.distance("0f", "00"), 4)     // nibble f = 1111 → 4 bits
        XCTAssertEqual(IconHash.distance("ff", "00"), 8)
        XCTAssertEqual(IconHash.distance(" abc", "abc"), Int.max)  // length mismatch → never a false "identical"
    }

    func testDedupMatchesNearDuplicateAppendsDistinct() {
        let t0 = Date(timeIntervalSince1970: 0)
        func icon(_ hash: String) -> IconRecord {
            IconRecord(id: UUID(), edgeHash: hash, cropRef: "x.png", sizePx: .init(width: 20, height: 20),
                       boundsNormalizedSample: [0, 0, 0.1, 0.1], firstSeen: t0, lastSeen: t0)
        }
        var app = AppIcons(bundleID: "com.x", appName: "X", icons: [icon("ff00ff00")])
        // A near-identical hash (1 nibble off → ≤8 bits) dedups to the existing icon.
        XCTAssertNotNil(app.matchIndex(edgeHash: "ff00ff0f", maxDistance: 8))
        // A very different hash is a new icon.
        XCTAssertNil(app.matchIndex(edgeHash: "00ff00ff", maxDistance: 8))

        // Labeled accounting.
        app.icons[0].label = "settings"
        XCTAssertEqual(app.labeledCount, 1)
        XCTAssertTrue(app.icons[0].isLabeled)
    }

    func testBestLabelPrefersNearestLabeledOverEarlierUnlabeled() {
        let t0 = Date(timeIntervalSince1970: 0)
        func icon(_ hash: String, label: String? = nil) -> IconRecord {
            var r = IconRecord(id: UUID(), edgeHash: hash, cropRef: "x.png", sizePx: .init(width: 20, height: 20),
                               boundsNormalizedSample: [0, 0, 0.1, 0.1], firstSeen: t0, lastSeen: t0)
            r.label = label
            return r
        }
        // The measured failure: an UNLABELED near-duplicate sits EARLIER in the array than the labeled
        // icon; first-match-any absorbed the match and the label never surfaced.
        let app = AppIcons(bundleID: "com.x", appName: "X", icons: [
            icon("ff00ff00"),                    // unlabeled sibling, distance 4 from the probe
            icon("ff00ff33", label: "call"),     // labeled, distance 4 too (nearest labeled)
            icon("00ff00ff", label: "settings"), // labeled but far
        ])
        XCTAssertEqual(app.bestLabel(edgeHash: "ff00ff03", maxDistance: 10), "call")
        // Out of range → nil (never a wrong guess).
        XCTAssertNil(app.bestLabel(edgeHash: "0000000000", maxDistance: 10))
        // Nothing labeled → nil even if unlabeled icons are close.
        let bare = AppIcons(bundleID: "com.x", appName: "X", icons: [icon("ff00ff00")])
        XCTAssertNil(bare.bestLabel(edgeHash: "ff00ff00", maxDistance: 10))
    }

    func testStoreRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = IconStore(directory: dir)
        let app = AppIcons(bundleID: "com.x", appName: "X", icons: [
            IconRecord(id: UUID(), edgeHash: "abcd", cropRef: "a.png", sizePx: .init(width: 16, height: 16),
                       boundsNormalizedSample: [0, 0, 0.1, 0.1], firstSeen: .init(timeIntervalSince1970: 0), lastSeen: .init(timeIntervalSince1970: 0))])
        try store.save(app)
        XCTAssertEqual(store.load(bundleID: "com.x"), app)
        XCTAssertEqual(try store.bundleIDs(), ["com.x"])
    }
}
