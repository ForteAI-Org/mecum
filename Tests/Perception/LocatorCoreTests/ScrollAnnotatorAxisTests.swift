import XCTest
@testable import LocatorCore

/// The AXIS a section scrolls on, as the map says it. Vertical has two sources (ledger truth + visual
/// evidence); SIDEWAYS has exactly one — the ledger — because no visual heuristic for horizontal strips
/// exists and inventing one is how "scrolls ↓" once got advertised on a pane nothing could scroll.
/// Measured need: DaVinci's Deliver preset carousel, which an agent never tried scrolling sideways
/// because the map never said it could.
final class ScrollAnnotatorAxisTests: XCTestCase {

    // MARK: sideways — learned truth only, never inferred

    func testAProvenSidewaysPaneSaysSoWithTheArrow() {
        let mark = ScrollAnnotator.annotateSideways(learned: true)
        XCTAssertNotNil(mark)
        XCTAssertTrue(mark?.contains("scrolls →") == true, "the agent must read the axis — got \(mark ?? "nil")")
        XCTAssertTrue(mark?.contains("learned") == true, "provenance is stated — got \(mark ?? "nil")")
    }

    func testNeverProvenMeansSilence() {
        XCTAssertNil(ScrollAnnotator.annotateSideways(learned: nil),
                     "no evidence source exists for sideways — silence, not a guess")
        XCTAssertNil(ScrollAnnotator.annotateSideways(learned: false),
                     "a proven-static pane must never advertise an axis")
    }

    // MARK: the vertical claim is untouched — its wording, its sources, its silences

    func testVerticalWordingIsUnchanged() {
        let truncated = ScrollEvidence(listRows: 6, rowPitch: 0.04, moreBelow: true, moreAbove: false,
                                       likelyScrollsV: true, why: "list of 6 ends at the bottom edge")
        XCTAssertEqual(ScrollAnnotator.annotate(learned: nil, evidence: truncated),
                       "likely scrolls ↓ (more below) — list of 6 ends at the bottom edge")
        XCTAssertEqual(ScrollAnnotator.annotate(learned: true, evidence: truncated), "scrolls ↓ (more below) · learned")
        XCTAssertNil(ScrollAnnotator.annotate(learned: false, evidence: truncated),
                     "learned truth still outranks visual evidence both ways")
        XCTAssertNil(ScrollAnnotator.annotate(learned: nil, evidence: .none))
    }

    /// The two axes are two independent CLAIMS on the section, never one merged arrow: the vertical half
    /// can be a guess ("likely scrolls ↓") while sideways is only ever proven, and every existing
    /// consumer of the vertical field (the scroll verb's candidates, reach's ranking, the sibling
    /// ledger's listness test) means the vertical axis alone.
    func testTheAxesAreSeparateFields() {
        var s = SceneSection(name: "content (Deliver)", pos: [0, 0.1, 1, 0.12])
        XCTAssertNil(s.scrolls)
        XCTAssertNil(s.scrollsX)
        s.scrollsX = ScrollAnnotator.annotateSideways(learned: true)
        XCTAssertNil(s.scrolls, "a sideways strip must not enter the VERTICAL scroll paths")
        XCTAssertEqual(s.scrollsX, "scrolls → (sideways) · learned")
    }

    // MARK: the WRITE half — WHICH pane a sideways scroll just proved

    /// The map can only ever say "scrolls →" about a pane the ledger was TOLD about, and the one path
    /// that really slides DaVinci's preset carousel is reach's AX-directed branch (AX knows the target
    /// sits right of its container; the section-level verb wheels the settings form at its centre and
    /// no-ops). That branch scrolls a BAND of an AX container — a band wide enough to cross several map
    /// sections — so naming the pane it moved is the whole write half of the marker, and this is it.
    ///
    /// It is named from the LABELS, never from geometry: the elements that ARRIVED in the band belong to
    /// the pane whose content moved, whatever else the band overlaps.

    private func el(_ label: String, section: String?) -> SceneElement {
        var e = SceneElement(id: "\(section ?? "-")/\(label)", kind: "text", label: label,
                            pos: [0.1, 0.2, 0.09, 0.02], state: nil, unlabeled: nil)
        e.section = section
        return e
    }

    private let strip = "content (Render Settings)"

    func testTheArrivingLabelsNameTheirPane() {
        let before: Set<String> = ["H.264 Master", "YouTube 1080p"]
        let now = [el("YouTube 1080p", section: strip), el("Vimeo 1080p", section: strip),
                   el("Audio Only", section: strip)]
        XCTAssertEqual(ScrollAnnotator.sidewaysPaneToLearn(bandBefore: before, bandNow: now), strip)
    }

