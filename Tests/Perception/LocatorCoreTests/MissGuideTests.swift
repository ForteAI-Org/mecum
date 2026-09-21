import XCTest
import CoreGraphics
@testable import LocatorCore

/// THE NEXT MOVE IN A MISS. Measured failure: an agent re-clicked a phantom 4× with no strategy
/// change, then shipped the wrong render preset — because `honest_miss` / `acted_unverified` said
/// what did NOT happen and never what the engine already knew to try. This composer is that
/// knowledge turned into ONE sentence: the axis a pane scrolls on, where AX says the target hides,
/// and whether anything moved elsewhere. Pure, so the wording is pinned offline; the strings it
/// appends are asserted live in the ticket's replays.
final class MissGuideTests: XCTestCase {

    // MARK: direction — the same geometry reach steers by

    func testAnOffViewTargetRightOfItsContainerReadsAsSideways() {
        // DaVinci's Deliver carousel, measured: container 32…481pt, "YouTube 1080p" virtually at 520.
        let way = MissGuide.way(target: CGRect(x: 500, y: 300, width: 90, height: 24),
                                container: CGRect(x: 32, y: 280, width: 449, height: 60))
        XCTAssertTrue(way.horizontal)
        XCTAssertEqual(way.word, "right")
        XCTAssertEqual(way.arrow, "→")
    }

    func testAnOffViewTargetBelowItsContainerReadsAsVertical() {
        let way = MissGuide.way(target: CGRect(x: 40, y: 900, width: 120, height: 20),
                                container: CGRect(x: 32, y: 100, width: 300, height: 500))
        XCTAssertFalse(way.horizontal)
        XCTAssertEqual(way.word, "down")
        XCTAssertEqual(way.arrow, "↓")
    }

    func testLeftAndUpAreNamedToo() {
        XCTAssertEqual(MissGuide.way(target: CGRect(x: -200, y: 300, width: 80, height: 20),
                                     container: CGRect(x: 32, y: 280, width: 449, height: 60)).word, "left")
        XCTAssertEqual(MissGuide.way(target: CGRect(x: 40, y: -300, width: 80, height: 20),
                                     container: CGRect(x: 32, y: 100, width: 300, height: 500)).word, "up")
    }

    // MARK: naming the container — the pane the agent must act on, in the words the map uses

    func testTheContainerIsNamedWithTheSectionItOverlaps() {
        let win = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let sections = [SceneSection(name: "sidebar", pos: [0, 0, 0.19, 1]),
                        SceneSection(name: "content (Deliver)", pos: [0.19, 0, 0.81, 1])]
        XCTAssertEqual(MissGuide.containerName(CGRect(x: 200, y: 100, width: 700, height: 600),
                                               windowFrame: win, sections: sections),
                       "content (Deliver)")
    }

    func testAContainerNoSectionCoversIsNotGivenAFakeName() {
        let win = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let sections = [SceneSection(name: "sidebar", pos: [0, 0, 0.19, 1])]
        XCTAssertNil(MissGuide.containerName(CGRect(x: 500, y: 100, width: 400, height: 600),
                                             windowFrame: win, sections: sections),
                     "a made-up pane name is worse than none — the agent would target a section that isn't there")
    }

    /// THE MEASURED SHAPE: AX exposes no tight node around DaVinci's carousel, so its container is the
    /// whole settings panel and NO section covers it. The band — the target's own row across that
    /// container — does land inside one, which is the name the agent can pass to scroll(section:).
    func testAWideContainerIsNamedByTheBandTheTargetSitsIn() {
        let win = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let sections = [SceneSection(name: "toolbar", pos: [0, 0, 1, 0.1]),
                        SceneSection(name: "presets", pos: [0, 0.3, 1, 0.2]),
                        SceneSection(name: "settings", pos: [0, 0.5, 1, 0.5])]
        // Container = the whole panel (y 80…800); the target's row sits at y≈280, inside "presets".
        let off = MissGuide.OffView(label: "YouTube 1080p",
                                    frame: CGRect(x: 1200, y: 280, width: 90, height: 24),
                                    container: CGRect(x: 0, y: 80, width: 900, height: 720))
        let w = MissGuide.way(target: off.frame, container: off.container)
        XCTAssertTrue(w.horizontal, "hidden sideways — the band must be its ROW")
        XCTAssertEqual(MissGuide.containerName(off.container, windowFrame: win, sections: sections), "settings",
                       "the raw container's 'best cover' is a pane the target is NOT in — which is why the band is named instead")
        let g = try! XCTUnwrap(MissGuide.forMissedTarget(target: "YouTube 1080p", sections: sections,
                                                        offView: off, windowFrame: win, suggestReach: false))
        XCTAssertTrue(g.contains("presets"), "the band's section is the actionable name — got \(g)")
        XCTAssertTrue(g.contains("scroll(section:\"presets\", direction:\"right\")"),
                      "and it must be spelled as a call the agent can make — got \(g)")
    }

