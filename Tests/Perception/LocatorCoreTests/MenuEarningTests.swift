import XCTest
@testable import LocatorCore

/// The metronome regression (ticket 25): "Option + Click Solo" — a MODIFIER GESTURE naming no command —
/// executed Options > Click on a live Pro Tools because a one-word leaf contained in the query scored at
/// the accept threshold. These tests pin the coverage gate with the real menu shapes from that session.
final class MenuEarningTests: XCTestCase {
    private func knowledge(_ paths: [[String]]) -> AppKnowledge {
        var k = AppKnowledge(bundleID: "com.avid.ProTools")
        let now = Date()
        k.observeMenus(paths.map {
            MenuCommand(path: $0, topLevelTitle: $0.first ?? "", firstSeen: now, lastSeen: now)
        }, now: now)
        return k
    }

    func testGestureDescriptionNamesNoCommand() {
        let k = knowledge([["Options", "Click"], ["Options", "Loop Playback"],
                           ["Track", "New…"], ["File", "Open Session…"]])
        // The live bug: 1 of 3 query words explained ⇒ never executed…
        XCTAssertNil(k.bestMenuCommand(for: "Option + Click Solo"))
        // …but still worth NAMING in the miss message.
        XCTAssertEqual(k.menuSuggestion(for: "Option + Click Solo")?.path, ["Options", "Click"])
    }

    func testGenuineQueriesStillResolve() {
        let k = knowledge([["Options", "Click"], ["Track", "New…"], ["File", "Export", "AAF…"],
                           ["Setup", "I/O…"], ["Filter", "Blur", "Gaussian Blur…"]])
        XCTAssertEqual(k.bestMenuCommand(for: "new track")?.path, ["Track", "New…"])
        XCTAssertEqual(k.bestMenuCommand(for: "gaussian blur")?.path, ["Filter", "Blur", "Gaussian Blur…"])
        // "I/O" tokenizes to i·o, so "io" has never matched it — pre-existing tokenizer behavior this
        // gate must not be blamed for. The underspecified single word still resolves (coverage 1.0):
        XCTAssertEqual(k.bestMenuCommand(for: "setup")?.path, ["Setup", "I/O…"])
        // The bare leaf itself still works — coverage 1.0.
        XCTAssertEqual(k.bestMenuCommand(for: "click")?.path, ["Options", "Click"])
    }

    func testScatteredTokensAcrossPathDoNotExecute() {
        // "solo the click track" scatters over Options>Click's path + unrelated words: no execution.
        let k = knowledge([["Options", "Click"], ["Track", "New…"]])
        XCTAssertNil(k.bestMenuCommand(for: "solo the click track please"))
    }
}
