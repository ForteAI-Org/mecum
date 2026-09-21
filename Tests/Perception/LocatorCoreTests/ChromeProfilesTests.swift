import XCTest
@testable import LocatorCore

/// Profile-by-name resolution for the agent Chrome — parsed from Chrome's Local State, matched
/// unique-accept (the same honesty rule as element resolution: 2+ hits is an answer, not a guess).
final class ChromeProfilesTests: XCTestCase {
    // Shape lifted from Ron's real Local State (4 profiles, two named "Forte…"/"Team").
    let localState = """
    {"profile":{"last_used":"Default","info_cache":{
      "Default":{"name":"Ronaldo","user_name":"roon316@gmail.com"},
      "Profile 1":{"name":"Ron","user_name":"ron@forte-ai.com"},
      "Profile 2":{"name":"Team","user_name":"forte.music.team@gmail.com"},
      "Profile 4":{"name":"Forte! Team","user_name":"team@forte-ai.com"}}}}
    """.data(using: .utf8)!

    func testParseReadsAllProfilesSorted() {
        let profs = ChromeProfiles.parse(localState: localState)
        XCTAssertEqual(profs.map(\.dir), ["Default", "Profile 1", "Profile 2", "Profile 4"])
        XCTAssertEqual(profs[1].name, "Ron")
        XCTAssertEqual(profs[1].account, "ron@forte-ai.com")
    }

    func testExactNameWinsOverSubstringNoise() {
        // "Team" is an exact name AND a substring of "Forte! Team" — exact must win alone.
        let profs = ChromeProfiles.parse(localState: localState)
        let hits = ChromeProfiles.match("team", in: profs)
        XCTAssertEqual(hits.map(\.dir), ["Profile 2"])
    }

    func testSubstringResolvesByEmailFragment() {
        let profs = ChromeProfiles.parse(localState: localState)
        XCTAssertEqual(ChromeProfiles.match("roon316", in: profs).map(\.dir), ["Default"])
        XCTAssertEqual(ChromeProfiles.match("profile 4", in: profs).map(\.name), ["Forte! Team"])
    }

    func testAmbiguousAndMissAreHonest() {
        let profs = ChromeProfiles.parse(localState: localState)
        // "forte" hits the two forte-ai accounts AND forte.music.team — ambiguous, no guess.
        XCTAssertGreaterThan(ChromeProfiles.match("forte", in: profs).count, 1)
        XCTAssertTrue(ChromeProfiles.match("nonexistent", in: profs).isEmpty)
        XCTAssertTrue(ChromeProfiles.match("  ", in: profs).isEmpty)
    }

    func testGarbageDataParsesEmpty() {
        XCTAssertTrue(ChromeProfiles.parse(localState: Data("not json".utf8)).isEmpty)
        XCTAssertTrue(ChromeProfiles.parse(localState: Data("{}".utf8)).isEmpty)
    }
}
