import XCTest
@testable import LocatorCore

/// The symbolic-seeing plan's Task-9 fixtures (docs/codex/...implementation-plan.md), pinned as unit
/// tests: single-app work, the export detour (A→Finder→A), a long Slack interruption, idle
/// completion, and rapid app switching. Determinism is the contract — same events, same timeline.
final class EpisodeSegmenterTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    func ev(_ s: TimeInterval, _ app: String, kind: String = "click",
            label: String? = nil, actor: String = "user") -> ActivityEvent {
        ActivityEvent(ts: t0.addingTimeInterval(s), actor: actor, app: "com.x.\(app)",
                      appName: app, kind: kind, label: label)
    }

    func testSingleAppBurstIsOneEpisodeOneStep() {
        let eps = EpisodeSegmenter.episodes([ev(0, "ProTools"), ev(5, "ProTools"), ev(12, "ProTools")])
        XCTAssertEqual(eps.count, 1)
        XCTAssertEqual(eps[0].steps.count, 1)
        XCTAssertNil(eps[0].endReason)          // still open
        XCTAssertEqual(eps[0].primaryApp.name, "ProTools")
    }

    func testPauseInsideAppSplitsStepNotTask() {
        let eps = EpisodeSegmenter.episodes([ev(0, "ProTools"), ev(10, "ProTools"),
                                             ev(50, "ProTools"), ev(55, "ProTools")])   // 40s pause < taskGap
        XCTAssertEqual(eps.count, 1)
        XCTAssertEqual(eps[0].steps.count, 2)
    }

    func testIdleGapEndsTheTaskWithEvidence() {
        let eps = EpisodeSegmenter.episodes([ev(0, "ProTools"), ev(10, "ProTools"),
                                             ev(400, "ProTools"), ev(405, "ProTools")])  // 390s idle
        XCTAssertEqual(eps.count, 2)
        XCTAssertEqual(eps[0].endReason, "idle 7m")   // 390s ≈ 7m, the boundary keeps its evidence
        XCTAssertNil(eps[1].endReason)
    }

    func testShortDetourFoldsAsInterruption() {
        // Resolve → Finder (20s) → Resolve: ONE export task with a folded interruption step.
        let eps = EpisodeSegmenter.episodes([
            ev(0, "Resolve", label: "Export"), ev(8, "Resolve"),
            ev(40, "Finder"), ev(55, "Finder"),
            ev(80, "Resolve"), ev(90, "Resolve", label: "Render"),
        ])
        XCTAssertEqual(eps.count, 1)
        XCTAssertEqual(eps[0].steps.count, 3)
        XCTAssertTrue(eps[0].steps[1].isInterruption)
        XCTAssertEqual(eps[0].primaryApp.name, "Resolve")
        XCTAssertEqual(eps[0].steps.filter(\.isInterruption).count, 1)
    }

    func testLongForeignWorkSplitsTasks() {
        // Slack work lasting > interruptionMax is its own episode, with switch evidence on both sides.
        let eps = EpisodeSegmenter.episodes([
            ev(0, "ProTools"), ev(10, "ProTools"),
            ev(40, "Slack"), ev(80, "Slack"), ev(140, "Slack"),   // 100s of Slack
            ev(170, "ProTools"), ev(180, "ProTools"),
        ])
        XCTAssertEqual(eps.count, 3)
        XCTAssertEqual(eps[0].endReason, "switched to Slack")
        XCTAssertEqual(eps[1].endReason, "switched to ProTools")
        XCTAssertEqual(eps[1].primaryApp.name, "Slack")
        XCTAssertNil(eps[2].endReason)
    }

    func testRapidSwitchingKeepsRealWorkSeparate() {
        // A then B then C, each with sustained work and no sandwich — three episodes.
        let eps = EpisodeSegmenter.episodes([
            ev(0, "A"), ev(100, "A"),
            ev(130, "B"), ev(230, "B"),
            ev(260, "C"), ev(360, "C"),
        ])
        XCTAssertEqual(eps.count, 3)
        XCTAssertEqual(eps.compactMap(\.endReason), ["switched to B", "switched to C"])
    }

    func testAgentActivityIsTaggedAndTitled() {
        let eps = EpisodeSegmenter.episodes([
            ev(0, "ProTools", label: "New Tracks"),
            ev(5, "ProTools", kind: "act", label: "Routing Folder", actor: "agent"),
            ev(9, "ProTools", label: "Routing Folder"),
            ev(12, "ProTools", label: "Routing Folder"),
        ])
        XCTAssertEqual(eps.count, 1)
        XCTAssertTrue(eps[0].hasAgentActivity)
        XCTAssertTrue(eps[0].title.contains("Routing Folder"))   // most-touched label leads the title
        XCTAssertTrue(TimelineRenderer.summaryLine(eps[0]).contains("⚙ agent"))
    }

    func testGlueAppsNeitherOwnNorSplitEpisodes() {
        // ProTools → Dock clicks → Chrome: the Dock joins whatever is open and the boundary evidence
        // names Chrome, never the Dock. Measured need: Dock-primary episodes covered half the first
        // real ledger before glue handling.
        let dock = { (s: TimeInterval) in ActivityEvent(ts: self.t0.addingTimeInterval(s), actor: "user",
                                                        app: "com.apple.dock", appName: "Dock", kind: "click") }
        let eps = EpisodeSegmenter.episodes([
            ev(0, "ProTools", label: "Mix"), ev(6, "ProTools"),
            dock(30), dock(32),
            ev(60, "Chrome"), ev(160, "Chrome"),
        ])
        XCTAssertEqual(eps.count, 2)
        XCTAssertEqual(eps[0].primaryApp.name, "ProTools")
        XCTAssertEqual(eps[0].endReason, "switched to Chrome")
        XCTAssertTrue(eps[0].steps.contains { $0.isGlue })       // the Dock rode along, uncounted
        XCTAssertEqual(eps[1].primaryApp.name, "Chrome")
        // All-glue stretches still surface honestly when nothing else exists.
        let onlyDock = EpisodeSegmenter.episodes([dock(0), dock(5)])
        XCTAssertEqual(onlyDock.count, 1)
        XCTAssertEqual(onlyDock[0].primaryApp.name, "Dock")
    }

    func testEmptyAndRendererDoNotCrash() {
        XCTAssertTrue(EpisodeSegmenter.episodes([]).isEmpty)
        let eps = EpisodeSegmenter.episodes([ev(0, "A", label: "x")])
        XCTAssertFalse(TimelineRenderer.detail(eps[0]).isEmpty)
    }
}
