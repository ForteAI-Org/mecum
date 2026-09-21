import XCTest
@testable import LocatorCore

/// WHERE THE LIVING MEMORY LIVES is a decision, so it gets tests. The reason it needs them: 1,175 of
/// 4,221 rows in the operator's live interaction ledger were unit-test fixtures (`com.x` / `btn4` /
/// `ts = 0`) — 28% of the table — because a test can write into `LocatorMemory.shared` without ever
/// naming it. Everything measured on that machine was measured through fixture noise.
final class MemoryStorePathTests: XCTestCase {
    private let appSupport = URL(fileURLWithPath: "/Users/nobody/Library/Application Support", isDirectory: true)

    /// The default must stay EXACTLY where it is today: moving the live store would orphan 16,470
    /// sightings, 197 experiences and the whole interaction spine.
    func testTheDefaultIsStillApplicationSupportLocator() {
        let dir = LocatorMemory.resolveDirectory(env: [:], underTest: false, appSupport: appSupport)
        XCTAssertEqual(dir?.standardizedFileURL.path,
                       appSupport.appendingPathComponent("Locator").standardizedFileURL.path)
    }

    /// A pinned path wins over both — how a DEPLOYED binary is pointed at a scratch store, so manual
    /// testing does not have to pollute the real memory either.
    func testAPinnedPathWinsOverTheDefault() {
        let dir = LocatorMemory.resolveDirectory(env: ["LOCATOR_MEMORY_DIR": "/tmp/scratch-store"],
                                                 underTest: false, appSupport: appSupport)
        XCTAssertEqual(dir?.path, "/tmp/scratch-store")
    }

    /// An unexpanded manifest token (`${HOME}/…`) is not a path — reject it and fall back, the same rule
    /// `DescriptorPaths.iconsDir` learned under Claude Desktop.
    func testAnUnexpandedTokenIsIgnoredRatherThanUsedAsAPath() {
        let dir = LocatorMemory.resolveDirectory(env: ["LOCATOR_MEMORY_DIR": "${HOME}/Locator"],
                                                 underTest: false, appSupport: appSupport)
        XCTAssertEqual(dir?.standardizedFileURL.path,
                       appSupport.appendingPathComponent("Locator").standardizedFileURL.path)
    }

    /// Under XCTest the default is never the live store. Constructor injection already existed and most
    /// tests use it; this catches the write a test does not know it is making.
    func testUnderTestTheDefaultIsNeverTheLiveStore() {
        let dir = LocatorMemory.resolveDirectory(env: [:], underTest: true, appSupport: appSupport)
        XCTAssertNotNil(dir)
        XCTAssertFalse(dir!.path.hasPrefix(appSupport.path), "a test run must not resolve into the live store")
    }

    /// THE TRIPWIRE, checked against this very process: whatever else this suite does, the process-wide
    /// store it can reach is not the operator's. If this fails, the pollution is back.
    func testThisTestProcessCannotReachTheOperatorsStore() throws {
        let live = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: false)
            .appendingPathComponent("Locator", isDirectory: true)
        let mine = try XCTUnwrap(LocatorMemory.shared.directory)
        XCTAssertNotEqual(mine.standardizedFileURL.path, live.standardizedFileURL.path)
    }

    /// And a write through it lands in the temp store, not merely "somewhere else" — the ledger has to
    /// still work for the tests that legitimately read back through `.shared`.
    func testAWriteThroughTheProcessWideStoreLandsInTheTempStore() throws {
        LocatorMemory.shared.recordInteraction(app: "com.x.tripwire", kind: "scroll", section: nil, detail: nil)
        let db = try XCTUnwrap(LocatorMemory.shared.directory).appendingPathComponent("locator.db")
        XCTAssertTrue(FileManager.default.fileExists(atPath: db.path))
        XCTAssertTrue(LocatorMemory.shared.recentTimeline(limit: 50).contains { $0.contains("com.x.tripwire") })
    }
}
