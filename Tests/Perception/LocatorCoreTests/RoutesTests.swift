import XCTest
@testable import LocatorCore

final class RoutesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func step(_ target: String) -> RouteStep { RouteStep(tool: "act", target: target, verb: "click") }

    func testLearnAndBestRoute() {
        var app = AppKnowledge(bundleID: "com.x")
        app.learnRoute(name: "simone chat", steps: [step("¿ Simone")], proof: "2 verified steps, none missed", now: t0)
        app.learnRoute(name: "export tab", steps: [step("Export")], proof: "2 verified steps, none missed", now: t0)
        XCTAssertEqual(app.bestRoute(for: "simone chat")?.steps.first?.target, "¿ Simone")
        XCTAssertEqual(app.bestRoute(for: "simone")?.name, "simone chat")     // token subset still unique
        XCTAssertNil(app.bestRoute(for: "totally unknown thing"))
    }

    func testBestRouteIsUniqueAccept() {
        // Two routes that both match a vague query must refuse (nil) — same house rule as bestMenuCommand.
        var app = AppKnowledge(bundleID: "com.x")
        app.learnRoute(name: "export tab", steps: [step("Export")], proof: "2 verified steps, none missed", now: t0)
        app.learnRoute(name: "export settings", steps: [step("Export"), step("Settings")], proof: "2 verified steps, none missed", now: t0)
        XCTAssertNil(app.bestRoute(for: "export"))
        XCTAssertEqual(app.bestRoute(for: "export settings")?.steps.count, 2)  // exact still wins
    }

    func testRelearnSameStepsBumpsEvidenceDifferentStepsResets() {
        var app = AppKnowledge(bundleID: "com.x")
        app.learnRoute(name: "simone chat", steps: [step("¿ Simone")], proof: "2 verified steps, none missed", now: t0)
        app.learnRoute(name: "simone chat", steps: [step("¿ Simone")], proof: "2 verified steps, none missed", now: t0)        // same way again
        XCTAssertEqual(app.routes[0].evidence, 2)
        app.learnRoute(name: "Simone Chat", steps: [step("Home"), step("Simone")], proof: "2 verified steps, none missed", now: t0)  // new way (normalized-same name)
        XCTAssertEqual(app.routes.count, 1)
        XCTAssertEqual(app.routes[0].evidence, 1)                                       // reset — it's a different procedure
        XCTAssertEqual(app.routes[0].steps.count, 2)
    }

    func testSuccessStrengthensAndResetsFailStreak() {
        var app = AppKnowledge(bundleID: "com.x")
        app.learnRoute(name: "export tab", steps: [step("Export")], proof: "2 verified steps, none missed", now: t0)
        app.recordRouteUse(name: "export tab", success: true, now: t0)
        XCTAssertEqual(app.routes[0].evidence, 2)
        app.recordRouteUse(name: "export tab", success: false, now: t0)
        app.recordRouteUse(name: "export tab", success: true, now: t0)   // a win clears the streak
        XCTAssertEqual(app.routes[0].failStreak, 0)
        XCTAssertEqual(app.routes[0].evidence, 3)
    }

    func testOneFailureStillMatchesTwoDemote() {
        var app = AppKnowledge(bundleID: "com.x")
        app.learnRoute(name: "export tab", steps: [step("Export")], proof: "2 verified steps, none missed", now: t0)
        app.recordRouteUse(name: "export tab", success: false, now: t0)
        XCTAssertNotNil(app.bestRoute(for: "export tab"))              // one failure: still usable
        app.recordRouteUse(name: "export tab", success: false, now: t0)
        XCTAssertNil(app.bestRoute(for: "export tab"))                 // two consecutive: not actionable
        // …but the row and its cause SURVIVE — a Contradiction demotes, it never erases (ADR 0001).
        XCTAssertEqual(app.routes.count, 1)
        XCTAssertEqual(app.routes[0].demotedAt, t0)
        XCTAssertTrue(app.routes[0].demotionCause?.contains("replay failed") == true)
    }

    // MARK: the falsifiability law (ticket 12)

    /// A write with no Proof is stored as an Observation: readable, never replayed.
    func testAnUnprovenRouteIsStoredButNeverActionable() {
        var app = AppKnowledge(bundleID: "com.x")
        app.learnRoute(name: "export tab", steps: [step("Export")], now: t0)
        XCTAssertEqual(app.routes.count, 1)
        XCTAssertFalse(app.routes[0].isActionable)
        XCTAssertNil(app.bestRoute(for: "export tab"))
    }

    /// The grandfather clause: a pre-law row that earned itself independently keeps working.
    func testAnIndependentlyConfirmedPreLawRouteStaysActionable() {
        var app = AppKnowledge(bundleID: "com.x")
        app.learnRoute(name: "export tab", steps: [step("Export")], now: t0)   // no proof — pre-law shape
        app.recordRouteUse(name: "export tab", success: true, now: t0)          // one independent confirmation
        XCTAssertEqual(app.routes[0].evidence, 2)
        XCTAssertNotNil(app.bestRoute(for: "export tab"))
    }

    func testACorrectionDemotesAndKeepsTheCause() {
        var app = AppKnowledge(bundleID: "com.x")
        app.learnRoute(name: "unsolo all tracks", steps: [step("Solo")], proof: "2 verified steps, none missed", now: t0)
        let demoted = app.demoteRoute(named: "Unsolo All Tracks", cause: "you corrected me: \u{201C}no no, use api\u{201D}", now: t0)
        XCTAssertEqual(demoted?.name, "unsolo all tracks")
        XCTAssertNil(app.bestRoute(for: "unsolo all tracks"))
        XCTAssertEqual(app.routes[0].steps.count, 1)                            // the corpse keeps its steps
        XCTAssertTrue(app.routes[0].demotionCause?.contains("no no, use api") == true)
        // Demoting twice must not overwrite the first cause — the first Contradiction is the true one.
        XCTAssertNil(app.demoteRoute(named: "unsolo all tracks", cause: "something else", now: t0))
        XCTAssertTrue(app.routes[0].demotionCause?.contains("no no, use api") == true)
    }

    /// A Belief may be re-earned: a later verified success lifts the demotion, and the record that it
    /// was once wrong stays.
    func testAFreshProofLiftsADemotion() {
        var app = AppKnowledge(bundleID: "com.x")
        app.learnRoute(name: "export tab", steps: [step("Export")], proof: "2 verified steps, none missed", now: t0)
        app.demoteRoute(named: "export tab", cause: "you corrected me", now: t0)
        app.learnRoute(name: "export tab", steps: [step("Export")], proof: "3 verified steps, none missed", now: t0)
        XCTAssertNotNil(app.bestRoute(for: "export tab"))
        XCTAssertNotNil(app.routes[0].demotionCause)
    }

    func testTheRetrofitDemotesEveryUnearnedRowAndSaysWhy() {
        var app = AppKnowledge(bundleID: "com.x")
        app.learnRoute(name: "you went to next, not previous", steps: [step("Next")], now: t0)   // pre-law garbage
        app.learnRoute(name: "creative cloud", steps: [step("Home")], now: t0)
        app.recordRouteUse(name: "creative cloud", success: true, now: t0)                        // confirmed once
        app.learnRoute(name: "go to simone", steps: [step("Simone")], proof: "2 verified steps, none missed", now: t0)
        let demoted = app.demoteUnearnedRoutes(now: t0)
        XCTAssertEqual(demoted.map(\.name), ["you went to next, not previous"])
        XCTAssertTrue(demoted[0].demotionCause?.contains("before a Route had to be earned") == true)
        XCTAssertEqual(app.actionableRoutes.map(\.name).sorted(), ["creative cloud", "go to simone"])
        XCTAssertEqual(app.routes.count, 3)                                                       // nothing erased
        XCTAssertTrue(app.demoteUnearnedRoutes(now: t0).isEmpty)                                  // idempotent
    }

    func testPruneStaleAndCap() {
        var app = AppKnowledge(bundleID: "com.x")
        app.learnRoute(name: "old", steps: [step("A")], proof: "2 verified steps, none missed", now: t0)
        let later = t0.addingTimeInterval(31 * 86_400)
        app.learnRoute(name: "fresh", steps: [step("B")], proof: "2 verified steps, none missed", now: later)  // learning prunes: "old" unused 31d → gone
        XCTAssertEqual(app.routes.map(\.name), ["fresh"])
    }

    func testDecodeBackCompatAndRoundTrip() throws {
        let enc = DescriptorStore.makeEncoder(); let dec = DescriptorStore.makeDecoder()
        // Old per-app JSON (no routes key) still loads.
        let old = try dec.decode(AppKnowledge.self, from: Data(#"{"bundleID":"com.x","windows":[]}"#.utf8))
        XCTAssertTrue(old.routes.isEmpty)
        // Round-trip with a route incl. a Return-only type step.
        var app = AppKnowledge(bundleID: "com.x")
        app.learnRoute(name: "delete confirm", steps: [
            RouteStep(tool: "act", target: "Elimina messaggio...", verb: "click", expect: "elementsAppeared"),
            RouteStep(tool: "type", submit: true),
        ], proof: "2 verified steps, none missed", now: t0)
        XCTAssertEqual(try dec.decode(AppKnowledge.self, from: try enc.encode(app)), app)
    }

    func testStopwordInsensitiveMatching() {
        // "Simone chat" must find 'go to simone' — filler (go/to/open/vai…) carries no goal content
        // (measured: scored 0.5 and missed, gemma gave up).
        var app = AppKnowledge(bundleID: "com.x")
        app.learnRoute(name: "go to simone", steps: [step("Simone")], proof: "2 verified steps, none missed", now: t0)
        XCTAssertEqual(app.bestRoute(for: "Simone chat")?.name, "go to simone")
        XCTAssertEqual(app.bestRoute(for: "simone")?.name, "go to simone")
        XCTAssertEqual(app.bestRoute(for: "vai da simone")?.name, "go to simone")   // Italian filler too
        XCTAssertNil(app.bestRoute(for: "michele"))                                  // no content overlap
    }

    func testEndTitleFamilyAndActionKeyIgnoreObservations() {
        var app = AppKnowledge(bundleID: "com.x")
        let s1 = [RouteStep(tool: "act", target: "Home", verb: "click", afterTitle: "homeforteai"),
                  RouteStep(tool: "act", target: "Simone", verb: "click", afterTitle: "simonemdforteaislack")]
        app.learnRoute(name: "go to simone", steps: s1, proof: "2 verified steps, none missed", now: t0)
        XCTAssertEqual(app.routes[0].endTitleFamily, "simonemdforteaislack")
        // Re-save with the SAME actions but different observed titles → same way → evidence bumps.
        let s2 = [RouteStep(tool: "act", target: "Home", verb: "click", afterTitle: "different"),
                  RouteStep(tool: "act", target: "Simone", verb: "click", afterTitle: "simonemdforteaislack2")]
        app.learnRoute(name: "go to simone", steps: s2, proof: "2 verified steps, none missed", now: t0)
        XCTAssertEqual(app.routes[0].evidence, 2)
    }

    func testGoalSatisfiedByTitle() {
        // "go to simone" is DONE when the window is Simone's chat — no stored end state needed.
        XCTAssertTrue(Route.goalSatisfied(byTitle: "Simone (MD) - Forte AI - Slack", goal: "go to simone"))
        XCTAssertTrue(Route.goalSatisfied(byTitle: "Simone (MD) - Forte AI - Slack", goal: "Simone chat"))  // "chat" = filler
        XCTAssertFalse(Route.goalSatisfied(byTitle: "Andrea (MD) - Forte AI - Slack", goal: "go to simone"))
        XCTAssertFalse(Route.goalSatisfied(byTitle: "Untitled - Premiere Pro", goal: "export tab"))  // titles don't name tabs — no false idempotence
        XCTAssertFalse(Route.goalSatisfied(byTitle: "", goal: "simone"))
    }

    func testStepSummaries() {
        XCTAssertEqual(step("Export").summary, "act click 'Export'")
        XCTAssertEqual(RouteStep(tool: "run_menu", path: "File > Export").summary, "run_menu 'File > Export'")
        XCTAssertEqual(RouteStep(tool: "type", submit: true).summary, "press Return")
    }
}