    // MARK: (c) a target findOffView knows — the miss names the container AND the direction

    func testAKnownOffViewTargetNamesTheContainerAndTheDirection() {
        let win = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let sections = [SceneSection(name: "content (Deliver)", pos: [0.19, 0, 0.81, 1])]
        let g = MissGuide.forMissedTarget(
            target: "YouTube 1080p",
            sections: sections,
            // Measured: container 200…500pt wide on screen, the preset virtually at 520 — just right of it.
            offView: MissGuide.OffView(label: "YouTube 1080p",
                                       frame: CGRect(x: 520, y: 300, width: 90, height: 24),
                                       container: CGRect(x: 200, y: 280, width: 300, height: 60)),
            windowFrame: win,
            suggestReach: true)
        let s = try! XCTUnwrap(g)
        XCTAssertTrue(s.contains("content (Deliver)"), "names the container — got \(s)")
        XCTAssertTrue(s.contains("right"), "names the direction — got \(s)")
        XCTAssertTrue(s.contains("reach("), "names the verb that acts on it — got \(s)")
        XCTAssertEqual(s.filter { $0 == "." }.count, 1, "ONE sentence — prompt cost is the budget: \(s)")
    }

    // MARK: (a) an off-view carousel item — the axis marker alone is enough to name the move

    func testASidewaysSectionSaysScrollRightEvenWithNoAXAtAll() {
        var strip = SceneSection(name: "content", pos: [0.19, 0.4, 0.81, 0.12])
        strip.scrollsX = ScrollAnnotator.annotateSideways(learned: true)
        let g = try! XCTUnwrap(MissGuide.forMissedTarget(target: "YouTube 1080p", sections: [strip],
                                                        offView: nil, windowFrame: nil, suggestReach: true))
        XCTAssertTrue(g.contains("right"), "the sideways axis IS the next move — got \(g)")
        XCTAssertTrue(g.contains("content"), "names the pane — got \(g)")
        XCTAssertTrue(g.contains("scroll("), "names the verb, since reach's vision hunt is vertical — got \(g)")
    }

    func testAVerticalScrollerPointsAtReach() {
        var pane = SceneSection(name: "files", pos: [0.2, 0, 0.8, 1])
        pane.scrolls = "scrolls ↓ (more below) · learned"
        let g = try! XCTUnwrap(MissGuide.forMissedTarget(target: "Renders", sections: [pane],
                                                         offView: nil, windowFrame: nil, suggestReach: true))
        XCTAssertTrue(g.contains("files"))
        XCTAssertTrue(g.contains("reach("), "reach owns the vertical hunt — got \(g)")
    }

    func testWhenNothingScrollsTheGuidanceSaysSoInsteadOfSendingTheAgentScrolling() {
        let g = try! XCTUnwrap(MissGuide.forMissedTarget(target: "Renders",
                                                         sections: [SceneSection(name: "toolbar", pos: [0, 0, 1, 0.1])],
                                                         offView: nil, windowFrame: nil, suggestReach: true))
        XCTAssertFalse(g.contains("reach("), "no pane scrolls — reach is a wasted round, and saying so IS the guidance: \(g)")
        XCTAssertTrue(g.lowercased().contains("scroll"), "it must name what it ruled out — got \(g)")
    }

    /// After reach itself has missed, "call reach" is the advice that just failed. The pane and the
    /// axis stay useful; the verb changes to the one the agent hasn't spent.
    func testAfterReachHasMissedItNeverSuggestsReachAgain() {
        var pane = SceneSection(name: "files", pos: [0.2, 0, 0.8, 1])
        pane.scrolls = "scrolls ↓ (more below) · learned"
        let g = try! XCTUnwrap(MissGuide.forMissedTarget(target: "Renders", sections: [pane],
                                                         offView: nil, windowFrame: nil, suggestReach: false))
        XCTAssertFalse(g.contains("reach("), "reach already missed — got \(g)")
        XCTAssertTrue(g.contains("scroll("), "the unspent verb — got \(g)")
    }

