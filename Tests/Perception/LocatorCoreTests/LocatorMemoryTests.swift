import XCTest
@testable import LocatorCore

final class LocatorMemoryTests: XCTestCase {
    private func freshMemory() -> LocatorMemory {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("locmem-\(UUID().uuidString)", isDirectory: true)
        return LocatorMemory(directory: dir)
    }

    func testSightingUpsertIncrementsSeenAndSurvivesOCRJunk() {
        let m = freshMemory()
        m.recordSightings(app: "slack", items: [("z Fritz", "sidebar (Connessioni esterne)", 0.15, 0.7)])
        m.recordSightings(app: "slack", items: [("Ze Fritz", "sidebar (Connessioni esterne)", 0.15, 0.72)])
        // queried with a DIFFERENT junk prefix — the core survives ("z/Ze Fritz" ≡ "fritz")
        let s = m.sighting(app: "slack", target: "fritz")
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.seen, 2)
        XCTAssertEqual(s?.section, "sidebar")   // volatile header stripped → canonical role
    }

    func testCanonicalSectionCollapsesVolatileHeaders() {
        XCTAssertEqual(LocatorMemory.canonicalSection("content (Sabato 4 luglio v)"), "content")
        XCTAssertEqual(LocatorMemory.canonicalSection("content #2"), "content")
        XCTAssertEqual(LocatorMemory.canonicalSection("sidebar (Connessioni esterne)"), "sidebar")
        XCTAssertEqual(LocatorMemory.canonicalSection("nav rail (Home)"), "nav rail")
        XCTAssertEqual(LocatorMemory.canonicalSection("bottom bar"), "bottom bar")
        XCTAssertEqual(LocatorMemory.canonicalSection("region 3"), "region")
        XCTAssertNil(LocatorMemory.canonicalSection(nil))
        XCTAssertNil(LocatorMemory.canonicalSection(""))
        XCTAssertNil(LocatorMemory.canonicalSection("Q Cerca Forte AI"))   // volatile-header cruft → unknown
        XCTAssertNil(LocatorMemory.canonicalSection("Oggi v"))
    }

    // MARK: remembered no-ops (ticket 15 — never recommend a gesture already proven inert)

    /// The whole point of a SEPARATE column: a sideways no-op must be remembered WITHOUT denying the
    /// affordance a real scroll once proved. `scrollable` cannot carry it (nothing can re-infer a
    /// horizontal affordance, so a recorded denial is unrecoverable), and the guide still needs to know
    /// this exact call moved nothing.
    func testASidewaysNoOpIsRememberedWithoutErasingTheProvenAffordance() {
        let m = freshMemory()
        m.recordPane(app: "resolve", role: "content (Render Settings)", axis: "h", scrollable: true, pxPerTick: nil)
        m.recordPaneNoop(app: "resolve", role: "content (Render Settings)", axis: "h", direction: "right")
        XCTAssertEqual(m.paneNoopDirections(app: "resolve", role: "content", axis: "h"), ["right"])
        XCTAssertEqual(m.paneScrollable(app: "resolve", role: "content", axis: "h"), true,
                       "the proven affordance survives — only the spent gesture is recorded")
    }

    /// CAUGHT IN REVIEW, and the worst bug this ticket could have shipped: `SceneBuilder` turns
    /// `paneScrollable(axis: "h") == true` directly into the map's `scrolls → (sideways) · learned`
    /// claim, whose only legitimate source is a horizontal scroll that MOVED. A fresh row seeded with
    /// `scrollable = 1` would make a single no-op advertise an affordance the pane has never shown — so
    /// the very next describe_scene would invite the round this ticket exists to prevent.
    func testANoOpOnANeverScrolledPaneNeverAdvertisesASidewaysAffordance() {
        let m = freshMemory()
        m.recordPaneNoop(app: "resolve", role: "sidebar", axis: "h", direction: "right")
        XCTAssertNotEqual(m.paneScrollable(app: "resolve", role: "sidebar", axis: "h"), true)
        XCTAssertNil(ScrollAnnotator.annotateSideways(
            learned: m.paneScrollable(app: "resolve", role: "sidebar", axis: "h")),
            "the map must not claim a pane slides sideways because a scroll of it did nothing")
    }

    /// Written under the map's volatile name, read back under either — the same canonical key rule the
    /// rest of this ledger uses.
    func testTheNoOpIsKeyedOnTheCanonicalRole() {
        let m = freshMemory()
        m.recordPaneNoop(app: "resolve", role: "content (Deliver)", axis: "h", direction: "right")
        XCTAssertEqual(m.paneNoopDirections(app: "resolve", role: "content (Render Settings)", axis: "h"), ["right"])
    }

    /// The SAME verb succeeding is what retires the record — the scroll tool clears what the scroll tool
    /// wrote.
    func testTheSameVerbSucceedingClearsTheNoOp() {
        let m = freshMemory()
        m.recordPaneNoop(app: "resolve", role: "content", axis: "h", direction: "right")
        m.clearPaneNoop(app: "resolve", role: "content (Render Settings)", axis: "h")
        XCTAssertEqual(m.paneNoopDirections(app: "resolve", role: "content", axis: "h"), [])
    }

    /// And a DIFFERENT gesture succeeding does NOT. The Deliver carousel is a sub-container: the AX-aimed
    /// wheel slides it (which is what writes `scrollable: true` here) while `scroll(section:)` wheels the
    /// settings form behind it and moves nothing (ticket 14). Clearing on that success would re-enable
    /// exactly the false recommendation ticket 15 measured.
    func testAnotherGestureSucceedingDoesNotRetireTheSectionLevelNoOp() {
        let m = freshMemory()
        m.recordPaneNoop(app: "resolve", role: "content", axis: "h", direction: "right")
        m.recordPane(app: "resolve", role: "content", axis: "h", scrollable: true, pxPerTick: nil)
        XCTAssertEqual(m.paneNoopDirections(app: "resolve", role: "content", axis: "h"), ["right"],
                       "the pane slides for SOME gesture — not for the one the guide would name")
    }

    /// MEASURED LIVE on Resolve's Deliver strip: the section-level wheel no-ops BOTH ways (it never
    /// reaches the carousel sub-container — ticket 14). A single-slot memory answers the right no-op with
    /// "scroll left", the left no-op with "scroll right", and the agent ping-pongs between two dead
    /// calls. Both must be remembered so the guide can say the axis is spent.
    func testBothDirectionsAccumulateSoTheGuideCanCallTheAxisSpent() {
        let m = freshMemory()
        m.recordPaneNoop(app: "resolve", role: "content", axis: "h", direction: "right")
        m.recordPaneNoop(app: "resolve", role: "content", axis: "h", direction: "left")
        XCTAssertEqual(Set(m.paneNoopDirections(app: "resolve", role: "content", axis: "h")), ["right", "left"])
    }

    /// Idempotent: the same gesture failing twice is still one fact.
    func testRepeatingTheSameNoOpDoesNotDuplicateIt() {
        let m = freshMemory()
        for _ in 0..<3 { m.recordPaneNoop(app: "resolve", role: "content", axis: "h", direction: "right") }
        XCTAssertEqual(m.paneNoopDirections(app: "resolve", role: "content", axis: "h"), ["right"])
    }

    /// Per AXIS: a vertical no-op says nothing about the sideways gesture, and vice versa.
    func testNoOpsDoNotLeakAcrossAxes() {
        let m = freshMemory()
        m.recordPaneNoop(app: "resolve", role: "content", axis: "v", direction: "down")
        XCTAssertEqual(m.paneNoopDirections(app: "resolve", role: "content", axis: "h"), [])
        XCTAssertEqual(m.paneNoopDirections(app: "resolve", role: "content", axis: "v"), ["down"])
    }

    func testAnUnknownPaneHasNoNoOpOpinion() {
        XCTAssertEqual(freshMemory().paneNoopDirections(app: "resolve", role: "sidebar", axis: "h"), [])
    }

    func testCheckedTransactionRollsBackOnFailure() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqltx-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = SQLiteStore(path: dir.appendingPathComponent("t.db").path)!
        store.exec("CREATE TABLE t(x INTEGER)")
        // body fails after an insert → the insert must NOT survive
        let failed = store.transactionChecked { run in
            _ = run("INSERT INTO t(x) VALUES(1)", [])
            return false
        }
        XCTAssertFalse(failed)
        XCTAssertEqual(store.query("SELECT COUNT(*) AS n FROM t").first?["n"] as? Int, 0, "rolled back")
        // body succeeds → committed
        XCTAssertTrue(store.transactionChecked { run in run("INSERT INTO t(x) VALUES(2)", []) })
        XCTAssertEqual(store.query("SELECT COUNT(*) AS n FROM t").first?["n"] as? Int, 1)
    }

    func testOneVerbPerPhrasing() {
        let m = freshMemory()
        m.recordExperience(app: nil, phrase: "huddle with simone", tool: "open", argsJSON: #"{"app":"slack"}"#, success: true)
        m.recordExperience(app: nil, phrase: "huddle with simone", tool: "start_call", argsJSON: #"{"person":"simone"}"#, success: true)
        // the phrasing now maps to exactly ONE verb — the most recent (start_call), the stale `open` gone
        let mine = m.recentExperiences().filter { Set($0.tokens) == ["huddle", "simone"] }
        XCTAssertEqual(mine.count, 1)
        XCTAssertEqual(mine.first?.tool, "start_call")
    }

    func testExperienceExactImitation() {
        let m = freshMemory()
        m.recordExperience(app: nil, phrase: "huddle with simone", tool: "start_call",
                           argsJSON: #"{"person":"simone","app":"slack"}"#, success: true)
        let hit = LocatorMemory.imitate(input: "huddle with simone", from: m.recentExperiences())
        XCTAssertEqual(hit?.tool, "start_call")
    }

    func testExperienceOneTokenGeneralization() {
        let m = freshMemory()
        m.recordExperience(app: nil, phrase: "huddle with simone", tool: "start_call",
                           argsJSON: #"{"person":"simone","app":"slack"}"#, success: true)
        // The substituted entity has to be one the engine has SIGHTED in the target app — michele is,
        // in slack's graph. Without that evidence this same swap abstains (see the test below).
        let hit = LocatorMemory.imitate(input: "huddle with michele", from: m.recentExperiences(),
                                        graph: crossGraph)
        XCTAssertEqual(hit?.tool, "start_call")
        XCTAssertTrue(hit?.argsJSON.contains("michele") == true, "the changed entity substitutes into args")
        XCTAssertFalse(hit?.argsJSON.contains("simone") == true)
    }

    /// The entity-evidence gate, from the old entry point: the identical one-token swap with nothing
    /// sighted to back it is a guess, and a guess is an abstention.
    func testGeneralizationWithoutEntityEvidenceAbstains() {
        let m = freshMemory()
        m.recordExperience(app: nil, phrase: "huddle with simone", tool: "start_call",
                           argsJSON: #"{"person":"simone","app":"slack"}"#, success: true)
        XCTAssertNil(LocatorMemory.imitate(input: "huddle with fritz", from: m.recentExperiences(),
                                          graph: crossGraph),
                     "fritz has never been seen in slack — the model can find out, memory cannot invent it")
    }

    func testSendMessageIsNeverImitated() {
        let m = freshMemory()
        m.recordExperience(app: nil, phrase: "ping ron now", tool: "send_message",
                           argsJSON: #"{"to":"ron"}"#, success: true)
        XCTAssertNil(LocatorMemory.imitate(input: "ping ron now", from: m.recentExperiences()),
                     "sends are composed, never replayed from memory")
    }

    func testHintForPartialOverlap() {
        let m = freshMemory()
        m.recordExperience(app: nil, phrase: "huddle with simone", tool: "start_call",
                           argsJSON: #"{"person":"simone"}"#, success: true)
        let h = LocatorMemory.hint(input: "can you make a huddle happen with simone please",
                                   from: m.recentExperiences())
        XCTAssertNotNil(h)
        XCTAssertTrue(h!.contains("start_call"))
    }

    func testStitchOverlappingFramesBuildOneOrder() {
        // frame 1: A B C D — frame 2 (scrolled): C D E F → global order A<B<C<D<E<F
        var ranks = LocatorMemory.stitch(existing: [:], visible: ["a", "b", "c", "d"])
        ranks = LocatorMemory.stitch(existing: ranks, visible: ["c", "d", "e", "f"])
        let ordered = ranks.sorted { $0.value < $1.value }.map(\.key)
        XCTAssertEqual(ordered, ["a", "b", "c", "d", "e", "f"])
    }

    func testStitchInsertsBetweenKnownNeighbors() {
        var ranks = LocatorMemory.stitch(existing: [:], visible: ["a", "c"])
        ranks = LocatorMemory.stitch(existing: ranks, visible: ["a", "b", "c"])
        XCTAssertTrue(ranks["a"]! < ranks["b"]! && ranks["b"]! < ranks["c"]!)
    }

    func testStitchTrustsTheCurrentFrameOnReorder() {
        var ranks = LocatorMemory.stitch(existing: [:], visible: ["a", "b", "c"])
        ranks = LocatorMemory.stitch(existing: ranks, visible: ["b", "a", "c"])   // list reordered live
        XCTAssertTrue(ranks["b"]! < ranks["a"]! && ranks["a"]! < ranks["c"]!)
    }

    func testMemberSeedDirectionAndRows() {
        let m = freshMemory()
        m.recordMembers(app: "slack", family: "sidebar",
                        members: [("andrea", "Andrea"), ("eliomar", "Eliomar"), ("fritz", "Fritz"),
                                  ("loris", "Loris"), ("michele", "Michele"), ("simone", "Simone")],
                        rowPitch: 0.035)
        // visible now: only the top of the list — target fritz should read "below andrea/eliomar"
        let seed = m.memberSeed(app: "slack", target: "z Fritz", visibleCores: ["andrea", "eliomar"])
        XCTAssertEqual(seed?.direction, 1)
        XCTAssertEqual(seed?.rowsAway, 1)          // eliomar → fritz: adjacent
        XCTAssertEqual(seed?.anchorLabel, "Eliomar")
        // and from the bottom: target fritz is ABOVE simone
        let up = m.memberSeed(app: "slack", target: "fritz", visibleCores: ["simone", "michele"])
        XCTAssertEqual(up?.direction, -1)
    }

    func testSightingKeepsDetailAlongsideCanonicalSection() {
        let m = freshMemory()
        m.recordSightings(app: "slack", items: [("Fritz", "sidebar (Connessioni esterne)", 0.15, 0.7)])
        let s = m.sighting(app: "slack", target: "fritz")
        XCTAssertEqual(s?.section, "sidebar", "identity stays canonical")
        XCTAssertEqual(s?.detail, "sidebar (Connessioni esterne)", "the full context survives as detail")
    }

    // MARK: cross-graph imitation — fast-paths hop between app graphs on ENTITY EVIDENCE

    private var crossGraph: LocatorMemory.GraphContext {
        LocatorMemory.GraphContext(sighted: [
            "com.tinyspeck.slackmacgap": ["simone", "michele"],
            "net.whatsapp.whatsapp": ["michele"],       // michele exists in BOTH graphs; simone only in slack
        ])
    }

    func testImitationHopsToAnotherAppWhenEntityIsSightedThere() {
        let m = freshMemory()
        m.recordExperience(app: nil, phrase: "call simone", tool: "start_call",
                           argsJSON: #"{"person":"simone","app":"slack"}"#, success: true)
        // entity swap + graph hop in one phrase — michele IS sighted in whatsapp's graph
        let hit = LocatorMemory.imitate(input: "call michele on whatsapp",
                                        from: m.recentExperiences(), graph: crossGraph)
        XCTAssertEqual(hit?.tool, "start_call")
        XCTAssertTrue(hit?.argsJSON.contains("michele") == true)
        XCTAssertTrue(hit?.argsJSON.contains(#""app":"whatsapp""#) == true, "retargeted to the other graph")
    }

    func testImitationRefusesHopWithoutEntityEvidence() {
        let m = freshMemory()
        m.recordExperience(app: nil, phrase: "call simone", tool: "start_call",
                           argsJSON: #"{"person":"simone","app":"slack"}"#, success: true)
        // simone was NEVER sighted in whatsapp — no evidence, no hop, the model handles it
        XCTAssertNil(LocatorMemory.imitate(input: "call simone on whatsapp",
                                           from: m.recentExperiences(), graph: crossGraph))
    }

    func testImitationHopsSamePhraseWhenEntityKnownInTargetGraph() {
        let m = freshMemory()
        m.recordExperience(app: nil, phrase: "call michele", tool: "start_call",
                           argsJSON: #"{"person":"michele","app":"slack"}"#, success: true)
        let hit = LocatorMemory.imitate(input: "call michele on whatsapp",
                                        from: m.recentExperiences(), graph: crossGraph)
        XCTAssertEqual(hit?.tool, "start_call")
        XCTAssertTrue(hit?.argsJSON.contains(#""app":"whatsapp""#) == true)
    }

    func testFailedExperiencesDontImitate() {
        let m = freshMemory()
        m.recordExperience(app: nil, phrase: "huddle with simone", tool: "start_call",
                           argsJSON: #"{"person":"simone"}"#, success: false)
        XCTAssertNil(LocatorMemory.imitate(input: "huddle with simone", from: m.recentExperiences()))
    }
}
