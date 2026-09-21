import XCTest
@testable import LocatorCore

/// WHAT A MISS IS ALLOWED TO COST. This seam decides, before a single pixel is captured, how much of
/// the expensive scroll-hunt a `reach` may pay for — from what accessibility has already told us for
/// free. Measured shape (ticket 13, DaVinci Deliver page): a target that IS there answers in 1.08s, a
/// target that is not cost 18.42s to learn one bit.
///
/// The cases below pin the real role-mix numbers, measured on the running apps (2026-08-22):
///   DaVinci Resolve  278 labels, 232 of them list content   → its silence means something
///   Adobe Premiere   144 labels,   5 of them list content   → 91 buttons of chrome; silence means nothing
///   Google Chrome     30 labels,   0 of them list content   → nothing
///   Finder           186 labels, walk ran out of budget     → an unfinished census proves nothing
final class HuntPolicyTests: XCTestCase {

    /// A map like Resolve's: it lists its own content, so a label missing from it is probably absent.
    func rich(knowsLabel: Bool = false, placed: HuntPolicy.Axis? = nil) -> HuntPolicy.AXVerdict {
        .init(labelsRead: 278, contentLabels: 232, complete: true, knowsLabel: knowsLabel, placed: placed)
    }

    // MARK: - when the hunt is the only tool, it stays exactly as it is today

    func testZeroAXKeepsTodaysFullHunt() {
        // An Electron app with accessibility off: no map at all. The pixel hunt is the ONLY evidence.
        let plan = HuntPolicy.decide(ax: .init(labelsRead: 0, contentLabels: 0, complete: true,
                                               knowsLabel: false, placed: nil))
        XCTAssertNil(plan.panes)                                    // nil = every candidate pane
        XCTAssertEqual(plan.seconds, HuntPolicy.fullHuntSeconds)
        XCTAssertTrue(plan.huntsAtAll)
    }

    func testChromeOnlyMapIsNotProofOfAbsence() {
        // PREMIERE, measured: 144 labels and only 5 of them content — panel tabs, transport buttons,
        // combo boxes. A toolkit gives that away for free; it says nothing about what is in the lists.
        // Counting labels instead of CONTENT labels here would silently cap the hunt on the very app
        // the hunt exists for.
        let plan = HuntPolicy.decide(ax: .init(labelsRead: 144, contentLabels: 5, complete: true,
                                               knowsLabel: false, placed: nil))
        XCTAssertNil(plan.panes)
        XCTAssertTrue(plan.huntsAtAll)
    }

    func testInterruptedWalkIsNotProofOfAbsence() {
        // FINDER, measured: a rich map whose walk hit its wall budget. It can only say "not in the part
        // I read", which is not an answer to "is it in this app".
        let plan = HuntPolicy.decide(ax: .init(labelsRead: 186, contentLabels: 146, complete: false,
                                               knowsLabel: false, placed: nil))
        XCTAssertNil(plan.panes)
    }

    func testAXKnowingTheLabelKeepsTheHuntWorthPaying() {
        // AX has the label somewhere but not as an off-view control (a static text, a row CV misread).
        // The target EXISTS, so the pane hunt is the tool that can bring it into view.
        let plan = HuntPolicy.decide(ax: rich(knowsLabel: true))
        XCTAssertNil(plan.panes)
        XCTAssertTrue(plan.huntsAtAll)
    }

    // MARK: - when accessibility already has the answer, the hunt is not paid for

    func testContentRichMapWithNoMatchSkipsTheHunt() {
        let plan = HuntPolicy.decide(ax: rich())
        XCTAssertEqual(plan.panes, 0)
        XCTAssertFalse(plan.huntsAtAll)
    }

    func testTheContentFloorIsInclusive() {
        func at(_ n: Int) -> HuntPolicy.Plan {
            HuntPolicy.decide(ax: .init(labelsRead: n * 2, contentLabels: n, complete: true,
                                        knowsLabel: false, placed: nil))
        }
        XCTAssertEqual(at(HuntPolicy.trustedContentFloor).panes, 0)
        XCTAssertNil(at(HuntPolicy.trustedContentFloor - 1).panes)
    }

    func testSidewaysPlacementSkipsTheVerticalHunt() {
        // AX placed the target sideways of its container and the AX-directed slide could not reveal it.
        // The vision hunt only scrolls vertically, so it cannot cover that axis — paying for it buys
        // nothing. This stacking of a directed attempt AND a full hunt is the 18.42s measurement.
        XCTAssertEqual(HuntPolicy.decide(ax: rich(knowsLabel: true, placed: .sideways)).panes, 0)
    }

