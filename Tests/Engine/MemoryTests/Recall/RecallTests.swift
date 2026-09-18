//
//  RecallTests.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import Foundation
@testable import Memory
import Testing

/// Every test constructs the world by hand, remembered experiences plus the entity evidence, so what
/// is asserted is the decision recall reached, never which internal branch ran.
@Suite("Recall: three answers and the entity-evidence gate")
struct RecallTests {

    private func remembered(_ phrase: String, _ tool: String, _ args: [String: String], ok: Int = 1, fail: Int = 0) -> Experience {
        Experience(phrase: phrase, tool: tool, argsJSON: MisfireCorpus.json(args), ok: ok, fail: fail)
    }

    private func graph(_ sighted: [String: [String]]) -> SightingGraph {
        SightingGraph(sighted: sighted.mapValues { Set($0) })
    }

    private func fired(_ answer: Recall.Answer) -> (tool: String, args: [String: String])? {
        guard case .fire(let fire) = answer else { return nil }
        return (fire.tool, MisfireCorpus.args(fire.argsJSON))
    }

    private func abstention(_ answer: Recall.Answer) -> Recall.Abstention? {
        guard case .abstain(let abstention) = answer else { return nil }
        return abstention
    }

    private let premiere = ["com.adobe.premierepro": ["premiere"]]

    // MARK: The three answers

    @Test("an exact replay fires")
    func exactReplay() {
        let world = Recall.World(memories: [remembered("go to finder", "open", ["app": "finder"])],
                                 graph: graph(["com.apple.finder": ["finder"]]))
        let got = fired(Recall.decide(input: "go to finder", in: world))
        #expect(got?.tool == "open")
        #expect(got?.args == ["app": "finder"])
    }

    @Test("nothing remembered abstains silently")
    func silent() {
        let abstention = abstention(Recall.decide(input: "bounce the mix", in: Recall.World(memories: [])))
        #expect(abstention != nil)
        #expect(abstention?.refused == nil)
        #expect(abstention?.narration == nil)
    }

    @Test("empty input abstains")
    func emptyInput() {
        let world = Recall.World(memories: [remembered("go to finder", "open", ["app": "finder"])])
        #expect(abstention(Recall.decide(input: "   ...   ", in: world)) != nil)
    }

    @Test("a covering but chatty phrasing answers with a hint")
    func hint() {
        let world = Recall.World(memories: [remembered("huddle with simone", "start_call", ["app": "slack", "person": "simone"])],
                                 graph: graph(["com.tinyspeck.slackmacgap": ["simone"]]))
        guard case .hint(let hint) = Recall.decide(input: "can you make a huddle happen with simone please", in: world) else {
            Issue.record("expected a hint")
            return
        }
        #expect(hint.contains("start_call"))
        #expect(hint.contains("huddle with simone"))
    }

    // MARK: App-shaped slots

    @Test("a pronoun never fills an app slot, and the refusal is narrated")
    func pronoun() {
        let world = Recall.World(memories: [remembered("caN you open premiere", "launch_app", ["app": "premiere"], ok: 3)],
                                 graph: graph(premiere))
        let answer = Recall.decide(input: "can you open it", in: world)
        #expect(fired(answer) == nil)
        let abstention = abstention(answer)
        #expect(abstention?.refused == "caN you open premiere")
        #expect(abstention?.reason.contains("names no app I know") == true)
        #expect(abstention?.narration != nil)
    }

    @Test("a legitimate app substitution still fires")
    func appSwap() {
        let world = Recall.World(memories: [remembered("open premiere", "launch_app", ["app": "premiere"])],
                                 graph: graph(["com.adobe.premierepro": ["premiere"], "com.blackmagic-design.davinciresolve": ["master"]]))
        #expect(fired(Recall.decide(input: "open resolve", in: world))?.args == ["app": "resolve"])
    }

    @Test("a substring of a bundle id is not evidence")
    func substring() {
        let world = Recall.World(memories: [remembered("caN you open premiere", "launch_app", ["app": "premiere"], ok: 3)],
                                 graph: graph(["com.adobe.premierepro": ["premiere"], "com.forte-ai.aafchecker": [], "hylo.aaf-checker": []]))
        #expect(fired(Recall.decide(input: "can you check premiere", in: world)) == nil)
    }

    @Test("an ambiguous app name is not evidence")
    func ambiguousApp() {
        let evidence = RecallEvidence(graph: graph(["com.apple.finder": ["finder"], "com.forte-ai.aafchecker": [], "hylo.aaf-checker": []]))
        guard case .several(let bundles) = evidence.app(named: "aaf") else {
            Issue.record("\"aaf\" prefixes both checker bundles")
            return
        }
        #expect(bundles.count == 2)
        let world = Recall.World(memories: [remembered("go to finder", "open", ["app": "finder"])], evidence: evidence)
        let answer = Recall.decide(input: "go to aaf", in: world)
        #expect(fired(answer) == nil)
        #expect(abstention(answer)?.reason.contains("could be any of 2 apps") == true)
    }

