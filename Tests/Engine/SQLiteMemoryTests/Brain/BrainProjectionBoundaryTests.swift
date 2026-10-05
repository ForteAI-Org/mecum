//
//  BrainProjectionBoundaryTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

import CoreGraphics
import EngineCore
import Foundation
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// Where the brain's projection meets the rest of the file: memberships another hand wrote, the
/// references Routes and calls hold to a retired anchor, the structural scenes of the first S2
/// increment beside the application's scope, and the limits this increment declares: a clock
/// outside the representable range, a number the file cannot keep, and a second identical
/// mutation, which is applied again because no event identifies it yet.
@Suite("The brain's projection beside the rest of the living memory")
struct BrainProjectionBoundaryTests {

    private typealias F = BrainFixtures

    private func det(_ kind: ElementKind, _ label: String, x: Double, y: Double,
                     w: Double = 0.03, h: Double = 0.017, state: ControlState? = nil) -> BrainDetection {
        F.det(kind, label, x: x, y: y, w: w, h: h, state: state)
    }

    @Test("an impostor written into a stored membership is evicted by the next merge as in the pure brain, with its row and its current group gone")
    func impostorEvicted() async throws {
        let twin = try await F.Twin()
        try await twin.ingest(F.switchColumn(states: Array(repeating: .off, count: 8)), at: F.t0)
        let sidebar = (0..<4).map {
            det(.control, ["Home", "Downloads", "Documents", "Desktop"][$0], x: 0.028, y: 0.18 + Double($0) * 0.036, w: 0.06)
        }
        try await twin.ingest(sidebar, at: F.t1)
        #expect(twin.reference.groups.count == 2)
        let impostor = try #require(twin.anchor(labeled: "Home")).anchorKey
        let gi = try #require(twin.reference.groups.firstIndex { $0.memberAnchors.count == 8 })
        let column = twin.reference.groups[gi].id
        // The same corruption on both sides: an impostor appended to the column, as UIBrainTests.impostors does.
        twin.reference.groups[gi].memberAnchors.append(impostor)
        let appID = try #require(try await twin.memory.integers("SELECT app_id FROM brain_apps").first ?? nil)
        try await twin.memory.store.write { transaction in
            try transaction.execute(
                "INSERT INTO brain_group_members (app_id, group_id, anchor_id, position) VALUES (?, ?, ?, 8)",
                [.integer(appID), .text(column.uuidString), .text(impostor)]
            )
        }
        try await twin.check()
        try await twin.ingest(F.switchColumn(states: Array(repeating: .off, count: 8)), at: F.t1)
        #expect(twin.reference.groups[gi].memberAnchors.count == 8)
        #expect(twin.reference.objects.first { $0.anchorKey == impostor }?.groupID == nil)
        #expect(try await twin.memory.integers(
            "SELECT count(*) FROM brain_group_members WHERE group_id = ? AND anchor_id = ?", [.text(column.uuidString), .text(impostor)]
        ) == [0])
        #expect(try await twin.memory.integers("SELECT position FROM brain_group_members WHERE group_id = ? ORDER BY position", [.text(column.uuidString)])
                == (0..<8).map { Int64($0) })
        await twin.close()
    }

    @Test("a Route check, a call argument and an evidence link to an anchor stay readable after the anchor is retired, and the evidence count is the projection's own")
    func referencesToRetiredRows() async throws {
        let twin = try await F.Twin()
        try await twin.ingest(F.scene(["Send", "Draft", "Discard"]) + [det(.control, "Once", x: 0.9, y: 0.9)], at: try F.block(0))
        let once = try #require(twin.anchor(labeled: "Once"))
        try await twin.record(F.element("c|once", "Once", x: 0.9, y: 0.9), effect: .stateFlip(from: .off, to: .on), at: try F.block(0))
        let appID = try #require(try await twin.memory.integers("SELECT app_id FROM brain_apps").first ?? nil)
        let transitionID = try #require(try await twin.memory.texts("SELECT transition_id FROM brain_transitions").first)
        try await twin.memory.store.write { transaction in
            try transaction.execute(
                """
                INSERT INTO memory_events (event_id, source, source_stream_id, source_key, event_kind, app_id, occurred_at_ms, capture_status)
                VALUES ('call', 'app', 'worker', 'call', 'action', ?, 1, 'not_applicable')
                """,
                [.integer(appID)]
            )
            try transaction.execute(
                "INSERT INTO memory_agent_actions (event_id, app_id, tool_kind, execution_status) VALUES ('call', ?, 'act', 'completed')",
                [.integer(appID)]
            )
            try transaction.execute(
                """
                INSERT INTO memory_operation_arguments (event_id, app_id, argument_name, value_kind, anchor_id)
                VALUES ('call', ?, 'target', 'anchor', ?)
                """,
                [.integer(appID), .text(once.anchorKey)]
            )
            try transaction.execute("INSERT INTO memory_routes (route_id, name, status, created_at_ms) VALUES ('route', 'Toggle', 'draft', 0)")
            try transaction.execute(
                "INSERT INTO memory_route_steps (step_id, route_id, position, step_kind, goal_text, app_id) VALUES ('step', 'route', 0, 'goal', 'On', ?)",
                [.integer(appID)]
            )
            try transaction.execute(
                """
                INSERT INTO memory_step_checks (check_id, route_id, step_id, app_id, position, check_kind, expected_anchor_id, expected_state)
                VALUES ('check', 'route', 'step', ?, 0, 'state', ?, 'on')
                """,
                [.integer(appID), .text(once.anchorKey)]
            )
            for (column, value) in [("anchor_id", once.anchorKey), ("transition_id", transitionID)] {
                try transaction.execute(
                    """
                    INSERT INTO brain_evidence (app_id, event_id, relation, assessed_by, assessment_version, assessed_at_ms, \(column))
                    VALUES (?, 'call', 'supports', 'fixture', '1', 1, ?)
                    """,
                    [.integer(appID), .text(value)]
                )
            }
        }
        try await twin.check()
        #expect(twin.reference.transitions.first?.evidence == 1, "a link row is not evidence of the projection")
        for i in 1...12 { try await twin.ingest(F.scene(["Send", "Draft", "Discard"]), at: try F.block(i)) }
        #expect(twin.anchor(labeled: "Once") == nil)
        #expect(try await twin.memory.texts("SELECT retirement_cause FROM brain_anchors WHERE anchor_id = ?", [.text(once.anchorKey)]) == ["transient"])
        #expect(try await twin.memory.texts("SELECT expected_anchor_id FROM memory_step_checks") == [once.anchorKey])
        #expect(try await twin.memory.texts("SELECT anchor_id FROM memory_operation_arguments") == [once.anchorKey])
        #expect(try await twin.memory.integers("SELECT count(*) FROM brain_evidence") == [2])
        #expect(try await twin.memory.texts("SELECT label FROM brain_anchors a JOIN memory_step_checks c ON c.expected_anchor_id = a.anchor_id") == ["Once"])
        #expect(try await twin.memory.foreignKeyCheck() == 0)
        await twin.close()
    }

    @Test("the structural scenes and associations of the first increment stay valid and apart: the brain's scope is one row of its own, never a candidate")
    func structuralScenesStayApart() async throws {
        let scenes = try await SceneFixtures.open()
        let window = SceneFixtures.perceive(SceneFixtures.window("Inbox", [
            SceneFixtures.button("Compose", y: 700), SceneFixtures.table("Messages", rows: ["Alice", "Bob"]),
        ]))
        let first = try await SceneFixtures.observe(scenes, "e1", window)
        #expect(first.decision == .newScene)
        let ids = BrainIdentities()
        let brain = SQLiteBrainRepository(store: scenes.store, keys: ids.keys, makeTransitionID: ids.transitionID, makeSceneID: ids.sceneID)
        let bundle = SceneFixtures.app.bundleID
        _ = try await brain.observe(window.scene, now: F.t0)
        let compose = try #require(window.scene.elements.first { $0.label == "Compose" })
        let outcome = try await brain.record(
            ActionRecord(bundleID: bundle, element: compose, verb: .click, effect: .menuOpened(labels: ["New", "Reply"]), windowTitleAfter: nil),
            now: F.t0
        )
        guard case .recorded = outcome else {
            Issue.record("expected the reveal to be recorded, got \(outcome)")
            return
        }
        let kinds = try await scenes.store.read { try $0.query("SELECT scene_kind FROM brain_scenes ORDER BY scene_kind") { try $0.text(0) ?? "" } }
        #expect(kinds == ["app", "window"])
        #expect(try await scenes.scenes.scenes(of: bundle).map(\.id) == ["scene-1"], "the scope is never offered as a scene")
        let second = try await SceneFixtures.observe(scenes, "e2", window)
        #expect(second.decision == .confirmed(sceneID: "scene-1"))
        #expect(try await count("SELECT count(*) FROM memory_event_scenes WHERE scene_id = 'scene-1' AND match_status = 'confirmed'", in: scenes.store) == 2)
        #expect(try await count("SELECT count(*) FROM memory_event_scenes WHERE scene_id = 'scope-1'", in: scenes.store) == 0)
        #expect(try await count("SELECT count(*) FROM brain_transitions WHERE from_scene_id = 'scope-1' AND to_scene_id IS NULL", in: scenes.store) == 1)
        #expect(try await count("SELECT observation_count FROM brain_scenes WHERE scene_id = 'scope-1'", in: scenes.store) == 0)
        #expect(try await count("SELECT count(*) FROM brain_scene_elements WHERE scene_id = 'scope-1'", in: scenes.store) == 0)
        let loaded = try #require(try await brain.brain(of: bundle))
        #expect(loaded.transitions.map(\.effect) == ["menuOpened:New|Reply"])
        #expect(try await scenes.store.read { try $0.query("PRAGMA foreign_key_check") { _ in () } }.isEmpty)
        await scenes.store.close()
    }

    @Test("F7 through the store: a scene the accessibility tree never read teaches anchors and creates no structural scene, no sample and no scope")
    func pixelOnlySceneCreatesNoStructure() async throws {
        let memory = try await F.open()
        let pixels = SceneFixtures.pixelsOnly(["Inbox", "Compose", "Settings"], title: "Mail")
        #expect(pixels.capture == .unknown && pixels.surface == .unknown)
        let scene = SceneSnapshot(
            bundleID: F.bundle, appName: "Fixture", windowTitle: "Mail",
            viewportPixelSize: pixels.scene.viewportPixelSize,
            elements: pixels.scene.elements + [
                F.element("icon|gear", "(unlabeled)", x: 0.9, y: 0.05, kind: .icon, unlabeled: true),
                F.element("icon|bell", "(unlabeled)", x: 0.85, y: 0.05, kind: .icon, unlabeled: true),
                F.element("control|go", "Go", x: 0.5, y: 0.5),
            ]
        )
        let stats = try await memory.brain.observe(scene, now: F.t0)
        #expect(stats.created == 3)
        #expect(try await memory.integers("SELECT count(*) FROM brain_scenes") == [0])
        #expect(try await memory.integers("SELECT count(*) FROM memory_event_observations") == [0])
        #expect(try await memory.integers("SELECT count(*) FROM memory_events") == [0])
        #expect(try await memory.load()?.objects.map(\.window) == ["mail", "mail", "mail"])
        await memory.store.close()
    }

    @Test("a clock outside the representable range is a typed refusal through the repository, and nothing is written")
    func clockOutOfRange() async throws {
        let memory = try await F.open()
        await #expect(throws: BrainProjectionError.clock(.dateOutOfRange(seconds: 1e16))) {
            _ = try await memory.brain.ingest(F.scene(["A", "B", "C"]), into: F.bundle, now: Date(timeIntervalSince1970: 1e16), window: nil)
        }
        await #expect(throws: BrainProjectionError.clock(.notFinite)) {
            _ = try await memory.brain.setName("x", anchorKey: "k", in: F.bundle, now: Date(timeIntervalSince1970: .nan))
        }
        #expect(try await memory.integers("SELECT count(*) FROM brain_apps") == [0])
        await memory.store.close()
    }

    @Test("a bound or a cell size that is not a finite number is refused before the commit, never stored as NULL or an infinity")
    func nonFiniteNumbersRefused() async throws {
        let memory = try await F.open()
        await #expect(throws: BrainProjectionError.unrepresentableNumber(table: "brain_anchors", id: "anchor-1", column: "typical_x")) {
            _ = try await memory.brain.ingest([det(.control, "Broken", x: .nan, y: 0.1)], into: F.bundle, now: F.t0, window: nil)
        }
        #expect(try await memory.integers("SELECT count(*) FROM brain_anchors") == [0])
        await #expect(throws: BrainProjectionError.unrepresentableNumber(table: "brain_anchors", id: "anchor-2", column: "typical_height")) {
            _ = try await memory.brain.ingest([det(.control, "Tall", x: 0.1, y: 0.1, h: .infinity)], into: F.bundle, now: F.t0, window: nil)
        }
        #expect(try await memory.load() == nil)
        let stats = try await memory.brain.ingest([det(.control, "Tiny", x: 5e-324, y: 1e-300)], into: F.bundle, now: F.t0, window: nil)
        #expect(stats.created == 1)
        #expect(try await memory.load()?.objects.first?.boundsTypical == F.rect(5e-324, 1e-300), "extreme finite values are kept exactly")
        await memory.store.close()
    }

    @Test("a second identical mutation is a new evaluation and moves the counters again: the projection does not deduplicate by event yet")
    func secondMutationIsApplied() async throws {
        let twin = try await F.Twin()
        let export = F.element("c|export", "Export", x: 0.1, y: 0.1)
        try await twin.ingest(F.scene(["Export", "Cancel", "Help"], x: 0.1), at: F.t0)
        try await twin.ingest(F.scene(["Export", "Cancel", "Help"], x: 0.1), at: F.t0)
        #expect(twin.anchor(labeled: "Export")?.seenCount == 2)
        try await twin.record(export, effect: .stateFlip(from: .off, to: .on), at: F.t0)
        let again = try await twin.record(export, effect: .stateFlip(from: .off, to: .on), at: F.t0)
        guard case .recorded(_, 2) = again else {
            Issue.record("the same record offered twice counts twice, got \(again)")
            return
        }
        #expect(try await twin.memory.integers("SELECT evidence_count FROM brain_transitions") == [2])
        #expect(try await twin.memory.integers("SELECT count(*) FROM brain_evidence") == [0], "no evidence link is fabricated for a counter")
        #expect(try await twin.memory.integers("SELECT count(*) FROM memory_events") == [0], "no event is fabricated for a counter")
        await twin.close()
    }
}
