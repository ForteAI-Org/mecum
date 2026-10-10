//
//  SchemaResourceTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import Foundation
import Memory
@testable import SQLiteMemory
import Testing

/// The three writes the S0 closing review found the v5 candidate still admitted, now refused by
/// the included resource, and the symmetry of the app-scope rules on INSERT and UPDATE. Every
/// case runs through the store on a temporary file, so the resource proven is the one shipped.
@Suite("The included schema resource")
struct SchemaResourceTests {

    /// One app with a structural scene and its scope; three events: a complete sample with a
    /// confirmed scene, a partial sample with a candidate scene, and a sample nobody references.
    /// No sample has child rows, so no foreign key of a child can mask what the triggers decide.
    private func fixture() async throws -> SQLiteMemoryStore {
        let store = try await SQLiteMemoryStore.open(at: try temporaryDatabase())
        try await store.write { transaction in
            try transaction.execute("INSERT INTO brain_apps (app_id, bundle_id) VALUES (1, 'test.synthetic')")
            try transaction.execute(
                "INSERT INTO brain_scenes (scene_id, app_id, title_bucket, first_seen_ms, last_seen_ms) VALUES ('scene', 1, 'Test', 0, 100)"
            )
            try transaction.execute(
                """
                INSERT INTO brain_scenes (scene_id, app_id, title_bucket, scene_kind, first_seen_ms, last_seen_ms, observation_count)
                VALUES ('app-scope', 1, '#app', 'app', 0, 100, 0)
                """
            )
            try transaction.execute("INSERT INTO brain_scene_roles (scene_id, role) VALUES ('scene', 'AXButton')")
            try transaction.execute("INSERT INTO brain_scene_labels (scene_id, label_token) VALUES ('scene', 'send')")
            for event in ["event1", "event2", "event3"] {
                try transaction.execute(
                    """
                    INSERT INTO memory_events (event_id, source, source_stream_id, source_key, event_kind, app_id, occurred_at_ms, capture_status)
                    VALUES (?, 'app', 'stream', ?, 'action', 1, 100, 'complete')
                    """,
                    [.text(event), .text(event)]
                )
            }
            try transaction.execute(
                """
                INSERT INTO memory_event_observations (observation_id, event_id, phase, sample_ordinal, observation_kind, status, surface_kind)
                VALUES (1, 'event1', 'after', 0, 'capture', 'complete', 'window'),
                       (2, 'event2', 'after', 0, 'capture', 'partial', 'window'),
                       (3, 'event3', 'before', 0, 'capture', 'complete', 'window')
                """
            )
            try transaction.execute(
                """
                INSERT INTO memory_event_scenes (event_id, app_id, phase, sample_ordinal, scene_id, match_status, matched_by, matcher_version)
                VALUES ('event1', 1, 'after', 0, 'scene', 'confirmed', 'rules', 'test'),
                       ('event2', 1, 'after', 0, 'scene', 'candidate', 'rules', 'test')
                """
            )
        }
        return store
    }

    @Test("the resources ship schema 2: 66 tables, 75 triggers and 41 indexes, the four S1 triggers among them, and no JSON column")
    func shape() async throws {
        let store = try await fixture()
        #expect(try await store.read { snapshot in try SchemaShape(snapshot) } == SchemaShape.current)
        let triggers = try await store.read { snapshot in
            try snapshot.query("SELECT name FROM sqlite_schema WHERE type = 'trigger' ORDER BY name") { try $0.text(0) ?? "" }
        }
        for name in ["brain_scene_roles_not_app_scope_update", "brain_scene_labels_not_app_scope_update",
                     "memory_event_observations_capture_identity_guard", "memory_event_observations_capture_delete_guard",
                     "memory_event_observations_capture_status_guard"] {
            #expect(triggers.contains(name), "\(name) is missing")
        }
        let json = try await store.read { snapshot in
            try snapshot.query("SELECT name FROM sqlite_schema WHERE type = 'table' AND upper(sql) LIKE '%JSON%'") { try $0.text(0) ?? "" }
        }
        #expect(json.isEmpty)
        #expect(try await store.read { snapshot in try snapshot.query("PRAGMA foreign_key_check") { try $0.text(0) ?? "" } }.isEmpty)
    }