    @Test("what counts as naming an app")
    func naming() {
        let evidence = RecallEvidence(graph: graph(["com.adobe.premierepro": ["premiere"],
                                                   "com.blackmagic-design.davinciresolve": ["master"],
                                                   "com.apple.finder": ["finder"], "hylo.aaf-checker": []]))
        #expect(evidence.app(named: "premiere") == .one("com.adobe.premierepro"))
        #expect(evidence.app(named: "resolve") == .one("com.blackmagic-design.davinciresolve"))
        #expect(evidence.app(named: "finder") == .one("com.apple.finder"))
        #expect(evidence.app(named: "davinci") == .one("com.blackmagic-design.davinciresolve"))
        #expect(evidence.app(named: "com.apple.finder") == .one("com.apple.finder"))
        #expect(evidence.app(named: "check") == .unknown)
        #expect(evidence.app(named: "it") == .unknown)
        #expect(evidence.app(named: "that") == .unknown)
        #expect(evidence.app(named: "aprilo") == .unknown)
    }

    // MARK: Entities inside an app

    @Test("a discourse token never becomes a click target")
    func discourse() {
        let world = Recall.World(memories: [remembered("in master", "act", ["app": "com.blackmagic-design.DaVinciResolve",
                                                                            "section": "sidebar (Master)", "target": "Master", "verb": "click"])],
                                 graph: graph(["com.blackmagic-design.davinciresolve": ["master"]]))
        let answer = Recall.decide(input: "continue", in: world)
        #expect(fired(answer) == nil)
        #expect(abstention(answer)?.reason.contains("never seen \"continue\"") == true)
    }

    @Test("a sighted entity substitution fires, an unsighted one abstains")
    func entitySwap() {
        let memory = remembered("huddle with michele", "start_call", ["app": "slack", "person": "michele"])
        let sighted = Recall.World(memories: [memory], graph: graph(["com.tinyspeck.slackmacgap": ["simone", "michele"]]))
        #expect(fired(Recall.decide(input: "huddle with simone", in: sighted))?.args == ["app": "slack", "person": "simone"])
        let unsighted = Recall.World(memories: [memory], graph: graph(["com.tinyspeck.slackmacgap": ["michele"]]))
        #expect(fired(Recall.decide(input: "huddle with simone", in: unsighted)) == nil)
    }

    @Test("an entity slot with no app to check abstains")
    func noApp() {
        let world = Recall.World(memories: [remembered("huddle with michele", "start_call", ["person": "michele"])],
                                 graph: graph(["com.tinyspeck.slackmacgap": ["simone", "michele"]]))
        #expect(fired(Recall.decide(input: "huddle with simone", in: world)) == nil)
    }

    @Test("a hop without entity evidence abstains and says why; with evidence it fires")
    func hop() {
        let world = Recall.World(memories: [remembered("call simone", "start_call", ["app": "slack", "person": "simone"])],
                                 graph: graph(["com.tinyspeck.slackmacgap": ["simone", "michele"], "net.whatsapp.whatsapp": ["michele"]]))
        let refused = Recall.decide(input: "call simone on whatsapp", in: world)
        #expect(fired(refused) == nil)
        #expect(abstention(refused)?.narration != nil)
        #expect(fired(Recall.decide(input: "call michele on whatsapp", in: world))?.args == ["app": "whatsapp", "person": "michele"])
    }

    @Test("a substitution the hop would overwrite abstains")
    func dropped() {
        let world = Recall.World(memories: [remembered("open foo", "open", ["app": "foo"])],
                                 graph: graph(["com.apple.finder": ["finder"]]))
        let answer = Recall.decide(input: "open bar in finder", in: world)
        #expect(fired(answer) == nil)
        #expect(abstention(answer)?.reason.contains("would be dropped, not used") == true)
    }

    @Test("a refused candidate does not block another memory from firing")
    func notShadowed() {
        let refusable = remembered("huddle with michele", "start_call", ["app": "whatsapp", "person": "michele"], ok: 2)
        let good = remembered("huddle with simone", "start_call", ["app": "slack", "person": "simone"])
        let world = Recall.World(memories: [refusable, good],
                                 graph: graph(["net.whatsapp.whatsapp": ["michele"], "com.tinyspeck.slackmacgap": ["simone", "michele"]]))
        let got = fired(Recall.decide(input: "huddle with simone", in: world))
        #expect(got?.tool == "start_call")
        #expect(got?.args == ["app": "slack", "person": "simone"])
    }
}