    // MARK: ticket 15 — guidance the agent can FOLLOW, never a call already proven not to work

    /// THE MEASURED DEFECT: minutes after `scroll(section:"content (Render Settings)", direction:"right")`
    /// answered `acted_noop`, a miss on the same window recommended that exact call again. Guidance the
    /// agent cannot follow is worse than none — it turns one wasted round into two and teaches the agent
    /// to distrust the one channel meant to end the flailing.
    func testAScrollAlreadyProvenToNoOpIsNeverRecommendedAgain() {
        let win = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let sections = [SceneSection(name: "content (Render Settings)", pos: [0.19, 0, 0.81, 1])]
        let off = MissGuide.OffView(label: "Pro Tools",
                                   frame: CGRect(x: 520, y: 300, width: 90, height: 24),
                                   container: CGRect(x: 200, y: 280, width: 300, height: 60))
        let dead: Set<MissGuide.DeadScroll> = [.init(section: "content (Render Settings)", direction: "right")]
        let g = try! XCTUnwrap(MissGuide.forMissedTarget(
            target: "Pro Tools", sections: sections, offView: off, windowFrame: win,
            suggestReach: false, deadScrolls: dead))
        XCTAssertFalse(g.contains("scroll(section:"),
                       "that call already answered acted_noop on this pane — recommending it costs a round: \(g)")
        XCTAssertTrue(g.contains("Pro Tools") && g.contains("content (Render Settings)"),
                      "the placement is still worth reporting — only the dead gesture is dropped: \(g)")
        XCTAssertEqual(g.filter { $0 == "." }.count, 1, "ONE sentence — prompt cost is the budget: \(g)")
    }

    /// A no-op is DIRECTIONAL. "at its right end" says nothing about scrolling left, so a right no-op
    /// must not silence the left recommendation — withholding a true next move is the same failure in
    /// the other direction.
    func testANoOpInOneDirectionDoesNotSilenceTheOther() {
        let win = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let sections = [SceneSection(name: "presets", pos: [0.19, 0, 0.81, 1])]
        // The target hides to the LEFT; the ledger only knows a RIGHT no-op.
        let off = MissGuide.OffView(label: "H.264",
                                   frame: CGRect(x: -60, y: 300, width: 90, height: 24),
                                   container: CGRect(x: 200, y: 280, width: 300, height: 60))
        let g = try! XCTUnwrap(MissGuide.forMissedTarget(
            target: "H.264", sections: sections, offView: off, windowFrame: win,
            suggestReach: false, deadScrolls: [.init(section: "presets", direction: "right")]))
        XCTAssertTrue(g.contains("scroll(section:\"presets\", direction:\"left\")"),
                      "a right no-op says nothing about left — got \(g)")
    }

    /// reach owns the sub-container the section-level wheel cannot reach (ticket 14), so a learned
    /// section-scroll no-op is not a reason to stop naming reach. Ticket 09's advice must survive.
    func testALearnedScrollNoOpStillLeavesReachAsTheAdvice() {
        let win = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let sections = [SceneSection(name: "content (Render Settings)", pos: [0.19, 0, 0.81, 1])]
        let off = MissGuide.OffView(label: "YouTube 1080p",
                                   frame: CGRect(x: 520, y: 300, width: 90, height: 24),
                                   container: CGRect(x: 200, y: 280, width: 300, height: 60))
        let g = try! XCTUnwrap(MissGuide.forMissedTarget(
            target: "YouTube 1080p", sections: sections, offView: off, windowFrame: win,
            suggestReach: true,
            deadScrolls: [.init(section: "content (Render Settings)", direction: "right")]))
        XCTAssertTrue(g.contains("reach("), "reach is the gesture that DOES move that strip — got \(g)")
    }