    @Test("a structural role or label cannot be moved onto the app scope by UPDATE, as it cannot be inserted there")
    func rolesAndLabelsStayOffTheAppScope() async throws {
        let store = try await fixture()
        let role = await refusal(of: "UPDATE brain_scene_roles SET scene_id = 'app-scope' WHERE scene_id = 'scene'", in: store)
        #expect(role?.code.extended == 1811)
        #expect(role?.message.contains("the app scope has no roles") == true)
        let label = await refusal(of: "UPDATE brain_scene_labels SET scene_id = 'app-scope' WHERE scene_id = 'scene'", in: store)
        #expect(label?.code.extended == 1811)
        #expect(label?.message.contains("the app scope has no labels") == true)
        #expect(await refusal(of: "INSERT INTO brain_scene_roles (scene_id, role) VALUES ('app-scope', 'AXButton')", in: store) != nil)
        #expect(await refusal(of: "INSERT INTO brain_scene_labels (scene_id, label_token) VALUES ('app-scope', 'send')", in: store) != nil)
        #expect(try await count("SELECT count(*) FROM brain_scene_roles WHERE scene_id = 'scene'", in: store) == 1)
        #expect(try await count("SELECT count(*) FROM brain_scene_labels WHERE scene_id = 'scene'", in: store) == 1)
        #expect(try await count("SELECT count(*) FROM brain_scene_roles WHERE scene_id = 'app-scope'", in: store) == 0)
    }

    @Test("a capture sample that a scene association references keeps its event_id, whether the association is confirmed or a candidate")
    func referencedSampleKeepsItsEvent() async throws {
        let store = try await fixture()
        let confirmed = await refusal(of: "UPDATE memory_event_observations SET event_id = 'event3' WHERE observation_id = 1", in: store)
        #expect(confirmed?.code.extended == 1811)
        #expect(confirmed?.message.contains("keeps its identity") == true)
        #expect(await refusal(of: "UPDATE memory_event_observations SET event_id = 'event3' WHERE observation_id = 2", in: store) != nil)
        #expect(await refusal(of: "UPDATE memory_event_observations SET sample_ordinal = 5 WHERE observation_id = 1", in: store) != nil)
        #expect(await refusal(of: "UPDATE memory_event_observations SET phase = 'current' WHERE observation_id = 2", in: store) != nil)
        #expect(await refusal(of: "UPDATE memory_event_observations SET observation_kind = 'element' WHERE observation_id = 1", in: store) != nil)

        let moved = try await store.write { transaction in
            try transaction.execute("UPDATE memory_event_observations SET event_id = 'event2' WHERE observation_id = 3")
        }
        #expect(moved == 1)
        let association = try await store.read { snapshot in
            try snapshot.query("SELECT event_id FROM memory_event_scenes WHERE match_status = 'confirmed'") { try $0.text(0) ?? "" }
        }
        #expect(association == ["event1"])
        #expect(try await count("SELECT count(*) FROM memory_event_observations WHERE observation_id = 1 AND event_id = 'event1'", in: store) == 1)
        #expect(try await store.read { snapshot in try snapshot.query("PRAGMA foreign_key_check") { try $0.text(0) ?? "" } }.isEmpty)
    }

    @Test("a capture sample that a scene association references cannot be deleted; an unreferenced one and a child row can")
    func referencedSampleCannotBeDeleted() async throws {
        let store = try await fixture()
        let confirmed = await refusal(of: "DELETE FROM memory_event_observations WHERE observation_id = 1", in: store)
        #expect(confirmed?.code.extended == 1811)
        #expect(confirmed?.message.contains("cannot be deleted") == true)
        #expect(await refusal(of: "DELETE FROM memory_event_observations WHERE observation_id = 2", in: store) != nil)
        #expect(try await count("SELECT count(*) FROM memory_event_observations", in: store) == 3)

        let deleted = try await store.write { transaction in
            try transaction.execute("DELETE FROM memory_event_observations WHERE observation_id = 3")
        }
        #expect(deleted == 1)
        let child = try await store.write { transaction in
            try transaction.execute(
                """
                INSERT INTO memory_event_observations (observation_id, event_id, phase, sample_ordinal, observation_kind, field_name, integer_value, status, parent_observation_id)
                VALUES (4, 'event1', 'after', 0, 'capture_field', 'nodes_visited', 120, 'observed', 1)
                """
            )
            return try transaction.execute("DELETE FROM memory_event_observations WHERE observation_id = 4")
        }
        #expect(child == 1)
        #expect(try await count("SELECT count(*) FROM memory_event_scenes", in: store) == 2)
    }

