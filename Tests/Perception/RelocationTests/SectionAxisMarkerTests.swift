import XCTest
import CoreGraphics
@testable import Relocation
import LocatorCore

/// The SIDEWAYS axis at the SCENE seam — where the sections, their names and the ledger meet, and where
/// the map line the agent actually reads is composed. Measured need: DaVinci's Deliver preset carousel
/// (the YouTube mis-render session) — a wide-short strip that slides horizontally, which the map never
/// mentioned, so the agent never tried `scroll(direction:"right")` and rendered with the wrong preset.
///
/// The strip is WIDE AND SHORT, which is why this can't ride on the vertical annotation: that one is
/// gated to tall panes (on a small slice, "flush with the edge" is meaningless — the edges are cuts
/// through content). Learned truth needs no such gate: someone really scrolled it.
final class SectionAxisMarkerTests: XCTestCase {

    private func freshMemory() -> LocatorMemory {
        LocatorMemory(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("axismark-\(UUID().uuidString)", isDirectory: true))
    }

    private func el(_ label: String, x: Double, y: Double, section: String,
                    w: Double = 0.09, h: Double = 0.02) -> SceneElement {
        var e = SceneElement(id: "\(section)/\(label)", kind: "text", label: label,
                            pos: [x, y, w, h], state: nil, unlabeled: nil)
        e.section = section
        return e
    }

    private let app = "test.axis.marker"

    /// DaVinci's Deliver page: a wide-short preset strip over a tall settings sidebar.
    private func deliverFrame() -> (sections: [SceneSection], elements: [SceneElement]) {
        let strip = "top bar", side = "sidebar (Render Settings)"
        let sections = [
            SceneSection(name: strip, pos: [0.0, 0.0, 1.0, 0.12]),
            SceneSection(name: side, pos: [0.0, 0.12, 0.22, 0.88]),
        ]
        // Presets sit SIDE BY SIDE in the strip — one row, no vertical list at all.
        let presets = ["H.264 Master", "YouTube 1080p", "Vimeo 1080p", "Pro Res 422", "Audio Only"]
        var elements = presets.enumerated().map { i, p in
            el(p, x: 0.04 + Double(i) * 0.14, y: 0.05, section: strip)
        }
        // The sidebar is an ordinary vertical list, complete, with slack below — it claims nothing.
        for (i, row) in ["Video", "Audio", "File", "Advanced Settings"].enumerated() {
            elements.append(el(row, x: 0.02, y: 0.16 + Double(i) * 0.05, section: side, w: 0.14))
        }
        return (sections, elements)
    }

    func testAProvenSidewaysStripCarriesTheAxisInTheMap() {
        let mem = freshMemory()
        mem.recordPane(app: app, role: "top bar", axis: "h", scrollable: true, pxPerTick: nil)
        var (sections, elements) = deliverFrame()
        SceneBuilder.annotateScrollability(sections: &sections, elements: elements, app: app, memory: mem)

        XCTAssertEqual(sections[0].scrollsX, "scrolls → (sideways) · learned")
        XCTAssertNil(sections[0].scrolls, "a sideways strip makes no VERTICAL claim")
        XCTAssertNil(sections[1].scrollsX, "the sidebar was never scrolled sideways")

        // What the agent reads.
        let map = SceneSnapshot(bundleID: app, app: app, windowTitle: "Deliver",
                                viewportPx: [1000, 800], elements: elements,
                                sections: sections, commands: []).mapText()
        let stripLine = map.split(separator: "\n").first { $0.hasPrefix("▣ top bar") }
        XCTAssertTrue(stripLine?.contains("scrolls →") == true, "got \(stripLine ?? "no line")")
        let sideLine = map.split(separator: "\n").first { $0.hasPrefix("▣ sidebar") }
        XCTAssertFalse(sideLine?.contains("→") == true, "the axis shows ONLY where recorded — got \(sideLine ?? "")")
    }

    /// The whole point of ticket 04, held for the new axis: nothing invents a sideways affordance. A
    /// frame with no ledger entry — which is every fixture, and every app on first contact — is silent.
    func testWithNothingLearnedNoSectionClaimsAnAxis() {
        let mem = freshMemory()
        var (sections, elements) = deliverFrame()
        SceneBuilder.annotateScrollability(sections: &sections, elements: elements, app: app, memory: mem)
        XCTAssertTrue(sections.allSatisfy { $0.scrollsX == nil },
                      "no visual heuristic for sideways exists — silence is the honest answer")
    }