    /// THE SELF-CONTRADICTION: one line reported the directed attempt's failure and then asserted
    /// "accessibility PLACES 'Pro Tools' right of ▣ …". Both halves came from the same binary in the
    /// same breath; the agent had no way to tell which to believe. A placement the engine's own
    /// AX-directed scroll could not act on is a map entry, not a fact about the screen.
    func testAPlacementTheDirectedScrollCouldNotMoveIsNotStatedAsFact() {
        let win = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let sections = [SceneSection(name: "content (Render Settings)", pos: [0.19, 0, 0.81, 1])]
        let off = MissGuide.OffView(label: "Pro Tools",
                                   frame: CGRect(x: 520, y: 300, width: 90, height: 24),
                                   container: CGRect(x: 200, y: 280, width: 300, height: 60))
        let g = try! XCTUnwrap(MissGuide.forMissedTarget(
            target: "Pro Tools", sections: sections, offView: off, windowFrame: win,
            suggestReach: false, directedStuck: true))
        XCTAssertFalse(g.contains("accessibility places"),
                       "the engine just failed to act on that placement — asserting it is the contradiction: \(g)")
        XCTAssertTrue(g.contains("accessibility lists"), "hedged to what it is — a map entry: \(g)")
        XCTAssertFalse(g.contains("scroll(section:"),
                       "the pane did not budge for the directed scroll; the section-level one aims worse: \(g)")
        XCTAssertEqual(g.filter { $0 == "." }.count, 1, "ONE sentence: \(g)")
    }

    /// The hedge is EVIDENCE-DRIVEN, not a blanket downgrade: with no failed attempt against it, the
    /// placement is still the strongest fact the engine has and still reads as one.
    func testWithNoFailedAttemptThePlacementIsStillStatedPlainly() {
        let win = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let sections = [SceneSection(name: "content (Render Settings)", pos: [0.19, 0, 0.81, 1])]
        let off = MissGuide.OffView(label: "Pro Tools",
                                   frame: CGRect(x: 520, y: 300, width: 90, height: 24),
                                   container: CGRect(x: 200, y: 280, width: 300, height: 60))
        let g = try! XCTUnwrap(MissGuide.forMissedTarget(
            target: "Pro Tools", sections: sections, offView: off, windowFrame: win, suggestReach: false))
        XCTAssertTrue(g.contains("accessibility places"), "nothing refutes it — got \(g)")
        XCTAssertTrue(g.contains("scroll(section:\"content (Render Settings)\", direction:\"right\")"),
                      "and the unspent verb is still named — got \(g)")
    }

    /// A dead end must still be a NEXT MOVE. Naming what is spent without naming anything to try is
    /// how an agent starts guessing again — the failure this composer exists to end.
    func testADeadEndStillNamesSomethingToTry() {
        let win = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let sections = [SceneSection(name: "presets", pos: [0.19, 0, 0.81, 1])]
        let off = MissGuide.OffView(label: "Pro Tools",
                                   frame: CGRect(x: 520, y: 300, width: 90, height: 24),
                                   container: CGRect(x: 200, y: 280, width: 300, height: 60))
        let g = try! XCTUnwrap(MissGuide.forMissedTarget(
            target: "Pro Tools", sections: sections, offView: off, windowFrame: win,
            suggestReach: false, directedStuck: true))
        XCTAssertTrue(g.contains("manage_window"), "a real lever on a strip too narrow to show it — got \(g)")
    }

    /// A strip with nothing left to give must not be reported as a window that does not scroll. Branch 4
    /// exists to stop scroll-hunting a static window; firing it here would be the same lie in reverse.
    func testAStripSpentBothWaysIsNotReportedAsAWindowThatDoesNotScroll() {
        var strip = SceneSection(name: "content", pos: [0.19, 0.4, 0.81, 0.12])
        strip.scrollsX = ScrollAnnotator.annotateSideways(learned: true)
        let dead: Set<MissGuide.DeadScroll> = [.init(section: "content", direction: "right"),
                                              .init(section: "content", direction: "left")]
        let g = try! XCTUnwrap(MissGuide.forMissedTarget(target: "Pro Tools", sections: [strip],
                                                        offView: nil, windowFrame: nil,
                                                        suggestReach: true, deadScrolls: dead))
        XCTAssertFalse(g.contains("scroll(section:\""), "both directions are spent — got \(g)")
        XCTAssertFalse(g.contains("no pane here advertises scrolling"),
                       "it DOES slide sideways; it just has nothing left to give — got \(g)")
        XCTAssertTrue(g.contains("content"), "still names the pane it ruled out — got \(g)")
        // FOUND LIVE, in this ticket's own verification: with the section verb spent both ways the guide
        // had stopped naming `reach` — which drives that very pane every time (it aims inside it). Losing
        // the one gesture that works is this ticket's defect in reverse.
        XCTAssertTrue(g.contains("reach("), "reach still drives that pane — got \(g)")
    }

