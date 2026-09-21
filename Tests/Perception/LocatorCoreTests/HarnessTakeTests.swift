import XCTest
@testable import LocatorCore

/// Issue 02. A take round-trips, and the refusals fire BEFORE anything is written — a half-written
/// take of a refused app is still a recording of it.
final class HarnessTakeTests: XCTestCase {

    private var tmp: URL!
    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private var stamp: HarnessReport.BinaryStamp {
        .init(sha256: "deadbeef", mtime: Date(timeIntervalSince1970: 1000), sourcesNewest: nil)
    }
    private func make(_ mode: TakeManifest.Mode = .trace,
                      apps: [(name: String, bundleID: String?, watched: Bool)] = [("Pro Tools", "com.avid.ProTools", true)]) throws -> TakeStore {
        try TakeStore.create(flow: "pt-import", mode: mode, binary: stamp, apps: apps, root: tmp)
    }

    // MARK: round trip

    func testATakeRoundTrips() throws {
        let store = try make()
        let reopened = try TakeStore.open(store.root)
        try reopened.writeManifest()
        XCTAssertEqual(try TakeStore.open(store.root).manifest, reopened.manifest,
                       "a manifest must be a fixed point of read→write")
        XCTAssertEqual(reopened.manifest.takeID, store.manifest.takeID)
        XCTAssertEqual(reopened.manifest.flow, "pt-import")
        XCTAssertEqual(reopened.manifest.appsPresent, ["Pro Tools"])
        XCTAssertEqual(reopened.manifest.redactionVersion, TakeManifest.currentRedactionVersion)
    }

    func testTheDirectoriesTheStreamsNeedExist() throws {
        let store = try make()
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.keysDir.path, isDirectory: &isDir) && isDir.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.brainDir.path, isDirectory: &isDir) && isDir.boolValue)
    }

    func testFilmModeStampsPerturbed() throws {
        // ADR 0010: --film changes the cost profile it measures, so the take must announce it and the
        // report must refuse it a percentile.
        XCTAssertTrue(try make(.film).manifest.perturbed)
        XCTAssertFalse(try make(.trace).manifest.perturbed)
    }

    // MARK: NDJSON

    struct Row: Codable, Equatable { let seq: Int; let stateKey: String }

    func testAppendWritesOneRecordPerLine() throws {
        let store = try make()
        try store.append(Row(seq: 1, stateKey: "a"), to: store.traceURL)
        try store.append(Row(seq: 2, stateKey: "b"), to: store.traceURL)

        let text = try String(contentsOf: store.traceURL, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2, "NDJSON is one record per line — a pretty-printed encoder would break the format")
        let decoded = try lines.map { try HarnessReport.decoder.decode(Row.self, from: Data($0.utf8)) }
        XCTAssertEqual(decoded, [Row(seq: 1, stateKey: "a"), Row(seq: 2, stateKey: "b")])
    }

    func testAppendSurvivesAcrossHandles() throws {
        // A take is written across a long run and must survive the process dying mid-take.
        let store = try make()
        for i in 1...50 { try store.append(Row(seq: i, stateKey: "s"), to: store.readsURL) }
        let lines = try String(contentsOf: store.readsURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 50)
    }

    // MARK: refusals

    func testLocatorsOwnWindowsAreRefused() {
        XCTAssertEqual(TakeStore.refusal(forApp: "Forte Locator Engine", bundleID: "com.forte.locator.engine", watched: true), .ownWindows)
        XCTAssertEqual(TakeStore.refusal(forApp: "Locator", bundleID: nil, watched: true), .ownWindows)
    }

    func testTerminalAndDockAreRefusedEvenWhenWatched() {
        // Retention-only exclusions (ADR 0004) — and a take IS retention.
        XCTAssertEqual(TakeStore.refusal(forApp: "Terminal", bundleID: "com.apple.Terminal", watched: true), .hardExcluded(app: "Terminal"))
        XCTAssertEqual(TakeStore.refusal(forApp: "Dock", bundleID: "com.apple.dock", watched: true), .hardExcluded(app: "Dock"))
    }

    func testAnUnwatchedAppIsRefusedBecauseRecordingIsRetention() {
        XCTAssertEqual(TakeStore.refusal(forApp: "Mail", bundleID: "com.apple.mail", watched: false), .notWatched(app: "Mail"))
        XCTAssertNil(TakeStore.refusal(forApp: "Mail", bundleID: "com.apple.mail", watched: true))
    }

    func testARefusalNamesItsReason() {
        XCTAssertTrue(RecordingRefusal.ownWindows.description.contains("hall of mirrors"))
        XCTAssertTrue(RecordingRefusal.notWatched(app: "Mail").description.contains("default-deny"))
        XCTAssertTrue(RecordingRefusal.hardExcluded(app: "Dock").description.contains("hard-excluded"))
    }

    func testNothingIsWrittenWhenAnyAppIsRefused() throws {
        // The refusal fires before creation: a half-written take of a refused app is a recording of it.
        XCTAssertThrowsError(try TakeStore.create(flow: "mixed", mode: .trace, binary: stamp,
                                                  apps: [("Pro Tools", "com.avid.ProTools", true),
                                                         ("Terminal", "com.apple.Terminal", true)],
                                                  root: tmp))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("mixed").path),
                       "no directory may exist for a refused run")
    }

    func testTakesLiveOutsideTheRepo() {
        XCTAssertTrue(TakeStore.harnessRoot().path.contains("/.fflow/harness"),
                      "takes hold raw pixels of the real screen — they never go in the repo")
    }

    func testTakeIDsSortChronologically() {
        let a = TakeStore.takeID(at: Date(timeIntervalSince1970: 1_700_000_000))
        let b = TakeStore.takeID(at: Date(timeIntervalSince1970: 1_700_003_600))
        XCTAssertLessThan(a, b)
    }
}
