//
//  ObservedObjectTests.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import Foundation
@testable import Memory
import PerceptionCore
import Testing

@Suite("Observed objects and window inventories")
struct ObservedObjectTests {

    private let t0 = Fixtures.t0, t1 = Fixtures.t1

    @Test("identity keys prefer an identifier, then role and text, then a coarse position bucket")
    func identityKeys() {
        let zero = NormalizedRect.zero
        #expect(ObservedObject.makeIdentityKey(role: "AXButton", identifier: "export-btn", text: "Export", boundsNormalized: zero) == "id:export-btn")
        #expect(ObservedObject.makeIdentityKey(role: "AXButton", identifier: nil, text: "Export", boundsNormalized: zero) == "AXButton|export")
        let a = ObservedObject.makeIdentityKey(role: "AXImage", identifier: nil, text: nil, boundsNormalized: Fixtures.rect(0.123, 0.456, 0.02, 0.02))
        let b = ObservedObject.makeIdentityKey(role: "AXImage", identifier: nil, text: nil, boundsNormalized: Fixtures.rect(0.119, 0.451, 0.02, 0.02))
        #expect(a == b)
        #expect(a == "AXImage|@1,5")
    }

    @Test("an affordance round-trips and a later observation backfills it")
    func affordance() throws {
        var object = Fixtures.observed("AXButton|export", "Export")
        object.affordance = .link
        let data = try KnowledgeCoding.makeEncoder().encode(object)
        #expect(try KnowledgeCoding.makeDecoder().decode(ObservedObject.self, from: data).affordance == .link)

        var inventory = WindowInventory(windowTitlePattern: "Edit", lastObserved: t0)
        inventory.merge([Fixtures.observed("AXButton|export", "Export")], now: t0)
        #expect(inventory.objects.first?.affordance == nil)
        var withAffordance = Fixtures.observed("AXButton|export", "Export")
        withAffordance.affordance = .text
        inventory.merge([withAffordance], now: t1)
        #expect(inventory.objects.first { $0.identityKey == "AXButton|export" }?.affordance == .text)
    }

    @Test("merge updates a known object and appends a new one")
    func merge() throws {
        var inventory = WindowInventory(windowTitlePattern: "Edit", lastObserved: t0)
        inventory.merge([Fixtures.observed("AXButton|export", "Export"), Fixtures.observed("AXButton|cancel", "Cancel")], now: t0)
        #expect(inventory.objects.count == 2)
        inventory.merge([Fixtures.observed("AXButton|export", "Export", bounds: Fixtures.rect(0.5, 0.5, 0.1, 0.05)),
                         Fixtures.observed("AXButton|ok", "OK")], now: t1)
        #expect(inventory.objects.count == 3)
        let export = try #require(inventory.objects.first { $0.identityKey == "AXButton|export" })
        #expect(export.observationCount == 2)
        #expect(export.lastSeen == t1)
        #expect(export.boundsNormalized == Fixtures.rect(0.5, 0.5, 0.1, 0.05))
        #expect(export.firstSeen == t0)
    }

    @Test("merge fills missing text from a later observation")
    func backfillText() {
        var inventory = WindowInventory(windowTitlePattern: "W", lastObserved: t0)
        inventory.merge([Fixtures.observed("AXImage|@1,5", nil, role: "AXImage")], now: t0)
        inventory.merge([Fixtures.observed("AXImage|@1,5", "Save", role: "AXImage")], now: t1)
        #expect(inventory.objects.first?.selfText == "Save")
    }

    @Test("candidates rank exact over subset over token overlap and exclude non-matches")
    func ranking() {
        var inventory = WindowInventory(windowTitlePattern: "W", lastObserved: t0)
        inventory.merge([
            Fixtures.observed("a", "Export Selected"),
            Fixtures.observed("b", "Export"),
            Fixtures.observed("c", "Re-Export As…"),
            Fixtures.observed("d", "Cancel"),
        ], now: t0)
        let ranked = inventory.candidates(for: "Export")
        #expect(ranked.first?.selfText == "Export")
        #expect(ranked.count == 3)
        #expect(Set(ranked.compactMap(\.selfText)) == ["Export", "Export Selected", "Re-Export As…"])
    }

    @Test("match score is token-based, never a raw substring")
    func tokenScore() {
        #expect(Fixtures.observed("x", "5").matchScore(query: "Audio 25") == 0)
        #expect(Fixtures.observed("x", "Audio 25").matchScore(query: "Audio 25") == 3)
        #expect(Fixtures.observed("x", "Audio 2").matchScore(query: "Audio 25") == 0.5)
        #expect(Fixtures.observed("x", "Re-Export As…").matchScore(query: "Export") == 2)
    }

