import XCTest
import CoreGraphics
import LocatorCore
@testable import Relocation

final class ScrollTraversalTests: XCTestCase {
    private let pane = CGRect(x: 0, y: 0.1, width: 0.3, height: 0.8)

    private func scene(_ label: String = "Output 30", section: String = "sidebar (Name)",
                       title: String = "I/O Setup") -> SceneSnapshot {
        SceneSnapshot(bundleID: "com.test.scroll", app: "Test", windowTitle: title,
                      viewportPx: [1000, 800], elements: [
                        SceneElement(id: label, kind: "text", label: label,
                                     pos: [0.02, 0.2, 0.2, 0.03], section: section),
                        SceneElement(id: "other", kind: "text", label: "Unrelated settings",
                                     pos: [0.5, 0.2, 0.3, 0.03], section: "content")
                      ], commands: [])
    }

    private func step(_ moved: Bool, verified: Bool = true) -> PaneScroller.Outcome {
        .init(moved: moved, paneName: "sidebar (Name)", ticks: 4, verified: verified)
    }

    // Ticket 28: a first downward burst at BOTTOM is still. The later upward and downward legs
    // genuinely move. The old handler discarded their outcomes, returned acted_noop, and learned false.
    func testSweepStartingAtBottomUsesLaterMovementAndSurvivesHeaderChanges() async {
        let outcomes = [step(true), step(false), step(true), step(false)]
        let pages = [scene(), scene("Output 1", section: "sidebar (Output 1)"), scene("Output 1"),
                     scene("Output 30", section: "sidebar (Output 30)"), scene()]
        var scrollIndex = 0, readIndex = 0
        let result = await ScrollTraversal.run(mode: .sweep, initial: step(false), paneProven: false, directionVerified: true,
            pane: pane, window: scene(), scroll: { _ in
                defer { scrollIndex += 1 }; return outcomes[scrollIndex]
            }, read: {
                defer { readIndex += 1 }; return pages[readIndex]
            })
        XCTAssertTrue(result.finished(.sweep))
        XCTAssertTrue(result.moved)
        XCTAssertTrue(result.paneProven, "the memory write must retain the movement proof")
        XCTAssertEqual(result.labels, ["Output 1", "Output 30"])
        XCTAssertFalse(result.message(mode: .sweep, pane: "sidebar").contains("EVERYTHING"))
    }

    func testStepLimitCannotClaimBottomReached() async {
        let result = await ScrollTraversal.run(mode: .bottom, initial: step(true), paneProven: true, directionVerified: true,
            pane: pane, window: scene(), firstLimit: 2, scroll: { _ in self.step(true) },
            read: { self.scene() })
        XCTAssertFalse(result.finished(.bottom))
        XCTAssertEqual(result.finalStop, .budget)
        XCTAssertTrue(result.message(mode: .bottom, pane: "sidebar").contains("step limit"))
        XCTAssertFalse(result.message(mode: .bottom, pane: "sidebar").contains("is now at"))
    }

    func testSweepMissingTopRemainsPartialEvenIfBottomStops() async {
        var call = 0
        let result = await ScrollTraversal.run(mode: .sweep, initial: step(true), paneProven: true, directionVerified: true,
            pane: pane, window: scene(), firstLimit: 1, scroll: { _ in
                defer { call += 1 }; return self.step(call == 0)
            }, read: { self.scene() })
        XCTAssertEqual(result.firstStop, .budget)
        XCTAssertEqual(result.finalStop, .unchanged)
        XCTAssertFalse(result.finished(.sweep))
    }