    /// POSITIVE ONLY, exactly like the verb path's writer: an unchanged band is ambiguous between "this
    /// pane doesn't scroll" and "it is at its end", and since nothing infers a sideways affordance, a
    /// recorded no could only ever erase a truth an earlier real scroll proved.
    func testAnUnchangedBandLearnsNothing() {
        let items = [el("H.264 Master", section: strip), el("YouTube 1080p", section: strip)]
        XCTAssertNil(ScrollAnnotator.sidewaysPaneToLearn(bandBefore: Set(items.map(\.label)), bandNow: items),
                     "nothing moved — no row, in either direction")
    }

    /// No before side, no claim. The witness has to be a comparison the caller actually measured; an
    /// absent one must not read as "everything is new".
    func testWithNoBeforeSideNothingIsLearned() {
        XCTAssertNil(ScrollAnnotator.sidewaysPaneToLearn(bandBefore: nil,
                                                          bandNow: [el("Audio Only", section: strip)]))
    }

    /// THE CASE THAT MATTERS. The AX container is the whole 449×754 render-settings panel (Qt exposes no
    /// tighter node), so the band crosses the static settings form as well as the carousel. The form's
    /// rows outnumber the strip's — and the strip is still the pane that moved, because the new labels
    /// are its.
    func testTheNewLabelsOutrankTheBandsMajority() {
        let form = "content (Render Settings)", presets = "region 6 (presets)"
        let before: Set<String> = ["Filename", "Location", "Format", "Codec", "Resolution", "H.264 Master"]
        let now = [el("Filename", section: form), el("Location", section: form), el("Format", section: form),
                   el("Codec", section: form), el("Resolution", section: form),
                   el("Vimeo 1080p", section: presets), el("Audio Only", section: presets)]
        XCTAssertEqual(ScrollAnnotator.sidewaysPaneToLearn(bandBefore: before, bandNow: now), presets,
                       "the pane whose content ARRIVED is the pane that scrolled")
    }

    /// A band straddling two panes that both changed cannot name one — and a wrong name would advertise
    /// sideways scrolling on a pane that has none, the exact failure ledger-only was chosen to avoid.
    func testASplitBandStaysSilent() {
        let now = [el("Vimeo 1080p", section: "content (Render Settings)"),
                   el("Timeline 2", section: "region 7")]
        XCTAssertNil(ScrollAnnotator.sidewaysPaneToLearn(bandBefore: ["H.264 Master"], bandNow: now),
                     "no majority — silence beats a guess")
    }

    /// A strip can slide so its items LEAVE the band without new ones arriving (the last screenful of a
    /// carousel). Something moved, and the band's remaining content still names the pane.
    func testItemsOnlyLeavingStillNamesThePane() {
        let before: Set<String> = ["H.264 Master", "YouTube 1080p", "Vimeo 1080p", "TikTok 1080p"]
        let now = [el("Vimeo 1080p", section: strip), el("TikTok 1080p", section: strip)]
        XCTAssertEqual(ScrollAnnotator.sidewaysPaneToLearn(bandBefore: before, bandNow: now), strip)
    }

    /// ONE changed label is not a slide — it is a LIVE READOUT. Deliver's own page carries "13%",
    /// "Completed in 00:01:21" and a running timecode, and a band is a ROW of an AX container, so any of
    /// them can sit in it and re-label itself every few hundred ms while nothing scrolls. Taking that as
    /// evidence would advertise a sideways axis on a pane that never moved — the one thing this marker
    /// must never do.
    func testATickingReadoutIsNotASlide() {
        let before: Set<String> = ["Job 2", "Completed in 00:01:20", "Render 1"]
        let now = [el("Job 2", section: strip), el("Completed in 00:01:21", section: strip),
                   el("Render 1", section: strip)]
        XCTAssertNil(ScrollAnnotator.sidewaysPaneToLearn(bandBefore: before, bandNow: now),
                     "a single re-labelled readout must not become a learned axis")
    }

    /// A pane the map cannot name is a pane the agent cannot pass to `scroll(section:)`.
    func testUnsectionedLabelsAreNotAPane() {
        XCTAssertNil(ScrollAnnotator.sidewaysPaneToLearn(bandBefore: ["H.264 Master"],
                                                          bandNow: [el("Audio Only", section: nil)]))
        XCTAssertNil(ScrollAnnotator.sidewaysPaneToLearn(bandBefore: ["H.264 Master"], bandNow: []),
                     "the band is empty now — nothing to key the ledger on")
    }
}