    /// `consultMemory: false` (the offline fixture gate) drops the axis with the rest of the ledger:
    /// a machine-local learned verdict must never be what a perception fixture is really asserting.
    func testTheFixtureGateSeesNoLedgerTruth() {
        let mem = freshMemory()
        mem.recordPane(app: app, role: "top bar", axis: "h", scrollable: true, pxPerTick: nil)
        var (sections, elements) = deliverFrame()
        SceneBuilder.annotateScrollability(sections: &sections, elements: elements, app: app,
                                           consultMemory: false, memory: mem)
        XCTAssertTrue(sections.allSatisfy { $0.scrollsX == nil })
    }

    /// A pane proven static VERTICALLY but proven to slide sideways still gets to say the one true
    /// thing about it — the two axes are independent verdicts, not one.
    func testAVerticalNoDoesNotSilenceTheSidewaysYes() {
        let mem = freshMemory()
        mem.recordPane(app: app, role: "top bar", axis: "v", scrollable: false, pxPerTick: nil)
        mem.recordPane(app: app, role: "top bar", axis: "h", scrollable: true, pxPerTick: nil)
        var (sections, elements) = deliverFrame()
        SceneBuilder.annotateScrollability(sections: &sections, elements: elements, app: app, memory: mem)
        XCTAssertNil(sections[0].scrolls)
        XCTAssertEqual(sections[0].scrollsX, "scrolls → (sideways) · learned")
    }

    /// Vertical annotation is UNCHANGED by the axis pass: a truncated tall list still claims what it
    /// always claimed, on the same pane, in the same words.
    func testVerticalAnnotationIsUnchanged() {
        let mem = freshMemory()
        mem.recordPane(app: app, role: "top bar", axis: "h", scrollable: true, pxPerTick: nil)
        let name = "sidebar (Recents)"
        var sections = [SceneSection(name: name, pos: [0.0, 0.0, 0.17, 1.0]),
                        SceneSection(name: "top bar", pos: [0.17, 0.0, 0.83, 0.1])]
        let rows = ["Recents", "Shared", "Applications", "Documents", "Desktop", "Downloads",
                    "aaf", "iCloud Drive", "Google Drive", "ronaldozefi"]
        let elements = rows.enumerated().map { i, l in
            el(l, x: 0.03, y: 0.06 + Double(i) * 0.093, section: name, w: 0.12, h: 0.018)
        }
        SceneBuilder.annotateScrollability(sections: &sections, elements: elements, app: app, memory: mem)
        XCTAssertNotNil(sections[0].scrolls, "a list clipped by the real window edge still scrolls")
        XCTAssertNil(sections[0].scrollsX, "…and gains no axis it was never proven to have")
    }

    /// THE WRITE HALF, end to end: the pane a real sideways scroll moved is named from the labels that
    /// ARRIVED in the wheeled band (`ScrollAnnotator.sidewaysPaneToLearn`), recorded by that name, and
    /// read back by the map. This is the loop reach's AX-directed path now closes — before it, the engine
    /// scrolled DaVinci's preset strip sideways and the ledger stayed empty of horizontal rows.
    func testWhatASidewaysScrollLearnsIsWhatTheMapThenSays() {
        let mem = freshMemory()
        var (sections, elements) = deliverFrame()
        let strip = elements.filter { $0.section == "top bar" }
        // The band as the AX-directed step saw it: three presets before the wheel, five after.
        let before = Set(strip.prefix(3).map(\.label))
        guard let role = ScrollAnnotator.sidewaysPaneToLearn(bandBefore: before, bandNow: strip) else {
            return XCTFail("the arriving presets must name their pane")
        }
        XCTAssertEqual(role, "top bar")
        mem.recordPane(app: app, role: role, axis: "h", scrollable: true, pxPerTick: nil)

        SceneBuilder.annotateScrollability(sections: &sections, elements: elements, app: app, memory: mem)
        XCTAssertEqual(sections[0].scrollsX, "scrolls → (sideways) · learned")
        XCTAssertNil(sections[1].scrollsX, "only the pane that moved learned anything")
    }

