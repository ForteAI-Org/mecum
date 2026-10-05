//
//  BrainGraphTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import EngineCore
import Foundation
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// The brain's general graph beside its compatible projection: arcs from a menu command, from a
/// scene element and from an anchor of a structural scene live with the projection's transitions;
/// the projection reads only its own and a mutation of it leaves the arcs, the elements and the
/// evidence as they were; evidence names exactly one target, from a confirmed structural source.
@Suite("The brain's general graph beside the projection", .serialized)
struct BrainGraphTests {

    private typealias F = BrainFixtures

    /// `F.t0` as the canonical milliseconds the store keeps.
    private static let t0MS: Int64 = 1_700_000_000_000

    private struct World {
        let memory: SceneFixtures.Memory
        let brain: SQLiteBrainRepository
        let graph: SQLiteBrainGraphRepository
        let menus: SQLiteMenuCommandRepository
        let bundle: String
        let scene: String
        let scope: String
        let element: String
        let anchor: String
    }

    /// A Mail-like window seen once as a structural scene (event e1, confirmed), the projection's
    /// anchors and one projection transition (a click on Compose revealing a menu), and a menu command.
    private func world() async throws -> World {
        let memory = try await SceneFixtures.open()
        let window = SceneFixtures.perceive(SceneFixtures.window("Inbox", [SceneFixtures.button("Compose", y: 700), SceneFixtures.button("Reply", y: 650)]))
        let first = try await SceneFixtures.observe(memory, "e1", window)
        guard case .newScene = first.decision, let scene = first.createdSceneID else { throw EventFactError.missingDefinition(id: "scene") }
        let ids = BrainIdentities()
        let brain = SQLiteBrainRepository(store: memory.store, keys: ids.keys, makeTransitionID: ids.transitionID, makeSceneID: ids.sceneID)
        let bundle = SceneFixtures.app.bundleID
        _ = try await brain.observe(window.scene, now: F.t0)
        let compose = try #require(window.scene.elements.first { $0.label == "Compose" })
        _ = try await brain.record(ActionRecord(bundleID: bundle, element: compose, verb: .click, effect: .menuOpened(labels: ["New", "Reply"]), windowTitleAfter: nil), now: F.t0)
        let graph = SQLiteBrainGraphRepository(store: memory.store)
        let menus = SQLiteMenuCommandRepository(store: memory.store)
        _ = try await menus.record(try MenuCommandRecord(menuCommandID: "m-new", bundleID: bundle, path: ["File", "New Message"], topLevelTitle: "File",
                                                         identifier: nil, hasSubmenu: false, enabled: true, markChar: nil, cmdChar: "N", firstSeenMS: 0, lastSeenMS: 0))
        let scope = try #require(try await memory.store.read { try $0.query("SELECT scene_id FROM brain_scenes WHERE scene_kind = 'app'", []) { try $0.text(0) } }.first ?? nil)
        let element = try #require(try await graph.elements(ofScene: scene).first { $0.scope == .control })
        let anchor = try #require(try await brain.brain(of: bundle)?.objects.first { $0.label == "Reply" }).anchorKey
        return World(memory: memory, brain: brain, graph: graph, menus: menus, bundle: bundle, scene: scene, scope: scope, element: element.sceneElementID, anchor: anchor)
    }

    private func arcs(_ w: World) throws -> [BrainArc] {
        let opened = try TransitionEffectRecord(effect: "menuOpened:Nuovo|Rispondi")
        let titled = try TransitionEffectRecord(kind: "windowTitleChanged", text: "Nuovo messaggio", requiredState: nil, resultingState: nil, items: [])
        return [
            try BrainArc(transitionID: "arc-menu", bundleID: w.bundle, fromSceneID: w.scope, trigger: .menu(menuCommandID: "m-new"), toSceneID: nil,
                         effect: titled, status: .candidate, evidenceCount: 0, firstSeenMS: Self.t0MS, lastSeenMS: Self.t0MS),
            try BrainArc(transitionID: "arc-element", bundleID: w.bundle, fromSceneID: w.scene, trigger: .element(sceneElementID: w.element, gesture: .click),
                         toSceneID: w.scene, effect: opened, status: .trusted, evidenceCount: 2, firstSeenMS: Self.t0MS, lastSeenMS: Self.t0MS, lastObservedEpoch: 1),
            try BrainArc(transitionID: "arc-anchor", bundleID: w.bundle, fromSceneID: w.scene, trigger: .anchor(anchorID: w.anchor, gesture: .rightClick),
                         effect: try TransitionEffectRecord(effect: "elementsAppeared:Inoltra"), status: .rejected, evidenceCount: 0, firstSeenMS: Self.t0MS, lastSeenMS: Self.t0MS),
        ]
    }