    /// …and once reach has missed too, there is nothing left to name and it says so.
    func testAStripSpentBothWaysAfterReachMissedNamesNoVerbAtAll() {
        var strip = SceneSection(name: "content", pos: [0.19, 0.4, 0.81, 0.12])
        strip.scrollsX = ScrollAnnotator.annotateSideways(learned: true)
        let dead: Set<MissGuide.DeadScroll> = [.init(section: "content", direction: "right"),
                                              .init(section: "content", direction: "left")]
        let g = try! XCTUnwrap(MissGuide.forMissedTarget(target: "Pro Tools", sections: [strip],
                                                        offView: nil, windowFrame: nil,
                                                        suggestReach: false, deadScrolls: dead))
        XCTAssertFalse(g.contains("reach("), "reach is the verb that just failed — got \(g)")
        XCTAssertFalse(g.contains("scroll(section:\""), "and the scroll is spent both ways — got \(g)")
    }

    /// Same rule on the vertical axis, and it applies to the direction as well as the pane: a `down`
    /// already proven inert must become `up`, not another `down`.
    func testAVerticalNoOpFlipsTheDirectionRatherThanRepeatingIt() {
        var pane = SceneSection(name: "files", pos: [0.2, 0, 0.8, 1])
        pane.scrolls = "scrolls ↓ (more below) · learned"
        let g = try! XCTUnwrap(MissGuide.forMissedTarget(
            target: "Renders", sections: [pane], offView: nil, windowFrame: nil, suggestReach: false,
            deadScrolls: [.init(section: "files", direction: "down")]))
        XCTAssertTrue(g.contains("direction:\"up\""), "down is spent — got \(g)")
        XCTAssertFalse(g.contains("direction:\"down\""), "got \(g)")
    }

    func testAVerticalPaneSpentBothWaysStopsNamingTheScroll() {
        var pane = SceneSection(name: "files", pos: [0.2, 0, 0.8, 1])
        pane.scrolls = "scrolls ↓ (more below) · learned"
        let g = try! XCTUnwrap(MissGuide.forMissedTarget(
            target: "Renders", sections: [pane], offView: nil, windowFrame: nil, suggestReach: false,
            deadScrolls: [.init(section: "files", direction: "down"), .init(section: "files", direction: "up")]))
        XCTAssertFalse(g.contains("scroll(section:"), "nothing unspent left to name — got \(g)")
        XCTAssertTrue(g.contains("files"), "got \(g)")
    }

    // MARK: (b) a dead click — nothing changed ANYWHERE, vs something changed elsewhere

    func testANewWindowElsewhereIsNamedAsWhatDidChange() {
        let before = [MissGuide.WindowSig(id: 1, title: "Project", layer: 0, size: CGSize(width: 1200, height: 800))]
        let after = before + [MissGuide.WindowSig(id: 2, title: "Export Settings", layer: 8,
                                                 size: CGSize(width: 815, height: 124))]
        let g = MissGuide.forUnverifiedAct(app: "Resolve", before: before, after: after).sentence
        XCTAssertTrue(g.contains("Export Settings"), "the window that DID appear is the answer — got \(g)")
    }

    func testAPopUpOpeningCountsAsSomethingHavingChanged() {
        let before = [MissGuide.WindowSig(id: 1, title: "Project", layer: 0, size: CGSize(width: 1200, height: 800))]
        let after = before + [MissGuide.WindowSig(id: 9, title: nil, layer: 101,
                                                 size: CGSize(width: 129, height: 197))]
        let g = MissGuide.forUnverifiedAct(app: "Resolve", before: before, after: after).sentence
        XCTAssertTrue(g.lowercased().contains("pop-up"), "an opened menu is the effect — got \(g)")
    }

