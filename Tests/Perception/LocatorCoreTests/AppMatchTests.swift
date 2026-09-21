import XCTest
@testable import LocatorCore

final class AppMatchTests: XCTestCase {
    // The running apps from Ron's machine.
    private let premiere = ("Adobe Premiere", "com.adobe.PremierePro.26")
    private let proTools = ("Pro Tools", "com.avid.ProTools")
    private let slack = ("Slack", "com.tinyspeck.slackmacgap")

    func testMultiWordPhraseMatches() {
        // The regression: "Premiere Pro" (two words) must match — the space broke literal-substring.
        XCTAssertTrue(AppMatch.matches(query: "Premiere Pro", name: premiere.0, bundle: premiere.1))
        XCTAssertTrue(AppMatch.matches(query: "premiere", name: premiere.0, bundle: premiere.1))
        XCTAssertTrue(AppMatch.matches(query: "adobe premiere pro", name: premiere.0, bundle: premiere.1))
        XCTAssertTrue(AppMatch.matches(query: "pro tools", name: proTools.0, bundle: proTools.1))
        XCTAssertTrue(AppMatch.matches(query: "slack", name: slack.0, bundle: slack.1))
    }

    func testDoesNotCrossMatch() {
        // "pro tools" must NOT match Premiere (whose bundle contains "pro" but not "tools").
        XCTAssertFalse(AppMatch.matches(query: "pro tools", name: premiere.0, bundle: premiere.1))
        XCTAssertFalse(AppMatch.matches(query: "slack", name: premiere.0, bundle: premiere.1))
        XCTAssertFalse(AppMatch.matches(query: "logic", name: proTools.0, bundle: proTools.1))
    }

    func testOrderInsensitiveAndEmpty() {
        XCTAssertTrue(AppMatch.matches(query: "premiere adobe", name: premiere.0, bundle: premiere.1))  // reversed words
        XCTAssertFalse(AppMatch.matches(query: "", name: premiere.0, bundle: premiere.1))
    }

    func testMentionedInPhrase() {
        // The gemma failure: run_route(name:"slack") with no app arg — the query itself names the app.
        XCTAssertTrue(AppMatch.mentioned(in: "slack", name: slack.0, bundle: slack.1))
        XCTAssertTrue(AppMatch.mentioned(in: "go to simone in slack", name: slack.0, bundle: slack.1))
        XCTAssertTrue(AppMatch.mentioned(in: "export tab in premiere", name: premiere.0, bundle: premiere.1))
        // No mention → false (no false positives from short words like "to"/"go"/"pro").
        XCTAssertFalse(AppMatch.mentioned(in: "go to simone chat", name: premiere.0, bundle: premiere.1))
        XCTAssertFalse(AppMatch.mentioned(in: "export tab", name: slack.0, bundle: slack.1))
        XCTAssertFalse(AppMatch.mentioned(in: "", name: slack.0, bundle: slack.1))
        // "tools" (≥4 chars) mentions Pro Tools; a bare "pro" (3 chars) must not.
        XCTAssertTrue(AppMatch.mentioned(in: "new track in pro tools", name: proTools.0, bundle: proTools.1))
        XCTAssertFalse(AppMatch.mentioned(in: "pro settings", name: proTools.0, bundle: proTools.1))
    }
}
