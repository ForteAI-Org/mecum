import XCTest
@testable import LocatorCore

final class TurnLedgerTests: XCTestCase {
    private func memory() -> LocatorMemory {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("turns-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return LocatorMemory(directory: dir, countReads: false)
    }

    func testTurnsRoundTripNewestFirstAndFilterByApp() {
        let m = memory()
        m.recordTurn(session: "s1", app: "com.adobe.PremierePro.26", phrase: "open the export aaf menu",
                     tools: [.init(tool: "run_menu", args: ["app": "premiere", "path": "File > Export > AAF"], outcome: "found_acted: opened File > Export > AAF\nmap: …")],
                     answer: "Opened the AAF export dialog.", ok: true)
        m.recordTurn(session: "s1", app: "com.avid.ProTools", phrase: "unsolo all tracks",
                     tools: [.init(tool: "act", args: ["target": "Solo"], outcome: "honest_miss: no Solo visible")], answer: nil, ok: false)
        let all = m.recentTurns()
        XCTAssertEqual(all.map(\.phrase), ["unsolo all tracks", "open the export aaf menu"])
        XCTAssertEqual(all[1].tools[0].outcome, "found_acted: opened File > Export > AAF", "first line only")
        XCTAssertEqual(m.recentTurns(app: "premiere").map(\.phrase), ["open the export aaf menu"])
        XCTAssertEqual(m.recentTurns(okOnly: true).count, 1)
    }

    /// The harness headline (ticket 01): a turn carries its MODEL ROUND COUNT, and `unknown` is not `0`.
    /// A caller with no loop of its own (MCP-driven: no user phrase, no rounds of ours) books `nil`,
    /// because `0` is reserved for "the model was never asked" — the no-model share's numerator.
    func testTurnCarriesRoundCountAndUnknownIsNotZero() {
        let m = memory()
        m.recordTurn(session: "s1", app: "com.apple.finder", phrase: "go to documents",
                     tools: [.init(tool: "go_to_folder", args: ["path": "~/Documents"], outcome: "found_acted")],
                     answer: "Opened Documents.", ok: true, rounds: 3)
        m.recordTurn(session: "s1", app: "com.apple.finder", phrase: "go to documents",
                     tools: [.init(tool: "go_to_folder", args: ["path": "~/Documents"], outcome: "found_acted")],
                     answer: "[replayed from memory] found_acted", ok: true, rounds: 0, imitated: true)
        m.recordTurn(session: "mcp", app: "com.apple.finder", phrase: "go to documents",
                     tools: [], answer: nil, ok: true)   // no loop counted it → unknown
        let all = m.recentTurns()
        XCTAssertEqual(all.map(\.rounds), [nil, 0, 3], "newest first: unknown, imitated, three model rounds")
        XCTAssertEqual(all.map(\.imitated), [false, true, false])
    }

    func testTypedTextAndMessagesAreRedacted() {
        let t = LocatorMemory.TurnTool(tool: "type", args: ["text": "my secret note", "target": "Search", "submit": true], outcome: "found_acted")
        XCTAssertEqual(t.args["text"], "«redacted»")
        XCTAssertEqual(t.args["target"], "Search")
        XCTAssertEqual(t.args["submit"], "true")
        XCTAssertEqual(LocatorMemory.TurnTool(tool: "send_message", args: ["message": "hi"], outcome: "sent").args["message"], "«redacted»")
    }

    func testAgentOutcomesLandInTheLedgerWithTheOutcomeWord() {
        let m = memory()
        m.recordAgentOutcome(app: "com.avid.ProTools", tool: "act", kind: "honest_miss", target: "Solo Safe")
        m.recordAgentOutcome(app: "com.avid.ProTools", tool: "reach", kind: "found_acted", target: "Bounce")
        let rows = m.activityEvents(sinceHours: 1).filter { $0.kind == "outcome" }
        XCTAssertEqual(rows.map(\.section), ["honest_miss", "found_acted"], "oldest first, section = the outcome word")
        XCTAssertTrue(rows.allSatisfy { $0.actor == "agent" })
    }

    /// The hygiene gate: one-word phrases and planning verbs never become experiences.
    func testJunkPhrasesAndPlanningVerbsAreNotExperiences() {
        let m = memory()
        m.recordExperience(app: nil, phrase: "export", tool: "act", argsJSON: "{}", success: true)
        m.recordExperience(app: nil, phrase: "apply a filter then export", tool: "plan_task", argsJSON: "{}", success: true)
        m.recordExperience(app: nil, phrase: "open the export aaf menu", tool: "run_menu", argsJSON: "{}", success: true)
        XCTAssertEqual(m.recentExperiences().map(\.phrase), ["open the export aaf menu"])
    }
}