    func testAWindowLayerDropdownIsCalledAPopUpNotANewWindow() {
        // DaVinci Resolve's resolution list is a dropdown on an ORDINARY window layer (ticket 12), so
        // the layer range below cannot recognise it — the CAPTURE layer classified it and said so with
        // `isPopup`. Without that flag this read "a NEW window 260×420pt appeared" and sent the agent
        // looking for a window when what opened was a list to read.
        let before = [MissGuide.WindowSig(id: 1, title: "tracks", layer: 0, size: CGSize(width: 1360, height: 714))]
        let after = before + [MissGuide.WindowSig(id: 7, title: nil, layer: 0,
                                                 size: CGSize(width: 260, height: 420), isPopup: true)]
        let g = MissGuide.forUnverifiedAct(app: "DaVinci Resolve", before: before, after: after).sentence
        XCTAssertTrue(g.lowercased().contains("pop-up"), "got \(g)")
        XCTAssertFalse(g.contains("NEW window"), "got \(g)")
    }

    func testAnUnflaggedWindowOnAnOrdinaryLayerIsStillANewWindow() {
        // The flag is evidence, not a licence to guess: with no classifier verdict the wording stays
        // exactly as it was.
        let before = [MissGuide.WindowSig(id: 1, title: "tracks", layer: 0, size: CGSize(width: 1360, height: 714))]
        let after = before + [MissGuide.WindowSig(id: 7, title: "Project Settings", layer: 0,
                                                 size: CGSize(width: 1040, height: 736))]
        let g = MissGuide.forUnverifiedAct(app: "DaVinci Resolve", before: before, after: after).sentence
        XCTAssertTrue(g.contains("NEW window"), "got \(g)")
    }

    func testAWindowThatVanishedIsReported() {
        let before = [MissGuide.WindowSig(id: 1, title: "Project", layer: 0, size: CGSize(width: 1200, height: 800)),
                      MissGuide.WindowSig(id: 2, title: "Export Settings", layer: 8, size: CGSize(width: 815, height: 124))]
        let after = [before[0]]
        let g = MissGuide.forUnverifiedAct(app: "Resolve", before: before, after: after).sentence
        XCTAssertTrue(g.contains("Export Settings") && g.lowercased().contains("closed"), "got \(g)")
    }

    /// The flag, not just the wording: the act handler drops its own "the click likely did not
    /// register" guess when this says something DID change, so the two can never print side by side.
    func testTheChangedFlagTracksTheFact() {
        let a = [MissGuide.WindowSig(id: 1, title: "Project", layer: 0, size: CGSize(width: 1200, height: 800))]
        let b = a + [MissGuide.WindowSig(id: 2, title: "Export Settings", layer: 8, size: CGSize(width: 815, height: 124))]
        XCTAssertTrue(MissGuide.forUnverifiedAct(app: "Resolve", before: a, after: b).changed)
        XCTAssertFalse(MissGuide.forUnverifiedAct(app: "Resolve", before: a, after: a).changed)
    }

    func testNothingAnywhereIsStatedAsAFactNotLeftToSpeculation() {
        let same = [MissGuide.WindowSig(id: 1, title: "Project", layer: 0, size: CGSize(width: 1200, height: 800))]
        let g = MissGuide.forUnverifiedAct(app: "Resolve", before: same, after: same).sentence
        XCTAssertTrue(g.lowercased().contains("nothing"), "a dead click must be NAMED dead — got \(g)")
    }

    /// The signature must not turn LIVE CHROME into news: a window that merely resized (a canvas
    /// repainting its own bounds, a meter strip) is not an effect the click caused elsewhere.
    func testAResizeAloneIsNotAnEffectElsewhere() {
        let before = [MissGuide.WindowSig(id: 1, title: "Project", layer: 0, size: CGSize(width: 1200, height: 800))]
        let after = [MissGuide.WindowSig(id: 1, title: "Project", layer: 0, size: CGSize(width: 1201, height: 800))]
        let g = MissGuide.forUnverifiedAct(app: "Resolve", before: before, after: after).sentence
        XCTAssertTrue(g.lowercased().contains("nothing"), "a 1pt reflow is not an effect — got \(g)")
    }

    func testATitleChangeOnTheSameWindowIsAnEffect() {
        let before = [MissGuide.WindowSig(id: 1, title: "Untitled", layer: 0, size: CGSize(width: 1200, height: 800))]
        let after = [MissGuide.WindowSig(id: 1, title: "Renders", layer: 0, size: CGSize(width: 1200, height: 800))]
        let g = MissGuide.forUnverifiedAct(app: "Resolve", before: before, after: after).sentence
        XCTAssertTrue(g.contains("Renders"), "a retitled window is a navigation — got \(g)")
    }
}