    func testCaptureFailureIsNotAnEndStopAndStopsFurtherDelivery() async {
        var calls = 0
        let result = await ScrollTraversal.run(mode: .sweep, initial: step(false), paneProven: false, directionVerified: true,
            pane: pane, window: scene(), scroll: { _ in
                calls += 1; return self.step(false, verified: false)
            }, read: { self.scene() })
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result.finalStop, .unverified)
        XCTAssertFalse(result.finished(.sweep))
        XCTAssertFalse(result.paneProven)
        XCTAssertNil(result.scene)
    }

    func testLostSceneKeepsPartialLabelsButNeverAttachesOldSceneAsCurrent() async {
        var reads = 0
        let result = await ScrollTraversal.run(mode: .sweep, initial: step(false), paneProven: false, directionVerified: true,
            pane: pane, window: scene(), scroll: { _ in self.step(true) }, read: {
                defer { reads += 1 }; return reads == 0 ? self.scene() : nil
            })
        XCTAssertEqual(result.finalStop, .unverified)
        XCTAssertNil(result.scene)
        XCTAssertEqual(result.labels, ["Output 30"])
        XCTAssertFalse(result.paneProven, "a missing scene cannot confirm which window moved")
    }

    func testDifferentWindowStopsWithoutMixingItsLabels() async {
        var reads = 0, calls = 0
        let result = await ScrollTraversal.run(mode: .sweep, initial: step(false), paneProven: false, directionVerified: true,
            pane: pane, window: scene(), scroll: { _ in
                calls += 1; return self.step(true)
            }, read: {
                defer { reads += 1 }
                return reads == 0 ? self.scene() : self.scene("Export", title: "Export dialog")
            })
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result.finalStop, .windowChanged)
        XCTAssertEqual(result.labels, ["Output 30"])
        XCTAssertNil(result.scene)
    }

    func testNoMovementInEitherDirectionDoesNotInventADeadPaneOrCompletedSweep() async {
        let result = await ScrollTraversal.run(mode: .sweep, initial: step(false), paneProven: false, directionVerified: true,
            pane: pane, window: scene(), scroll: { _ in self.step(false) }, read: { self.scene() })
        XCTAssertFalse(result.paneProven)
        XCTAssertFalse(result.finished(.sweep))
        XCTAssertTrue(result.message(mode: .sweep, pane: "sidebar").contains("indistinguishable"))
        XCTAssertEqual(result.labels, ["Output 30"])
    }

    func testNumericNamesAreKeptAndOutsideLabelsAreExcluded() {
        XCTAssertEqual(ScrollTraversal.labels(in: scene("808"), pane: pane), ["808"])
        XCTAssertEqual(ScrollTraversal.labels(in: scene("•••"), pane: pane), [])
    }

    func testProbeMovementAloneCannotCompleteAStationarySweep() async {
        let result = await ScrollTraversal.run(mode: .sweep, initial: step(false), paneProven: true, directionVerified: true,
            pane: pane, window: scene(), scroll: { _ in self.step(false) }, read: { self.scene() })
        XCTAssertTrue(result.paneProven)
        XCTAssertFalse(result.finished(.sweep))
        XCTAssertTrue(result.message(mode: .sweep, pane: "sidebar").contains("no traversal movement"))
    }

    func testUnknownWheelDirectionCannotClaimAnEndpoint() async {
        let result = await ScrollTraversal.run(mode: .bottom, initial: step(true), paneProven: true,
            directionVerified: false, pane: pane, window: scene(),
            scroll: { _ in self.step(false) }, read: { self.scene() })
        XCTAssertFalse(result.finished(.bottom))
        XCTAssertTrue(result.message(mode: .bottom, pane: "sidebar").contains("wheel direction not verified"))
    }

    func testReadingLegRetainsOverlapAcrossA120RowList() async {
        // A 30-row viewport and a 12-row nudge. Four-line reading bursts skip rows; one-line
        // nudges overlap. Start at the bottom to also exercise the original dead-initial-burst case.
        var offset = 90
        func page() -> SceneSnapshot {
            let rows = (offset..<(offset + 30)).map { n in
                SceneElement(id: "row-\(n)", kind: "text", label: "Row \(n)",
                             pos: [0.02, 0.12 + Double(n - offset) * 0.025, 0.2, 0.02],
                             section: "sidebar (Row \(offset))")
            }
            return SceneSnapshot(bundleID: "com.test.scroll", app: "Test", windowTitle: "I/O Setup",
                                 viewportPx: [1000, 800], elements: rows, commands: [])
        }
        let result = await ScrollTraversal.run(mode: .sweep, initial: step(false), paneProven: false,
            directionVerified: true, pane: pane, window: page(), scroll: { ticks in
                let before = offset
                offset = max(0, min(90, offset + ticks * 12))
                return self.step(offset != before)
            }, read: { page() })
        XCTAssertTrue(result.finished(.sweep))
        XCTAssertEqual(result.labels, Set((0..<120).map { "Row \($0)" }))
    }

    func testJumpReturnsCurrentViewportWithoutAnInventoryOfTheWholeJourney() async {
        var calls = 0, reads = 0
        let result = await ScrollTraversal.run(mode: .bottom, initial: step(true), paneProven: true, directionVerified: true,
            pane: pane, window: scene(), scroll: { _ in
                defer { calls += 1 }; return self.step(calls == 0)
            }, read: {
                defer { reads += 1 }; return self.scene("Output \(reads)")
            })
        XCTAssertTrue(result.finished(.bottom))
        XCTAssertEqual(result.labels, ["Output 2"])
        XCTAssertTrue(result.message(mode: .bottom, pane: "sidebar").contains("Current viewport"))
    }
}
