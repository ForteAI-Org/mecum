import XCTest
@testable import LocatorCore

/// Issues 05 and 06. The streams the sweeps and the headline are computed from.
final class HarnessStreamsTests: XCTestCase {

    private func roundTrip<T: Codable & Equatable>(_ v: T) throws -> T {
        try HarnessReport.decoder.decode(T.self, from: HarnessReport.compactEncoder.encode(v))
    }

    /// A take re-read and re-written is unchanged. This is the real guarantee (timestamps are
    /// millisecond-precision by design — see `HarnessReport.makeISO8601ms`), and it is what a replay
    /// depends on; bit-equality with an in-memory `Date` is not something any text format can promise.
    func assertRoundTripStable<T: Codable & Equatable>(_ v: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let once = try HarnessReport.decoder.decode(T.self, from: HarnessReport.compactEncoder.encode(v))
        let twice = try HarnessReport.decoder.decode(T.self, from: HarnessReport.compactEncoder.encode(once))
        XCTAssertEqual(once, twice, "a take must be a fixed point of read→write", file: file, line: line)
    }


    // MARK: ingest (issue 05)

    func testAnIngestRecordRoundTrips() throws {
        let r = IngestRecord(ts: Date(), observationBlock: 7, stateKey: "pt:mix:a1b2",
                             windowHandle: 4211, anchorKeys: ["kick", "snare"],
                             groups: ["Tracks#12"], transitions: ["mix→edit"], ingestEpoch: 34)
        try assertRoundTripStable(r)
    }

    func testIngestCarriesTheEpochADecayBugNeeds() throws {
        // The 2026-09-06 amnesia fix keyed decay to ingestEpoch. A take that loses it cannot reproduce
        // the bug this stream exists to catch.
        let json = try HarnessReport.compactEncoder.encode(
            IngestRecord(ts: Date(), observationBlock: 1, stateKey: "s", windowHandle: nil,
                         anchorKeys: [], groups: [], transitions: [], ingestEpoch: 99))
        XCTAssertTrue(String(decoding: json, as: UTF8.self).contains("\"ingestEpoch\":99"))
    }

    func testObservationBlocksAreTheUnitTheThresholdsCountIn() throws {
        // transient 12 / stale 150 are counted in OBSERVATIONS of a window, not frames and not days —
        // so the block number has to survive the round trip as an integer we can sweep over.
        let r = try roundTrip(IngestRecord(ts: Date(), observationBlock: 150, stateKey: "s",
                                           windowHandle: nil, anchorKeys: [], groups: [],
                                           transitions: [], ingestEpoch: 1))
        XCTAssertEqual(r.observationBlock, 150)
    }

    // MARK: session (issue 06)

    func testASessionRecordRoundTripsWithItsRoundCount() throws {
        let r = SessionRecord(ts: Date(), phrase: "mute the kick",
                              tools: [.init(tool: "act", args: ["app": "pro tools"], outcome: "found_acted: muted")],
                              rounds: 3, imitated: false, answer: "done", ok: true, app: "pro tools",
                              taskMark: "pt-import")
        try assertRoundTripStable(r)
    }

    func testUnknownRoundsSurviveAsNullAndNotAsZero() throws {
        // `nil` = nobody counted (an MCP turn). `0` = the model was never asked, and is the no-model
        // share's numerator. Collapsing the first into the second inflates the headline.
        let unknown = SessionRecord(ts: Date(), phrase: "p", tools: [], rounds: nil, imitated: false,
                                    answer: nil, ok: true, app: nil)
        let zero = SessionRecord(ts: Date(), phrase: "p", tools: [], rounds: 0, imitated: true,
                                 answer: nil, ok: true, app: nil)
        XCTAssertNil(try roundTrip(unknown).rounds)
        XCTAssertEqual(try roundTrip(zero).rounds, 0)
        XCTAssertNotEqual(try roundTrip(unknown), try roundTrip(zero))
    }

    func testTypedTextNeverReachesTheSessionStream() throws {
        // TurnTool's redaction is the law; this asserts the stream inherits it rather than re-implementing.
        let r = SessionRecord(ts: Date(), phrase: "send it",
                              tools: [.init(tool: "type", args: ["text": "my bank password"], outcome: "found_acted")],
                              rounds: 1, imitated: false, answer: nil, ok: true, app: "mail")
        let json = String(decoding: try HarnessReport.compactEncoder.encode(r), as: UTF8.self)
        XCTAssertFalse(json.contains("bank password"), "typed text must never land in a take")
        XCTAssertTrue(json.contains("redacted"))
    }

    // MARK: events (issue 06)

    func testAnInputEventRoundTrips() throws {
        let e = InputEvent(ts: Date(), kind: .scrollEnd, windowHandle: 42, pos: [0.5, 0.25])
        try assertRoundTripStable(e)
    }

    func testTheEventFormatHasNowhereToPutTypedText() throws {
        // Redaction BY CONSTRUCTION: a filter can be forgotten, a missing field cannot be filled in by
        // accident. The wire format's keys are a closed set, and none of them holds content.
        let json = try JSONSerialization.jsonObject(
            with: HarnessReport.compactEncoder.encode(InputEvent(ts: Date(), kind: .click, windowHandle: 1, pos: [0, 0])))
        let obj = (json as? [String: Any]) ?? [:]
        let keys = Set(obj.keys)
        XCTAssertEqual(keys, ["ts", "kind", "windowHandle", "pos"])
        XCTAssertTrue(keys.isDisjoint(with: ["text", "chars", "content", "body", "message"]))
    }

    func testOnlyTheTwoKeysThatAreLookTriggersExist() {
        // Ticket 04 made Return and Esc triggers; every other keystroke is exactly what the law forbids
        // keeping, so it has no representation at all.
        let all = Set([InputEvent.Kind.click, .rightClick, .doubleClick, .scrollEnd, .returnKey, .escape, .focusChange]
                        .map(\.rawValue))
        XCTAssertEqual(all.filter { $0.contains("Key") || $0 == "escape" }.sorted(), ["escape", "returnKey"])
    }

    // MARK: they land in a take

    func testTheStreamsAppendToTheirOwnFilesInATake() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try TakeStore.create(flow: "f", mode: .trace,
                                         binary: .init(sha256: "x", mtime: Date(), sourcesNewest: nil),
                                         apps: [("Pro Tools", "com.avid.ProTools", true)], root: tmp)
        try store.append(IngestRecord(ts: Date(), observationBlock: 1, stateKey: "s", windowHandle: nil,
                                      anchorKeys: [], groups: [], transitions: [], ingestEpoch: 1), to: store.ingestURL)
        try store.append(InputEvent(ts: Date(), kind: .click, windowHandle: 1), to: store.eventsURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.ingestURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.eventsURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.traceURL.path), "an unused stream stays absent")
    }
}