    @Test("an unconfirmed sample may still be corrected, and a confirmed one keeps its complete status")
    func statusCorrections() async throws {
        let store = try await fixture()
        let corrected = try await store.write { transaction in
            try transaction.execute("UPDATE memory_event_observations SET status = 'complete' WHERE observation_id = 2")
        }
        #expect(corrected == 1)
        let promoted = try await store.write { transaction in
            try transaction.execute("UPDATE memory_event_scenes SET match_status = 'confirmed' WHERE event_id = 'event2'")
        }
        #expect(promoted == 1)
        let downgraded = await refusal(of: "UPDATE memory_event_observations SET status = 'partial' WHERE observation_id = 1", in: store)
        #expect(downgraded?.message.contains("complete status") == true)
        #expect(await refusal(of: "UPDATE memory_event_observations SET status = 'failed' WHERE observation_id = 2", in: store) != nil)
    }

    @Test("every app-scope rule refuses the INSERT and the UPDATE that would put structure, association, evidence or a destination on the scope")
    func appScopeRulesAreSymmetric() async throws {
        let store = try await fixture()
        try await store.write { transaction in
            try transaction.execute(
                """
                INSERT INTO brain_scene_elements (scene_element_id, app_id, scene_id, element_key, first_seen_ms, last_seen_ms)
                VALUES ('element', 1, 'scene', 'AXButton|send', 0, 100)
                """
            )
            try transaction.execute(
                """
                INSERT INTO brain_evidence (evidence_id, app_id, event_id, relation, assessed_by, assessment_version, assessed_at_ms, scene_id)
                VALUES (1, 1, 'event1', 'supports', 'rules', 'test', 100, 'scene')
                """
            )
            try transaction.execute(
                """
                INSERT INTO brain_transitions (transition_id, app_id, insertion_order, from_scene_id, trigger_kind, to_scene_id, effect_kind, status, first_seen_ms, last_seen_ms)
                VALUES ('t1', 1, 0, 'scene', 'click', 'scene', 'navigation', 'candidate', 0, 100)
                """
            )
        }
        let inserts = [
            "INSERT INTO brain_scene_elements (scene_element_id, app_id, scene_id, element_key, first_seen_ms, last_seen_ms) VALUES ('e2', 1, 'app-scope', 'k', 0, 0)",
            "INSERT INTO brain_scene_roles (scene_id, role) VALUES ('app-scope', 'AXGroup')",
            "INSERT INTO brain_scene_labels (scene_id, label_token) VALUES ('app-scope', 'x')",
            "INSERT INTO memory_event_scenes (event_id, app_id, phase, sample_ordinal, scene_id, match_status, matched_by, matcher_version) VALUES ('event3', 1, 'before', 0, 'app-scope', 'candidate', 'rules', 'test')",
            "INSERT INTO brain_evidence (evidence_id, app_id, event_id, relation, assessed_by, assessment_version, assessed_at_ms, scene_id) VALUES (2, 1, 'event2', 'supports', 'rules', 'test', 100, 'app-scope')",
            "INSERT INTO brain_transitions (transition_id, app_id, insertion_order, from_scene_id, trigger_kind, to_scene_id, effect_kind, status, first_seen_ms, last_seen_ms) VALUES ('t2', 1, 1, 'scene', 'click', 'app-scope', 'navigation', 'candidate', 0, 100)",
        ]
        let updates = [
            "UPDATE brain_scene_elements SET scene_id = 'app-scope' WHERE scene_element_id = 'element'",
            "UPDATE brain_scene_roles SET scene_id = 'app-scope' WHERE scene_id = 'scene'",
            "UPDATE brain_scene_labels SET scene_id = 'app-scope' WHERE scene_id = 'scene'",
            "UPDATE memory_event_scenes SET scene_id = 'app-scope' WHERE event_id = 'event1'",
            "UPDATE brain_evidence SET scene_id = 'app-scope' WHERE evidence_id = 1",
            "UPDATE brain_transitions SET to_scene_id = 'app-scope' WHERE transition_id = 't1'",
            "UPDATE brain_scenes SET scene_kind = 'window' WHERE scene_id = 'app-scope'",
        ]
        for sql in inserts + updates {
            let fault = await refusal(of: sql, in: store)
            #expect(fault?.code.extended == 1811, Comment(rawValue: sql))
        }
        #expect(try await count("SELECT count(*) FROM brain_scene_elements WHERE scene_id = 'app-scope'", in: store) == 0)
        #expect(try await count("SELECT count(*) FROM memory_event_scenes WHERE scene_id = 'app-scope'", in: store) == 0)
        #expect(try await count("SELECT count(*) FROM brain_evidence WHERE scene_id = 'app-scope'", in: store) == 0)
        #expect(try await count("SELECT count(*) FROM brain_transitions WHERE to_scene_id = 'app-scope'", in: store) == 0)
    }
}