    @Test("a menu arc, an element arc and an anchor arc of a structural scene live beside the projection's transition: the projection reads as before, and a later mutation and retirement of it leave the arcs, the elements and their evidence as they were")
    func coexistence() async throws {
        let w = try await world()
        let projection = try #require(try await w.brain.brain(of: w.bundle))
        #expect(projection.transitions.count == 1)
        for arc in try arcs(w) { #expect(try await w.graph.record(arc) == .committed) }
        #expect(try await w.brain.brain(of: w.bundle) == projection, "the projection reads only what it owns")
        let orders = try await w.memory.store.read { try $0.query("SELECT insertion_order FROM brain_transitions ORDER BY insertion_order", []) { $0.integer(0) ?? -1 } }
        #expect(orders == [0, 1, 2, 3], "one order for the application, no collision")
        let evidence = try BrainEvidenceRecord(bundleID: w.bundle, eventID: "e1", target: .transition("arc-element"), relation: .supports, assessedBy: "fixture",
                                               assessmentVersion: "1", assessedAtMS: Self.t0MS)
        #expect(try await w.graph.record(evidence) == .committed)
        // The projection moves on: a new ingest much later retires the anchors it no longer sees.
        for block in 1...20 {
            _ = try await w.brain.ingest([F.det(.control, "Altro", x: 0.9, y: 0.9)], into: w.bundle, now: try F.block(block), window: nil)
        }
        let later = try #require(try await w.brain.brain(of: w.bundle))
        #expect(later != projection, "the projection did change")
        let back = try await w.graph.arcs(of: w.bundle)
        #expect(back.map(\.transitionID) == ["arc-menu", "arc-element", "arc-anchor"])
        for (stored, offered) in zip(back, try arcs(w)) { #expect(stored.isExactly(offered), Comment(rawValue: offered.transitionID)) }
        #expect(try await w.graph.elements(ofScene: w.scene).count >= 2)
        #expect(try await w.graph.evidence(ofEvent: "e1").contains { $0.isExactly(evidence) })
        #expect(try await w.memory.store.read { try $0.query("SELECT count(*) FROM brain_transitions WHERE transition_id LIKE 'arc-%' AND retired_at_ms IS NOT NULL", []) { $0.integer(0) ?? -1 } }.first == 0,
                "no general arc retired by the projection")
        await w.memory.store.close()
    }

    @Test("arcs are recorded once and changed against the arc last read; an anchor arc from the scope is the projection's, an element of another scene, a destination that is the scope or a command of another application are refused")
    func arcRules() async throws {
        let w = try await world()
        let all = try arcs(w)
        for arc in all { _ = try await w.graph.record(arc) }
        #expect(try await w.graph.record(all[1]) == .alreadyApplied)
        let moved = try BrainArc(transitionID: "arc-element", bundleID: w.bundle, fromSceneID: w.scene, trigger: .element(sceneElementID: w.element, gesture: .hover),
                                 toSceneID: w.scene, effect: all[1].effect, status: .trusted, evidenceCount: 2, firstSeenMS: Self.t0MS, lastSeenMS: Self.t0MS, lastObservedEpoch: 1)
        let conflict = await storeError { _ = try await w.graph.record(moved) }
        guard case .identity? = conflict else {
            Issue.record("another arc under the id must be a conflict, got \(String(describing: conflict))")
            return
        }
        let raised = try BrainArc(transitionID: "arc-element", bundleID: w.bundle, fromSceneID: w.scene, trigger: all[1].trigger, toSceneID: w.scene, effect: all[1].effect,
                                  status: .trusted, evidenceCount: 3, firstSeenMS: Self.t0MS, lastSeenMS: Self.t0MS + 10, lastObservedEpoch: 2)
        #expect(try await w.graph.update(from: all[1], to: raised) == .committed)
        #expect(try await w.graph.update(from: all[1], to: raised) == .alreadyApplied)
        #expect(await factError { _ = try await w.graph.update(from: all[1], to: try BrainArc(transitionID: "arc-element", bundleID: w.bundle, fromSceneID: w.scene, trigger: all[1].trigger,
                                                                                        toSceneID: w.scene, effect: all[1].effect, status: .rejected, evidenceCount: 3,
                                                                                        firstSeenMS: Self.t0MS, lastSeenMS: Self.t0MS + 10, lastObservedEpoch: 2)) }
                == .staleExpectation(id: "arc-element"))
        func refused(_ arc: BrainArc, _ expected: EventFactError) async {
            #expect(await factError { _ = try await w.graph.record(arc) } == expected, Comment(rawValue: arc.transitionID))
        }
        let effect = all[0].effect
        await refused(try BrainArc(transitionID: "x-scope-anchor", bundleID: w.bundle, fromSceneID: w.scope, trigger: .anchor(anchorID: w.anchor, gesture: .click),
                                   effect: effect, status: .candidate, evidenceCount: 0, firstSeenMS: 0, lastSeenMS: 0),
                      .invalidRecord(.shape(field: "an anchor arc from the scope is the projection's")))
        await refused(try BrainArc(transitionID: "x-to-scope", bundleID: w.bundle, fromSceneID: w.scene, trigger: .menu(menuCommandID: "m-new"), toSceneID: w.scope,
                                   effect: effect, status: .candidate, evidenceCount: 0, firstSeenMS: 0, lastSeenMS: 0), .missingDefinition(id: w.scope))
        await refused(try BrainArc(transitionID: "x-menu", bundleID: w.bundle, fromSceneID: w.scope, trigger: .menu(menuCommandID: "m-elsewhere"),
                                   effect: effect, status: .candidate, evidenceCount: 0, firstSeenMS: 0, lastSeenMS: 0), .missingDefinition(id: "m-elsewhere"))
        await refused(try BrainArc(transitionID: "x-element", bundleID: w.bundle, fromSceneID: w.scope, trigger: .element(sceneElementID: w.element, gesture: .click),
                                   effect: effect, status: .candidate, evidenceCount: 0, firstSeenMS: 0, lastSeenMS: 0), .missingDefinition(id: w.element))
        let projectionID = try #require(try await w.memory.store.read { try $0.query("SELECT transition_id FROM brain_transitions WHERE transition_id NOT LIKE 'arc-%'", []) { try $0.text(0) } }.first ?? nil)
        #expect(try await w.graph.arc(projectionID) == nil, "a projection transition is read through the projection")
        #expect(try await w.graph.link(element: w.element, toAnchor: w.anchor) == .committed)
        #expect(try await w.graph.link(element: w.element, toAnchor: w.anchor) == .alreadyApplied)
        let relink = await storeError { _ = try await w.graph.link(element: w.element, toAnchor: try await w.brain.brain(of: w.bundle)?.objects.first { $0.label == "Compose" }?.anchorKey ?? "") }
        guard case .identity? = relink else {
            Issue.record("another anchor for a linked element must be a conflict, got \(String(describing: relink))")
            return
        }
        #expect(try await w.graph.elements(ofScene: w.scene).first { $0.sceneElementID == w.element }?.anchorID == w.anchor)
        await w.memory.store.close()
    }

    @Test("evidence names exactly one of the six targets, of the event's application, never the scope; a structural source must be one the event's sample was confirmed in; retried it is already applied, other content a conflict")
    func evidence() async throws {
        let w = try await world()
        for arc in try arcs(w) { _ = try await w.graph.record(arc) }
        // Three aligned controls form a column group in the projection.
        _ = try await w.brain.ingest((0..<3).map { F.det(.control, "Col\($0)", x: 0.2, y: 0.1 + Double($0) * 0.05) }, into: w.bundle, now: F.t0, window: nil)
        let group = try await w.memory.store.read { try $0.query("SELECT group_id FROM brain_groups LIMIT 1", []) { try $0.text(0) } }.first ?? nil
        let groupID = try #require(group, "the two aligned buttons form a group: the sixth kind of target")
        let targets: [BrainEvidenceTarget] = [.scene(w.scene), .anchor(w.anchor), .sceneElement(w.element), .group(groupID), .menuCommand("m-new"),
                                              .transition("arc-element"), .transition("arc-menu")]
        for target in targets {
            let record = try BrainEvidenceRecord(bundleID: w.bundle, eventID: "e1", target: target, relation: .supports, assessedBy: "fixture", assessmentVersion: "1", assessedAtMS: 1)
            #expect(try await w.graph.record(record) == .committed, Comment(rawValue: "\(target)"))
            #expect(try await w.graph.record(record) == .alreadyApplied)
        }
        let changed = await storeError { _ = try await w.graph.record(try BrainEvidenceRecord(bundleID: w.bundle, eventID: "e1", target: .scene(w.scene), relation: .supports,
                                                                                             assessedBy: "another", assessmentVersion: "1", assessedAtMS: 1)) }
        guard case .identity? = changed else {
            Issue.record("the same key with other content must be a conflict, got \(String(describing: changed))")
            return
        }
        _ = try await w.memory.captures.record(SceneFixtures.event("e-unseen"))
        #expect(await factError { _ = try await w.graph.record(try BrainEvidenceRecord(bundleID: w.bundle, eventID: "e-unseen", target: .transition("arc-element"), relation: .supports,
                                                                                      assessedBy: "fixture", assessmentVersion: "1", assessedAtMS: 1)) }
                == .invalidRecord(.shape(field: "unconfirmed structural source")))
        #expect(try await w.graph.record(try BrainEvidenceRecord(bundleID: w.bundle, eventID: "e-unseen", target: .transition("arc-menu"), relation: .contradicts,
                                                                 assessedBy: "fixture", assessmentVersion: "1", assessedAtMS: 1)) == .committed,
                "an arc from the scope needs no structural source")
        #expect(await factError { _ = try await w.graph.record(try BrainEvidenceRecord(bundleID: w.bundle, eventID: "e1", target: .scene(w.scope), relation: .supports,
                                                                                      assessedBy: "fixture", assessmentVersion: "1", assessedAtMS: 1)) }
                == .invalidRecord(.shape(field: "the application's scope is never evidence")))
        _ = try await w.memory.captures.record(SceneFixtures.event("e-other", app: AppContextIdentity(bundleID: "test.other")))
        _ = try await w.menus.record(try MenuCommandRecord(menuCommandID: "m-other", bundleID: "test.other", path: ["X"], topLevelTitle: "X", identifier: nil, hasSubmenu: false,
                                                           enabled: true, markChar: nil, cmdChar: nil, firstSeenMS: 0, lastSeenMS: 0))
        #expect(await factError { _ = try await w.graph.record(try BrainEvidenceRecord(bundleID: w.bundle, eventID: "e-other", target: .menuCommand("m-new"), relation: .supports,
                                                                                      assessedBy: "fixture", assessmentVersion: "1", assessedAtMS: 1)) }
                == .invalidRecord(.appContradiction))
        #expect(await factError { _ = try await w.graph.record(try BrainEvidenceRecord(bundleID: w.bundle, eventID: "e1", target: .menuCommand("m-other"), relation: .supports,
                                                                                      assessedBy: "fixture", assessmentVersion: "1", assessedAtMS: 1)) }
                == .missingDefinition(id: "m-other"))
        #expect(try await w.graph.evidence(ofEvent: "e1").count == targets.count)
        await w.memory.store.close()
    }

    @Test("evidence written by hand within the constraints, on a structural scene or an arc from it, for an event with no confirmed association there, is refused by its reader; confirmed structural evidence and evidence of the scope's knowledge stay readable; the store goes on")
    func unconfirmedEvidence() async throws {
        let w = try await world()
        for arc in try arcs(w) { _ = try await w.graph.record(arc) }
        let confirmed = try BrainEvidenceRecord(bundleID: w.bundle, eventID: "e1", target: .scene(w.scene), relation: .supports, assessedBy: "fixture",
                                                assessmentVersion: "1", assessedAtMS: 1)
        #expect(try await w.graph.record(confirmed) == .committed)
        #expect(try await w.graph.evidence(ofEvent: "e1").map { $0.isExactly(confirmed) } == [true], "a structural source the event was confirmed in")
        _ = try await w.memory.captures.record(SceneFixtures.event("e-unseen"))
        for target in [BrainEvidenceTarget.anchor(w.anchor), .transition("arc-menu")] {
            #expect(try await w.graph.record(try BrainEvidenceRecord(bundleID: w.bundle, eventID: "e-unseen", target: target, relation: .supports, assessedBy: "fixture",
                                                                     assessmentVersion: "1", assessedAtMS: 1)) == .committed, Comment(rawValue: "\(target)"))
        }
        #expect(try await w.graph.evidence(ofEvent: "e-unseen").count == 2, "an anchor and an arc from the scope ask for no structural scene")
        for (column, target) in [("scene_id", w.scene), ("scene_element_id", w.element), ("transition_id", "arc-element")] {
            #expect(await factError { _ = try await w.graph.record(try BrainEvidenceRecord(bundleID: w.bundle, eventID: "e-unseen",
                                                                                          target: column == "scene_id" ? .scene(target) : column == "scene_element_id" ? .sceneElement(target) : .transition(target),
                                                                                          relation: .supports, assessedBy: "fixture", assessmentVersion: "1", assessedAtMS: 1)) }
                    == .invalidRecord(.shape(field: "unconfirmed structural source")), Comment(rawValue: column))
            try await w.memory.store.write { transaction in
                try transaction.execute(
                    """
                    INSERT INTO brain_evidence (app_id, event_id, relation, assessed_by, assessment_version, assessed_at_ms, \(column))
                    SELECT app_id, 'e-unseen', 'supports', 'by hand', '1', 1, ? FROM brain_apps WHERE bundle_id = ?
                    """,
                    [.text(target), .text(w.bundle)])
            }
            let planted = try #require(try await w.memory.store.read { try $0.query("SELECT max(evidence_id) FROM brain_evidence", []) { $0.integer(0) } }.first ?? nil)
            #expect(await factError { _ = try await w.graph.evidence(ofEvent: "e-unseen") }
                    == .malformedRow(table: "brain_evidence", id: "\(planted)", malformation: .invalid(.shape(field: "unconfirmed structural source"))),
                    Comment(rawValue: column))
            #expect(try await w.graph.evidence(ofEvent: "e1").count == 1, "another event's evidence is still read")
            try await w.memory.store.write { try $0.execute("DELETE FROM brain_evidence WHERE evidence_id = ?", [.integer(planted)]) }
        }
        #expect(try await w.graph.evidence(ofEvent: "e-unseen").count == 2, "the store goes on")
        await w.memory.store.close()
    }

    @Test("a general arc written by hand with an unknown trigger or effect, or a menu arc with a gesture, is refused by its reader; a row the projection owns that breaks its contract still fails the projection; the overview tells the parts apart")
    func malformedAndOverview() async throws {
        let w = try await world()
        for arc in try arcs(w) { _ = try await w.graph.record(arc) }
        let overview = try await w.graph.overview()
        let app = try #require(overview.apps.first { $0.bundleID == w.bundle })
        #expect(app.projectionTransitions == 1 && app.generalArcs == 3 && app.menuCommands == 1 && app.structuralScenes == 1 && app.events == 1 && app.samples == 1)
        #expect(app.projectionAnchors >= 2 && app.sceneElements >= 2)
        #expect(overview.routes[.active] == 0 && overview.experiences == 0)
        let evidence = try await w.memory.store.read { snapshot in
            try snapshot.query("""
                SELECT a.bundle_id, count(e.evidence_id) FROM brain_apps a LEFT JOIN brain_evidence e ON e.app_id = a.app_id
                GROUP BY a.bundle_id
                """, []) { (bundle: try $0.text(0) ?? "", count: Int($0.integer(1) ?? 0)) }
        }
        #expect(overview.apps.map { "\($0.bundleID)=\($0.brainEvidence)" } == evidence.sorted { $0.bundle < $1.bundle }.map { "\($0.bundle)=\($0.count)" },
                "each application's evidence, none included, is the table's own count")
        try await w.memory.store.write { transaction in
            try transaction.execute("UPDATE brain_transitions SET trigger_kind = 'swipe' WHERE transition_id = 'arc-element'")
            try transaction.execute("UPDATE brain_transitions SET trigger_kind = 'click' WHERE transition_id = 'arc-menu'")
            try transaction.execute("UPDATE brain_transitions SET effect_kind = 'teleport' WHERE transition_id = 'arc-anchor'")
        }
        #expect(await factError { _ = try await w.graph.arc("arc-element") }
                == .malformedRow(table: "brain_transitions", id: "arc-element", malformation: .unknownCode(column: "trigger_kind", code: "swipe")))
        #expect(await factError { _ = try await w.graph.arc("arc-menu") }
                == .malformedRow(table: "brain_transitions", id: "arc-menu", malformation: .unknownCode(column: "trigger_kind", code: "click")))
        if case .malformedRow(_, "arc-anchor", .unknownCode(column: "effect", _))? = await factError({ _ = try await w.graph.arc("arc-anchor") }) {} else {
            Issue.record("an unknown effect must be refused by the arc's reader")
        }
        #expect(try await w.brain.brain(of: w.bundle)?.transitions.count == 1, "the projection does not read the general arcs, malformed or not")
        try await w.memory.store.write { transaction in
            try transaction.execute(
                """
                INSERT INTO brain_transitions (transition_id, app_id, insertion_order, from_scene_id, trigger_kind, effect_kind, effect_text, status, first_seen_ms, last_seen_ms)
                SELECT 'owned-broken', app_id, 99, scene_id, 'click', 'windowTitleChanged', 'x', 'candidate', 0, 0 FROM brain_scenes WHERE scene_kind = 'app'
                """)
        }
        let projectionError = await { () async -> (any Error)? in
            do { _ = try await w.brain.brain(of: w.bundle); return nil } catch { return error }
        }()
        #expect(projectionError as? BrainProjectionError == .malformedRow(table: "brain_transitions", id: "owned-broken", malformation: .missingColumn("anchor_id")),
                "a row the projection owns is not hidden")
        await w.memory.store.close()
    }
}
