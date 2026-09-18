//
//  RoutesTests.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import Foundation
@testable import Memory
import Testing

@Suite("Routes: procedural memory")
struct RoutesTests {

    private let t0 = Fixtures.t0
    private let proof = Fixtures.proof
    private func step(_ target: String) -> RouteStep { Fixtures.step(target) }

    @Test("learn and find the best route")
    func learnAndBest() {
        var app = AppKnowledge(bundleID: "com.x")
        app.learnRoute(name: "simone chat", steps: [step("¿ Simone")], proof: proof, now: t0)
        app.learnRoute(name: "export tab", steps: [step("Export")], proof: proof, now: t0)
        #expect(app.bestRoute(for: "simone chat")?.steps.first?.target == "¿ Simone")
        #expect(app.bestRoute(for: "simone")?.name == "simone chat")
        #expect(app.bestRoute(for: "totally unknown thing") == nil)
    }

    @Test("the best route is unique-accept")
    func uniqueAccept() {
        var app = AppKnowledge(bundleID: "com.x")
        app.learnRoute(name: "export tab", steps: [step("Export")], proof: proof, now: t0)
        app.learnRoute(name: "export settings", steps: [step("Export"), step("Settings")], proof: proof, now: t0)
        #expect(app.bestRoute(for: "export") == nil)
        #expect(app.bestRoute(for: "export settings")?.steps.count == 2)
    }

    @Test("relearning the same way adds evidence, a different way resets it")
    func relearn() {
        var app = AppKnowledge(bundleID: "com.x")
        app.learnRoute(name: "simone chat", steps: [step("¿ Simone")], proof: proof, now: t0)
        app.learnRoute(name: "simone chat", steps: [step("¿ Simone")], proof: proof, now: t0)
        #expect(app.routes[0].evidence == 2)
        app.learnRoute(name: "Simone Chat", steps: [step("Home"), step("Simone")], proof: proof, now: t0)
        #expect(app.routes.count == 1)
        #expect(app.routes[0].evidence == 1)
        #expect(app.routes[0].steps.count == 2)
    }

    @Test("a success strengthens and clears the fail streak")
    func success() {
        var app = AppKnowledge(bundleID: "com.x")
        app.learnRoute(name: "export tab", steps: [step("Export")], proof: proof, now: t0)
        app.recordRouteUse(name: "export tab", success: true, now: t0)
        #expect(app.routes[0].evidence == 2)
        app.recordRouteUse(name: "export tab", success: false, now: t0)
        app.recordRouteUse(name: "export tab", success: true, now: t0)
        #expect(app.routes[0].failStreak == 0)
        #expect(app.routes[0].evidence == 3)
    }

    @Test("one failure still matches, two demote without erasing")
    func failures() {
        var app = AppKnowledge(bundleID: "com.x")
        app.learnRoute(name: "export tab", steps: [step("Export")], proof: proof, now: t0)
        app.recordRouteUse(name: "export tab", success: false, now: t0)
        #expect(app.bestRoute(for: "export tab") != nil)
        app.recordRouteUse(name: "export tab", success: false, now: t0)
        #expect(app.bestRoute(for: "export tab") == nil)
        #expect(app.routes.count == 1)
        #expect(app.routes[0].demotedAt == t0)
        #expect(app.routes[0].demotionCause?.contains("replay failed") == true)
    }

    @Test("an unproven route is stored but never actionable")
    func unproven() {
        var app = AppKnowledge(bundleID: "com.x")
        app.learnRoute(name: "export tab", steps: [step("Export")], now: t0)
        #expect(app.routes.count == 1)
        #expect(!app.routes[0].isActionable)
        #expect(app.bestRoute(for: "export tab") == nil)
    }

    @Test("an independently confirmed pre-proof route stays actionable")
    func grandfather() {
        var app = AppKnowledge(bundleID: "com.x")
        app.learnRoute(name: "export tab", steps: [step("Export")], now: t0)
        app.recordRouteUse(name: "export tab", success: true, now: t0)
        #expect(app.routes[0].evidence == 2)
        #expect(app.bestRoute(for: "export tab") != nil)
    }

    @Test("a correction demotes and keeps the first cause")
    func correction() {
        var app = AppKnowledge(bundleID: "com.x")
        app.learnRoute(name: "unsolo all tracks", steps: [step("Solo")], proof: proof, now: t0)
        let demoted = app.demoteRoute(named: "Unsolo All Tracks", cause: "you corrected me: \u{201C}no no, use api\u{201D}", now: t0)
        #expect(demoted?.name == "unsolo all tracks")
        #expect(app.bestRoute(for: "unsolo all tracks") == nil)
        #expect(app.routes[0].steps.count == 1)
        #expect(app.routes[0].demotionCause?.contains("no no, use api") == true)
        #expect(app.demoteRoute(named: "unsolo all tracks", cause: "something else", now: t0) == nil)
        #expect(app.routes[0].demotionCause?.contains("no no, use api") == true)
    }