    func testVerticalPlacementCapsRatherThanSkips() {
        // AX said the target hides above/below its container and the directed scroll still failed: the
        // virtual frame may be a phantom, and the vertical hunt is exactly the tool that can check.
        // Capped, because a cheap answer already exists — but never skipped.
        let plan = HuntPolicy.decide(ax: rich(knowsLabel: true, placed: .vertical))
        XCTAssertEqual(plan.panes, HuntPolicy.cappedHuntPanes)
        XCTAssertTrue(plan.huntsAtAll)
        XCTAssertLessThan(plan.seconds, HuntPolicy.fullHuntSeconds)
        XCTAssertGreaterThan(plan.seconds, 0)
    }

    func testEveryPlanCarriesItsReason() {
        let verdicts: [HuntPolicy.AXVerdict] = [
            .init(labelsRead: 0, contentLabels: 0, complete: true, knowsLabel: false, placed: nil),
            .init(labelsRead: 144, contentLabels: 5, complete: true, knowsLabel: false, placed: nil),
            .init(labelsRead: 186, contentLabels: 146, complete: false, knowsLabel: false, placed: nil),
            rich(), rich(knowsLabel: true), rich(knowsLabel: true, placed: .sideways),
            rich(knowsLabel: true, placed: .vertical),
        ]
        for ax in verdicts {
            XCTAssertFalse(HuntPolicy.decide(ax: ax).because.isEmpty,
                           "a plan with no stated reason cannot be reported honestly")
        }
    }

    func testAMapThatWasNeverReadIsNotBlamedOnABudget() {
        // `OffViewProbe.noWindow`: the capture layer gave no window frame, so AX was never asked
        // anything. That is `complete: false` with zero labels — and reporting it as "the walk ran out
        // of its own budget" is a statement about a walk that never happened.
        let plan = HuntPolicy.decide(ax: .init(labelsRead: 0, contentLabels: 0, complete: false,
                                               knowsLabel: false, placed: nil))
        XCTAssertNil(plan.panes)                                        // still hunts, as it must
        XCTAssertFalse(plan.because.contains("budget"), plan.because)
        XCTAssertTrue(plan.because.lowercased().contains("no accessibility map"), plan.because)
    }

    // MARK: - the extent sentence: a capped hunt must never read as proof of absence

    func testSkippedHuntSaysWhatWasAndWasNotSearched() {
        let ax = rich()
        let s = HuntPolicy.searched(ax: ax, plan: HuntPolicy.decide(ax: ax), panesAvailable: 4,
                                   walked: nil, seconds: nil, stoppedEarly: false)
        XCTAssertTrue(s.contains("278"), s)            // the map's size, so the claim can be judged
        XCTAssertTrue(s.contains("232"), s)            // and how much of it is content, which is the gate
        XCTAssertTrue(s.contains("0 of 4"), s)         // and the part of the app never looked at
        XCTAssertTrue(s.lowercased().contains("searched"), s)
        XCTAssertTrue(s.lowercased().contains("skipped"), s)
    }

    func testRanHuntNamesThePanesActuallyWalked() {
        let ax = HuntPolicy.AXVerdict(labelsRead: 0, contentLabels: 0, complete: true,
                                      knowsLabel: false, placed: nil)
        let s = HuntPolicy.searched(ax: ax, plan: HuntPolicy.decide(ax: ax), panesAvailable: 4,
                                   walked: 2, seconds: 12.4, stoppedEarly: true)
        XCTAssertTrue(s.contains("2 of 4"), s)
        XCTAssertTrue(s.contains("12.4s"), s)
        XCTAssertTrue(s.lowercased().contains("stopped"), s)   // an early stop is stated, never silent
    }

    func testAFullyWalkedHuntDoesNotClaimItStoppedEarly() {
        let ax = HuntPolicy.AXVerdict(labelsRead: 0, contentLabels: 0, complete: true,
                                      knowsLabel: false, placed: nil)
        let s = HuntPolicy.searched(ax: ax, plan: HuntPolicy.decide(ax: ax), panesAvailable: 3,
                                   walked: 3, seconds: 9.1, stoppedEarly: false)
        XCTAssertTrue(s.contains("3 of 3"), s)
        XCTAssertFalse(s.lowercased().contains("stopped"), s)
    }

