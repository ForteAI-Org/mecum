import XCTest
@testable import LocatorCore

/// THE RECALL SEAM's own suite. Every test here constructs the world by hand — remembered Experiences
/// plus the entity evidence — so what is asserted is the DECISION recall reached, never which internal
/// branch ran, and none of it needs a store, a session, or a driven app.
///
/// The real failure history is asserted separately, against the fixture, in `MisfireCorpusTests`. This
/// file covers the seam's contract: three answers, and the gate that produces the middle one.
final class RecallTests: XCTestCase {

    // MARK: helpers

    private func remembered(_ phrase: String, _ tool: String, _ args: [String: String],
                           ok: Int = 1, fail: Int = 0) -> LocatorMemory.Experience {
        let json = String(data: try! JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
        return LocatorMemory.Experience(phrase: phrase, tokens: LocatorMemory.tokens(phrase),
                                        tool: tool, argsJSON: json, ok: ok, fail: fail)
    }

    private func graph(_ sighted: [String: [String]]) -> LocatorMemory.GraphContext {
        LocatorMemory.GraphContext(sighted: sighted.mapValues { Set($0) })
    }

    private func fired(_ answer: Recall.Answer) -> (tool: String, args: [String: String])? {
        guard case .fire(let f) = answer, let d = f.argsJSON.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: String] else { return nil }
        return (f.tool, obj)
    }

    private func abstention(_ answer: Recall.Answer) -> Recall.Abstention? {
        guard case .abstain(let a) = answer else { return nil }
        return a
    }

    private let premiereGraph = ["com.adobe.premierepro": ["premiere"]]

    // MARK: the three answers

    func testExactReplayFires() {
        let w = Recall.World(memories: [remembered("go to finder", "open", ["app": "finder"])],
                            graph: graph(["com.apple.finder": ["finder"]]))
        let got = fired(Recall.decide(input: "go to finder", in: w))
        XCTAssertEqual(got?.tool, "open")
        XCTAssertEqual(got?.args, ["app": "finder"])
    }

    /// "Never seen it" is an abstention with nothing to narrate — the engine must not announce its own
    /// silence on every turn it has no memory of.
    func testNothingRememberedAbstainsSilently() {
        let a = abstention(Recall.decide(input: "bounce the mix", in: Recall.World(memories: [])))
        XCTAssertNotNil(a)
        XCTAssertNil(a?.refused, "nothing was refused — there was nothing there")
        XCTAssertNil(a?.narration, "silence is the right narration for a phrase never heard")
    }

    func testEmptyInputAbstains() {
        let w = Recall.World(memories: [remembered("go to finder", "open", ["app": "finder"])])
        XCTAssertNotNil(abstention(Recall.decide(input: "   ...   ", in: w)))
    }

    /// A phrase that covers a memory but leaves too much residue to substitute safely is the `hint`
    /// answer: worth whispering into the model round, never worth acting on.
    func testPartialOverlapAnswersWithAHint() {
        let w = Recall.World(memories: [remembered("huddle with simone", "start_call",
                                                   ["app": "slack", "person": "simone"])],
                            graph: graph(["com.tinyspeck.slackmacgap": ["simone"]]))
        guard case .hint(let h) = Recall.decide(input: "can you make a huddle happen with simone please",
                                               in: w) else {
            return XCTFail("expected a hint for a covering-but-chatty phrasing")
        }
        XCTAssertTrue(h.contains("start_call"), "a hint has to carry the verb to be worth anything")
        XCTAssertTrue(h.contains("huddle with simone"))
    }

    // MARK: the entity-evidence gate — app-shaped slots

    /// The case that started the effort. "it" names no app, so the slot cannot be filled with it.
    func testPronounNeverFillsAnAppSlot() {
        let w = Recall.World(memories: [remembered("caN you open premiere", "launch_app",
                                                   ["app": "premiere"], ok: 3)],
                            graph: graph(premiereGraph))
        let answer = Recall.decide(input: "can you open it", in: w)
        XCTAssertNil(fired(answer), "launch_app(app: \"it\") is the misfire this seam exists to stop")
        let a = abstention(answer)
        XCTAssertEqual(a?.refused, "caN you open premiere", "the refusal names what it refused")
        XCTAssertTrue(a?.reason.contains("names no app I know") == true, "got: \(a?.reason ?? "nil")")
        XCTAssertNotNil(a?.narration, "seen-but-not-trusted is owed a sentence")
    }

    /// The other half of the bar: the identical code path must keep firing when the token names a real
    /// app. A gate that abstained here would just be "refuse everything".
    func testLegitimateAppSubstitutionStillFires() {
        let w = Recall.World(memories: [remembered("open premiere", "launch_app", ["app": "premiere"])],
                            graph: graph(["com.adobe.premierepro": ["premiere"],
                                          "com.blackmagic-design.davinciresolve": ["master"]]))
        XCTAssertEqual(fired(Recall.decide(input: "open resolve", in: w))?.args, ["app": "resolve"],
                       "\"resolve\" names DaVinci Resolve — a concrete known entity")
    }