    @Test("a fresh proof lifts a demotion and keeps the record")
    func reEarned() {
        var app = AppKnowledge(bundleID: "com.x")
        app.learnRoute(name: "export tab", steps: [step("Export")], proof: proof, now: t0)
        app.demoteRoute(named: "export tab", cause: "you corrected me", now: t0)
        app.learnRoute(name: "export tab", steps: [step("Export")], proof: "3 verified steps, none missed", now: t0)
        #expect(app.bestRoute(for: "export tab") != nil)
        #expect(app.routes[0].demotionCause != nil)
    }

    @Test("the retrofit demotes every unearned row and says why")
    func retrofit() {
        var app = AppKnowledge(bundleID: "com.x")
        app.learnRoute(name: "you went to next, not previous", steps: [step("Next")], now: t0)
        app.learnRoute(name: "creative cloud", steps: [step("Home")], now: t0)
        app.recordRouteUse(name: "creative cloud", success: true, now: t0)
        app.learnRoute(name: "go to simone", steps: [step("Simone")], proof: proof, now: t0)
        let demoted = app.demoteUnearnedRoutes(now: t0)
        #expect(demoted.map(\.name) == ["you went to next, not previous"])
        #expect(demoted[0].demotionCause?.contains("before a Route had to be earned") == true)
        #expect(app.actionableRoutes.map(\.name).sorted() == ["creative cloud", "go to simone"])
        #expect(app.routes.count == 3)
        #expect(app.demoteUnearnedRoutes(now: t0).isEmpty)
    }

    @Test("learning prunes stale routes")
    func prune() {
        var app = AppKnowledge(bundleID: "com.x")
        app.learnRoute(name: "old", steps: [step("A")], proof: proof, now: t0)
        app.learnRoute(name: "fresh", steps: [step("B")], proof: proof, now: t0.addingTimeInterval(31 * 86_400))
        #expect(app.routes.map(\.name) == ["fresh"])
    }

    @Test("routes round-trip, including a Return-only type step, and old JSON still loads")
    func coding() throws {
        let encoder = KnowledgeCoding.makeEncoder(), decoder = KnowledgeCoding.makeDecoder()
        let old = try decoder.decode(AppKnowledge.self, from: Data(#"{"bundleID":"com.x","windows":[]}"#.utf8))
        #expect(old.routes.isEmpty)
        var app = AppKnowledge(bundleID: "com.x")
        app.learnRoute(name: "delete confirm", steps: [
            RouteStep(tool: "act", target: "Elimina messaggio...", verb: "click", expect: "elementsAppeared"),
            RouteStep(tool: "type", submit: true),
        ], proof: proof, now: t0)
        #expect(try decoder.decode(AppKnowledge.self, from: try encoder.encode(app)) == app)
    }

    @Test("matching ignores filler in both languages")
    func stopwords() {
        var app = AppKnowledge(bundleID: "com.x")
        app.learnRoute(name: "go to simone", steps: [step("Simone")], proof: proof, now: t0)
        #expect(app.bestRoute(for: "Simone chat")?.name == "go to simone")
        #expect(app.bestRoute(for: "simone")?.name == "go to simone")
        #expect(app.bestRoute(for: "vai da simone")?.name == "go to simone")
        #expect(app.bestRoute(for: "michele") == nil)
    }

    @Test("the end title family is recorded and the action key ignores observations")
    func endTitle() {
        var app = AppKnowledge(bundleID: "com.x")
        let first = [RouteStep(tool: "act", target: "Home", verb: "click", afterTitle: "homeforteai"),
                     RouteStep(tool: "act", target: "Simone", verb: "click", afterTitle: "simonemdforteaislack")]
        app.learnRoute(name: "go to simone", steps: first, proof: proof, now: t0)
        #expect(app.routes[0].endTitleFamily == "simonemdforteaislack")
        let second = [RouteStep(tool: "act", target: "Home", verb: "click", afterTitle: "different"),
                      RouteStep(tool: "act", target: "Simone", verb: "click", afterTitle: "simonemdforteaislack2")]
        app.learnRoute(name: "go to simone", steps: second, proof: proof, now: t0)
        #expect(app.routes[0].evidence == 2)
    }

    @Test("a navigation goal is satisfied by the window title")
    func goalByTitle() {
        #expect(GoalPhrase.goalSatisfied(byTitle: "Simone (MD) - Forte AI - Slack", goal: "go to simone"))
        #expect(GoalPhrase.goalSatisfied(byTitle: "Simone (MD) - Forte AI - Slack", goal: "Simone chat"))
        #expect(!GoalPhrase.goalSatisfied(byTitle: "Andrea (MD) - Forte AI - Slack", goal: "go to simone"))
        #expect(!GoalPhrase.goalSatisfied(byTitle: "Untitled - Premiere Pro", goal: "export tab"))
        #expect(!GoalPhrase.goalSatisfied(byTitle: "", goal: "simone"))
    }

    @Test("step summaries read as one line")
    func summaries() {
        #expect(step("Export").summary == "act click 'Export'")
        #expect(RouteStep(tool: "run_menu", path: "File > Export").summary == "run_menu 'File > Export'")
        #expect(RouteStep(tool: "type", submit: true).summary == "press Return")
    }
}