    /// …and the same step on a pane that did NOT move writes nothing, so the map keeps its silence.
    func testAnUnmovedBandLeavesTheMapSilent() {
        let mem = freshMemory()
        var (sections, elements) = deliverFrame()
        let strip = elements.filter { $0.section == "top bar" }
        XCTAssertNil(ScrollAnnotator.sidewaysPaneToLearn(bandBefore: Set(strip.map(\.label)), bandNow: strip))
        SceneBuilder.annotateScrollability(sections: &sections, elements: elements, app: app, memory: mem)
        XCTAssertTrue(sections.allSatisfy { $0.scrollsX == nil })
    }

    /// The learned key is the CANONICAL role, exactly as `recordPane` writes it — so the strip's
    /// volatile header ("content (Deliver)" → "content") can't lose the truth on the next frame.
    func testTheAxisSurvivesAVolatileSectionHeader() {
        let mem = freshMemory()
        mem.recordPane(app: app, role: "content (Deliver)", axis: "h", scrollable: true, pxPerTick: nil)
        var sections = [SceneSection(name: "content (Deliver Video)", pos: [0.0, 0.0, 1.0, 0.14])]
        SceneBuilder.annotateScrollability(sections: &sections, elements: [], app: app, memory: mem)
        XCTAssertEqual(sections[0].scrollsX, "scrolls → (sideways) · learned")
    }
}

/// READ-HIT ACCOUNTING at the scene seam (ticket 02): the map is where the `scroll_pane` ledger most
/// often earns its keep, and where "the memory answered" is most easily confused with "the memory
/// changed what the agent was told". The sideways axis has no visual evidence path at all — that line
/// exists only because the ledger spoke — while the vertical axis has its own evidence, so a remembered
/// truth that merely agrees with the pixels changed nothing.
final class SceneReadHitTests: XCTestCase {
    private func countingMemory() -> LocatorMemory {
        LocatorMemory(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("scenereadhit-\(UUID().uuidString)", isDirectory: true),
                      countReads: true)
    }

    private func paneHit(_ m: LocatorMemory, app: String) -> ReadHit? {
        m.flushReadHits()
        return m.readHits().first { $0.store == MemoryStore.scrollPane.rawValue && $0.app == app }
    }

    private let app = "test.scene.readhits"

    private func strip() -> ([SceneSection], [SceneElement]) {
        let sections = [SceneSection(name: "top bar", pos: [0.0, 0.0, 1.0, 0.12])]
        var e = SceneElement(id: "top bar/H.264", kind: "text", label: "H.264 Master",
                             pos: [0.04, 0.05, 0.09, 0.02], state: nil, unlabeled: nil)
        e.section = "top bar"
        return (sections, [e])
    }

    func testTheLearnedSidewaysClaimCountsAsAReadThatChangedTheScene() {
        let m = countingMemory()
        m.recordPane(app: app, role: "top bar", axis: "h", scrollable: true, pxPerTick: nil)
        var (sections, elements) = strip()
        SceneBuilder.annotateScrollability(sections: &sections, elements: elements, app: app, memory: m)

        XCTAssertEqual(sections[0].scrollsX, "scrolls → (sideways) · learned")
        let h = paneHit(m, app: app)
        XCTAssertGreaterThanOrEqual(h?.consulted ?? 0, 1)
        XCTAssertEqual(h?.useful, 1, "the map line exists only because the ledger answered")
    }

    func testASceneThatLearnedNothingConsultsWithoutClaimingAHit() {
        let m = countingMemory()
        var (sections, elements) = strip()
        SceneBuilder.annotateScrollability(sections: &sections, elements: elements, app: app, memory: m)

        XCTAssertNil(sections[0].scrollsX)
        let h = paneHit(m, app: app)
        XCTAssertGreaterThanOrEqual(h?.consulted ?? 0, 1, "the ledger was still asked")
        XCTAssertEqual(h?.useful, 0)
    }

    /// `consultMemory: false` is the fixture gate's pure-perception mode — it must not consult, so it
    /// must not count either (a fixture run that moved the operator's read-hit numbers would be the
    /// same class of pollution ticket 01 removed).
    func testThePurePerceptionModeCountsNothing() {
        let m = countingMemory()
        m.recordPane(app: app, role: "top bar", axis: "h", scrollable: true, pxPerTick: nil)
        var (sections, elements) = strip()
        SceneBuilder.annotateScrollability(sections: &sections, elements: elements, app: app,
                                           consultMemory: false, memory: m)
        XCTAssertNil(paneHit(m, app: app))
    }
}