    @Test("a tie goes to the more observed object")
    func tieBreak() {
        var inventory = WindowInventory(windowTitlePattern: "W", lastObserved: t0)
        inventory.merge([Fixtures.observed("x", "Save"), Fixtures.observed("y", "Save")], now: t0)
        inventory.merge([Fixtures.observed("y", "Save")], now: t1)
        #expect(inventory.candidates(for: "Save").first?.identityKey == "y")
    }

    @Test("observe routes objects to their window and counts them")
    func observe() {
        var app = AppKnowledge(bundleID: "com.x")
        app.observe(windowTitlePattern: "Main", objects: [Fixtures.observed("a", "A"), Fixtures.observed("b", "B")], now: t0)
        app.observe(windowTitlePattern: "Prefs", objects: [Fixtures.observed("c", "C")], now: t0)
        app.observe(windowTitlePattern: "Main", objects: [Fixtures.observed("a", "A")], now: t1)
        #expect(app.windows.count == 2)
        #expect(app.objectCount == 3)
    }

    @Test("a state fingerprint is stable across scroll and meters and separates different states")
    func fingerprint() {
        let top = StateFingerprint.make(title: "Edit: GAME • v4", objects: [
            Fixtures.observed("a", "Audio 1", role: nil), Fixtures.observed("b", "Audio 2", role: nil),
            Fixtures.observed("c", "wave", role: nil), Fixtures.observed("d", "00:00:14:11", role: nil),
            Fixtures.observed("e", "Bus 1-2", role: nil)])
        let scrolled = StateFingerprint.make(title: "Edit: GAME • v5", objects: [
            Fixtures.observed("a", "Audio 27", role: nil), Fixtures.observed("b", "Audio 28", role: nil),
            Fixtures.observed("c", "wave", role: nil), Fixtures.observed("d", "00:01:59:02", role: nil),
            Fixtures.observed("e", "Bus 1-2", role: nil)])
        #expect(top.matches(scrolled))

        let edit = StateFingerprint.make(title: "Edit", objects: [
            Fixtures.observed("a", "Audio 1"), Fixtures.observed("b", "wave"), Fixtures.observed("c", "Bus 1-2")])
        let prefs = StateFingerprint.make(title: "Playback Engine", objects: [
            Fixtures.observed("a", "Sample Rate", role: "AXPopUpButton"),
            Fixtures.observed("b", "Buffer Size", role: "AXPopUpButton"), Fixtures.observed("c", "OK")])
        #expect(!edit.matches(prefs))
    }

    @Test("observe merges the same state across a scroll into one node")
    func sameState() {
        var app = AppKnowledge(bundleID: "com.avid.ProTools")
        let a = StateFingerprint.make(title: "Edit", objects: [Fixtures.observed("a", "Audio 1", role: nil), Fixtures.observed("w", "wave", role: nil)])
        let b = StateFingerprint.make(title: "Edit", objects: [Fixtures.observed("a", "Audio 9", role: nil), Fixtures.observed("w", "wave", role: nil)])
        app.observe(windowTitlePattern: "Edit", objects: [Fixtures.observed("a", "Audio 1")], now: t0, fingerprint: a)
        app.observe(windowTitlePattern: "Edit", objects: [Fixtures.observed("z", "Audio 9")], now: t1, fingerprint: b)
        #expect(app.windows.count == 1)
        #expect(app.objectCount == 2)
    }

    @Test("older per-application JSON without newer sections still decodes and round-trips")
    func backCompat() throws {
        let decoder = KnowledgeCoding.makeDecoder(), encoder = KnowledgeCoding.makeEncoder()
        let old = try decoder.decode(AppKnowledge.self, from: Data(#"{"bundleID":"com.x","windows":[]}"#.utf8))
        #expect(old.bundleID == "com.x")
        #expect(old.menuCommands.isEmpty && old.routes.isEmpty && old.brain.objects.isEmpty)
        var app = AppKnowledge(bundleID: "com.avid.ProTools")
        app.observe(windowTitlePattern: "Edit", objects: [Fixtures.observed("a", "Audio 3"), Fixtures.observed("b", "Audio 4")], now: t0)
        #expect(try decoder.decode(AppKnowledge.self, from: try encoder.encode(app)) == app)
    }
}