    /// Ticket 03's second defect: two installed bundle ids CONTAIN "check", so an English verb resolved
    /// to an app. Containment is not naming.
    func testSubstringOfABundleIdIsNotEvidence() {
        let w = Recall.World(memories: [remembered("caN you open premiere", "launch_app",
                                                   ["app": "premiere"], ok: 3)],
                            graph: graph(["com.adobe.premierepro": ["premiere"],
                                          "com.forte-ai.aafchecker": [],
                                          "hylo.aaf-checker": []]))
        XCTAssertNil(fired(Recall.decide(input: "can you check premiere", in: w)),
                     "\"check\" sits in the MIDDLE of \"aafchecker\" — it names nothing")
    }

    /// A word that names several known apps is not evidence either — the same answer the launch tools
    /// already give ("pass the exact bundle id"), reached before anything is done rather than after.
    func testAmbiguousAppNameIsNotEvidence() {
        let ev = Recall.Evidence(graph: graph(["com.apple.finder": ["finder"],
                                              "com.forte-ai.aafchecker": [],
                                              "hylo.aaf-checker": []]))
        guard case .several(let bundles) = ev.app(named: "aaf") else {
            return XCTFail("\"aaf\" prefixes both checker bundles")
        }
        XCTAssertEqual(bundles.count, 2)
        let w = Recall.World(memories: [remembered("go to finder", "open", ["app": "finder"])],
                            evidence: ev)
        let answer = Recall.decide(input: "go to aaf", in: w)
        XCTAssertNil(fired(answer), "two apps could be meant, so neither is evidence")
        XCTAssertTrue(abstention(answer)?.reason.contains("could be any of 2 apps") == true,
                      "got: \(abstention(answer)?.reason ?? "nil")")
    }

    /// The naming rule itself, as a unit — this is the line between the pronoun bug and the feature.
    func testWhatCountsAsNamingAnApp() {
        let ev = Recall.Evidence(graph: graph(["com.adobe.premierepro": ["premiere"],
                                              "com.blackmagic-design.davinciresolve": ["master"],
                                              "com.apple.finder": ["finder"],
                                              "hylo.aaf-checker": []]))
        XCTAssertEqual(ev.app(named: "premiere"), .one("com.adobe.premierepro"), "prefix of a component")
        XCTAssertEqual(ev.app(named: "resolve"), .one("com.blackmagic-design.davinciresolve"), "suffix")
        XCTAssertEqual(ev.app(named: "finder"), .one("com.apple.finder"), "the whole component")
        XCTAssertEqual(ev.app(named: "davinci"), .one("com.blackmagic-design.davinciresolve"))
        XCTAssertEqual(ev.app(named: "com.apple.finder"), .one("com.apple.finder"),
                       "args routinely carry the exact bundle id")
        XCTAssertEqual(ev.app(named: "check"), Recall.Evidence.App.unknown, "an infix names nothing")
        XCTAssertEqual(ev.app(named: "it"), Recall.Evidence.App.unknown, "too short to name anything")
        XCTAssertEqual(ev.app(named: "that"), Recall.Evidence.App.unknown)
        XCTAssertEqual(ev.app(named: "aprilo"), Recall.Evidence.App.unknown, "Italian \"open it\"")
    }

    // MARK: the entity-evidence gate — everything inside an app

    /// The junk case: a discourse word answering the engine's own prompt became a click target.
    func testDiscourseTokenNeverBecomesAClickTarget() {
        let w = Recall.World(memories: [remembered("in master", "act",
                                                   ["app": "com.blackmagic-design.DaVinciResolve",
                                                    "section": "sidebar (Master)", "target": "Master",
                                                    "verb": "click"])],
                            graph: graph(["com.blackmagic-design.davinciresolve": ["master"]]))
        let answer = Recall.decide(input: "continue", in: w)
        XCTAssertNil(fired(answer))
        XCTAssertTrue(abstention(answer)?.reason.contains("never seen \"continue\"") == true,
                      "got: \(abstention(answer)?.reason ?? "nil")")
    }

    /// And the substitution the feature exists for: a person the engine has actually sighted in Slack.
    func testSightedEntitySubstitutionStillFires() {
        let w = Recall.World(memories: [remembered("huddle with michele", "start_call",
                                                   ["app": "slack", "person": "michele"])],
                            graph: graph(["com.tinyspeck.slackmacgap": ["simone", "michele"]]))
        XCTAssertEqual(fired(Recall.decide(input: "huddle with simone", in: w))?.args,
                       ["app": "slack", "person": "simone"])
    }

    /// Same phrase, same branch, no evidence: the sighting is what separates them.
    func testUnsightedEntitySubstitutionAbstains() {
        let w = Recall.World(memories: [remembered("huddle with michele", "start_call",
                                                   ["app": "slack", "person": "michele"])],
                            graph: graph(["com.tinyspeck.slackmacgap": ["michele"]]))
        XCTAssertNil(fired(Recall.decide(input: "huddle with simone", in: w)),
                     "\"simone\" has never been seen in Slack — the swap is a guess")
    }