    func testNoAXMapIsSaidPlainlyRatherThanCountedAsZeroLabels() {
        // "0 labels" reads like a map that was searched and found empty; the honest phrasing is that
        // there IS no map here to consult.
        let ax = HuntPolicy.AXVerdict(labelsRead: 0, contentLabels: 0, complete: true,
                                      knowsLabel: false, placed: nil)
        let s = HuntPolicy.searched(ax: ax, plan: HuntPolicy.decide(ax: ax), panesAvailable: 2,
                                   walked: 2, seconds: 8.0, stoppedEarly: false)
        XCTAssertFalse(s.contains("0 label"), s)
        XCTAssertTrue(s.lowercased().contains("no accessibility"), s)
    }

    func testTheHuntsPanesAreNotCalledScrollable() {
        // Measured live on Premiere: this sentence said "2 of 2 scrollable panes pixel-hunted" and the
        // guidance right after it said "no pane here advertises scrolling" — both true of DIFFERENT
        // things (the hunt's geometric candidates vs the map's advertised scrollers) and flatly
        // contradictory in one message. The hunt does not get to call its candidates scrollable; only
        // the map does, and it speaks in the "next:" clause.
        let ax = HuntPolicy.AXVerdict(labelsRead: 144, contentLabels: 5, complete: true,
                                      knowsLabel: false, placed: nil)
        let s = HuntPolicy.searched(ax: ax, plan: HuntPolicy.decide(ax: ax), panesAvailable: 2,
                                   walked: 2, seconds: 10.6, stoppedEarly: false)
        XCTAssertTrue(s.contains("2 of 2 panes"), s)
        XCTAssertFalse(s.contains("scrollable pane"), s)
    }

    func testAPartialCensusIsNeverQuotedAsTheMapsSize() {
        // A walk that STOPPED at the off-view match read only the part of the tree before it (measured
        // live: 57 labels of Resolve's 278). Printing that as "accessibility's map of it (57 labels)"
        // understates the map by 5x and invites the reader to judge the claim on a number that was never
        // the map. With a placement in hand the counts are not the evidence anyway — the placement is.
        let ax = HuntPolicy.AXVerdict(labelsRead: 57, contentLabels: 43, complete: false,
                                      knowsLabel: true, placed: .sideways)
        let s = HuntPolicy.searched(ax: ax, plan: HuntPolicy.decide(ax: ax), panesAvailable: 3,
                                   walked: nil, seconds: nil, stoppedEarly: false)
        XCTAssertFalse(s.contains("57"), s)
        XCTAssertFalse(s.contains("43"), s)
        XCTAssertTrue(s.lowercased().contains("places"), s)
    }

    func testAnUnfinishedCensusSaysItIsUnfinished() {
        // No placement, but the walk ran out of budget (Finder): the count IS worth reporting — it says
        // how far it got — and it must not read as the whole map.
        let ax = HuntPolicy.AXVerdict(labelsRead: 186, contentLabels: 146, complete: false,
                                      knowsLabel: false, placed: nil)
        let s = HuntPolicy.searched(ax: ax, plan: HuntPolicy.decide(ax: ax), panesAvailable: 3,
                                   walked: 3, seconds: 14.0, stoppedEarly: false)
        XCTAssertTrue(s.contains("186"), s)
        XCTAssertTrue(s.lowercased().contains("as far as"), s)
    }

    func testAWindowWithNoScrollablePaneDoesNotSayZeroOfZero() {
        // A static window (nothing in the map advertises scrolling) has no denominator to report, and
        // "0 of 0 panes" reads like a counting bug rather than the fact that there was nothing to walk.
        let ax = rich()
        let s = HuntPolicy.searched(ax: ax, plan: HuntPolicy.decide(ax: ax), panesAvailable: 0,
                                   walked: nil, seconds: nil, stoppedEarly: false)
        XCTAssertFalse(s.contains("0 of 0"), s)
        XCTAssertTrue(s.lowercased().contains("no pane"), s)
    }

    func testSidewaysSkipSaysTheAxisItCannotCover() {
        let ax = rich(knowsLabel: true, placed: .sideways)
        let s = HuntPolicy.searched(ax: ax, plan: HuntPolicy.decide(ax: ax), panesAvailable: 4,
                                   walked: nil, seconds: nil, stoppedEarly: false)
        XCTAssertTrue(s.lowercased().contains("sideways"), s)
        XCTAssertTrue(s.contains("0 of 4"), s)
    }
}