    /// A substituted entity slot in a call that names no app cannot be checked, and unverifiable is not
    /// the same as verified.
    func testEntitySlotWithNoAppToCheckAbstains() {
        let w = Recall.World(memories: [remembered("huddle with michele", "start_call",
                                                   ["person": "michele"])],
                            graph: graph(["com.tinyspeck.slackmacgap": ["simone", "michele"]]))
        XCTAssertNil(fired(Recall.decide(input: "huddle with simone", in: w)))
    }

    /// The hop's own gate (which the code already stated in its comment) keeps working, and now says so.
    func testHopWithoutEntityEvidenceAbstainsAndSaysWhy() {
        let w = Recall.World(memories: [remembered("call simone", "start_call",
                                                   ["app": "slack", "person": "simone"])],
                            graph: graph(["com.tinyspeck.slackmacgap": ["simone", "michele"],
                                          "net.whatsapp.whatsapp": ["michele"]]))
        let answer = Recall.decide(input: "call simone on whatsapp", in: w)
        XCTAssertNil(fired(answer), "simone was never sighted in whatsapp")
        XCTAssertNotNil(abstention(answer)?.narration)
    }

    func testHopWithEntityEvidenceFires() {
        let w = Recall.World(memories: [remembered("call simone", "start_call",
                                                   ["app": "slack", "person": "simone"])],
                            graph: graph(["com.tinyspeck.slackmacgap": ["simone", "michele"],
                                          "net.whatsapp.whatsapp": ["michele"]]))
        let got = fired(Recall.decide(input: "call michele on whatsapp", in: w))
        XCTAssertEqual(got?.args, ["app": "whatsapp", "person": "michele"])
    }

    /// A one-token swap and an app hop can land on the SAME slot, and then the hop wins — which would
    /// leave the word that earned the match out of the call entirely. Silently dropping what the user
    /// said is the same class of mistake as filling a slot with a pronoun.
    func testASubstitutionTheHopWouldOverwriteAbstains() {
        // "foo" names no app the engine knows, so it stays in the token diff and gets swapped for "bar"
        // — then the hop to finder overwrites the very slot that swap just wrote.
        let w = Recall.World(memories: [remembered("open foo", "open", ["app": "foo"])],
                            graph: graph(["com.apple.finder": ["finder"]]))
        let answer = Recall.decide(input: "open bar in finder", in: w)
        XCTAssertNil(fired(answer), "open(app: finder) would answer a request that also said \"bar\"")
        XCTAssertTrue(abstention(answer)?.reason.contains("would be dropped, not used") == true,
                      "got: \(abstention(answer)?.reason ?? "nil")")
    }

    // MARK: refusing one candidate is not refusing the turn

    /// The property that keeps the gate from becoming an over-abstention machine: a memory that fails
    /// the gate must not shadow a later memory that passes it.
    func testARefusedCandidateDoesNotBlockAnotherMemoryFromFiring() {
        // Ranked first: a huddle remembered in an app where "simone" was never sighted — the gate
        // refuses its substitution. Ranked second: the same phrase, exactly, in Slack.
        let refusable = remembered("huddle with michele", "start_call",
                                   ["app": "whatsapp", "person": "michele"], ok: 2)
        let good = remembered("huddle with simone", "start_call", ["app": "slack", "person": "simone"])
        let w = Recall.World(memories: [refusable, good],
                            graph: graph(["net.whatsapp.whatsapp": ["michele"],
                                          "com.tinyspeck.slackmacgap": ["simone", "michele"]]))
        let got = fired(Recall.decide(input: "huddle with simone", in: w))
        XCTAssertEqual(got?.tool, "start_call")
        XCTAssertEqual(got?.args, ["app": "slack", "person": "simone"],
                       "a refused candidate must not shadow one that earns its replay")
    }

    // MARK: the old entry point keeps its contract

    /// `LocatorMemory.imitate` is the seam's `fire` case and nothing else — the chat frontend and the
    /// existing tests still speak through it.
    func testImitateIsTheFireCaseOfTheSeam() {
        let w = Recall.World(memories: [remembered("open premiere", "launch_app", ["app": "premiere"])],
                            graph: graph(["com.adobe.premierepro": ["premiere"],
                                          "com.blackmagic-design.davinciresolve": ["master"]]))
        let hit = LocatorMemory.imitate(input: "open resolve", from: w.memories, graph: w.evidence.graph)
        XCTAssertEqual(hit?.tool, "launch_app")
        XCTAssertTrue(hit?.argsJSON.contains("resolve") == true)
        XCTAssertNil(LocatorMemory.imitate(input: "open it", from: w.memories, graph: w.evidence.graph),
                     "and an abstention reaches the old entry point as nil")
    }
}
