//
//  ObservationContractTests.swift
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

/// The observation contract: the registry of kinds and versions, the status vocabularies, the
/// eight quality fields, and the refusal of every stored row this build does not know. Each read
/// refusal runs through the store on a temporary file with rows written by raw SQL, the way another
/// writer or damage would leave them.
@Suite("The observation contract")
struct ObservationContractTests {

    private let key = CaptureSampleKey(eventID: "ev", phase: .current)

    @Test("the registry resolves its three kinds at version 1 and refuses unknown codes and versions")
    func registry() throws {
        #expect(try ObservationKind.resolve(code: "capture", version: 1) == .capture)
        #expect(try ObservationKind.resolve(code: "capture_field", version: 1) == .captureField)
        #expect(try ObservationKind.resolve(code: "element", version: 1) == .element)
        #expect(throws: ObservationContractError.unknownObservationKind("snapshot")) {
            try ObservationKind.resolve(code: "snapshot", version: 1)
        }
        #expect(throws: ObservationContractError.unsupportedContractVersion(kind: "capture", version: 2)) {
            try ObservationKind.resolve(code: "capture", version: 2)
        }
        #expect(ObservationStatus(rawValue: "complete") == nil, "a sample's completeness is not a child row's status")
        #expect(CaptureQuality.Completeness(rawValue: "observed") == nil)
        #expect(CaptureField.allCases.count == 8)
        #expect(CaptureField.walkCompleted.valueKind == .boolean)
        #expect(CaptureField.stoppedBy.valueKind == .text)
        #expect(CaptureField.nodesVisited.valueKind == .integer)
    }

    @Test("completeness is derived from the facts: a missing window or grant fails, an unfinished walk is partial, a finished walk of a found window is complete, anything else is unknown")
    func completeness() {
        #expect(CaptureQuality.unknown.completeness == .unknown)
        // R2: a finished walk alone used to be complete here; the agreed scene rule needs the window found
        // (true), so a walk of a window nobody confirmed stays unknown.
        #expect(CaptureQuality(walkCompleted: true).completeness == .unknown)
        #expect(CaptureQuality(walkCompleted: true, windowFound: true).completeness == .complete)
        #expect(CaptureQuality(walkCompleted: false, stoppedBy: .deadline).completeness == .partial)
        #expect(CaptureQuality(walkCompleted: true, windowFound: false).completeness == .failed)
        #expect(CaptureQuality(walkCompleted: true, isGrantAvailable: false).completeness == .failed)
        #expect(CaptureQuality(windowFound: false, isGrantAvailable: true).completeness == .failed,
                "a missing window does not become a denied grant")
        #expect(EventCaptureStatus.summary(of: []) == .notApplicable)
        #expect(EventCaptureStatus.summary(of: [.complete, .complete]) == .complete)
        #expect(EventCaptureStatus.summary(of: [.complete, .partial]) == .partial)
        #expect(EventCaptureStatus.summary(of: [.unknown, .complete]) == .unknown)
        #expect(EventCaptureStatus.summary(of: [.partial, .failed]) == .failed)
    }

    @Test("the quality fields round-trip, a not-observed field stays nil, and a wrong storage class or stop reason is refused")
    func fields() throws {
        let quality = CaptureQuality(walkCompleted: false, stoppedBy: .tableLimit, windowFound: true, isGrantAvailable: nil,
                                     windowRole: "AXWindow", windowSubrole: nil, nodesVisited: 12, elementsEmitted: 3)
        let sample = CaptureSample(key: key, windowTitle: nil, sessionRevision: nil, surface: .window, quality: quality, elements: [])
        let back = try CaptureQuality(fields: Dictionary(uniqueKeysWithValues: sample.fields))
        #expect(back == quality)
        #expect(sample.fields.count == 8)
        #expect(throws: ObservationContractError.unknownStopReason("tired")) {
            try CaptureQuality(fields: [.stoppedBy: .text("tired")])
        }
        #expect(throws: ObservationContractError.malformedObservation(observationID: 0, malformation: .valueKindMismatch("walk_completed"))) {
            try CaptureQuality(fields: [.walkCompleted: .text("yes")])
        }
    }

    // MARK: Refusals on the way out

    /// An event, a well-formed sample under it, and the id of its capture row.
    private func stored() async throws -> (SQLiteMemoryStore, SQLiteCaptureRepository, Int64) {
        let store    = try await SQLiteMemoryStore.open(at: try temporaryDatabase())
        let captures = SQLiteCaptureRepository(store: store)
        _ = try await captures.record(SceneFixtures.event("ev"))
        let window = SceneFixtures.perceive(SceneFixtures.window("W", [SceneFixtures.button("OK", y: 300)]))
        _ = try await captures.record(SceneFixtures.sample("ev", of: window))
        let captureID = try await store.read { snapshot in
            try snapshot.query("SELECT observation_id FROM memory_event_observations WHERE observation_kind = 'capture'", []) {
                $0.integer(0) ?? 0
            }.first ?? 0
        }
        return (store, captures, captureID)
    }

    private func readError(_ captures: SQLiteCaptureRepository) async -> ObservationContractError? {
        do {
            _ = try await captures.sample(key)
            return nil
        } catch let error as ObservationContractError {
            return error
        } catch {
            Issue.record("another error: \(error)")
            return nil
        }
    }

    @Test("a child row of an unknown kind, or at a future version, makes the whole sample unreadable")
    func unknownKindOrVersion() async throws {
        let (store, captures, captureID) = try await stored()
        _ = try await store.write { transaction in
            try transaction.execute(
                """
                INSERT INTO memory_event_observations
                    (event_id, phase, sample_ordinal, observation_kind, status, parent_observation_id, text_value)
                VALUES ('ev', 'current', 0, 'measurement', 'observed', ?, 'x')
                """,
                [.integer(captureID)]
            )
        }
        #expect(await readError(captures) == .unknownObservationKind("measurement"))
        _ = try await store.write { transaction in
            try transaction.execute("DELETE FROM memory_event_observations WHERE observation_kind = 'measurement'")
            try transaction.execute(
                "UPDATE memory_event_observations SET observation_contract_version = 2 WHERE observation_id = ?",
                [.integer(captureID)]
            )
        }
        #expect(await readError(captures) == .unsupportedContractVersion(kind: "capture", version: 2))
        await store.close()
    }

    @Test("a quality field with an unknown name, a foreign status, a missing or mistyped value, or a duplicate is refused")
    func malformedFields() async throws {
        let (store, captures, captureID) = try await stored()
        func insert(_ columns: String, _ values: String) async throws {
            _ = try await store.write { transaction in
                try transaction.execute(
                    """
                    INSERT INTO memory_event_observations
                        (event_id, phase, sample_ordinal, observation_kind, parent_observation_id, \(columns))
                    VALUES ('ev', 'current', 0, 'capture_field', \(captureID), \(values))
                    """
                )
            }
        }
        // The capture row is followed by its eight fields and the one element row of the "OK" button, so a
        // row inserted here takes the rowid after the element.
        func undo() async throws {
            _ = try await store.write { transaction in
                try transaction.execute(
                    "DELETE FROM memory_event_observations WHERE observation_kind = 'capture_field' AND observation_id > ?",
                    [.integer(captureID + 9)]
                )
            }
        }
        try await insert("field_name, status, integer_value", "'frames_dropped', 'observed', 3")
        #expect(await readError(captures) == .unknownCaptureField("frames_dropped"))
        try await undo()

        try await insert("field_name, status, integer_value", "'nodes_visited', 'observed', 3")
        #expect(await readError(captures) == .malformedObservation(observationID: captureID + 10, malformation: .duplicateField("nodes_visited")))
        try await undo()

        _ = try await store.write { transaction in
            try transaction.execute(
                "DELETE FROM memory_event_observations WHERE field_name = 'nodes_visited' AND parent_observation_id = ?", [.integer(captureID)]
            )
        }
        #expect(await readError(captures) == .malformedObservation(observationID: captureID, malformation: .missingColumn("nodes_visited")))
        try await insert("field_name, status, text_value", "'nodes_visited', 'observed', 'many'")
        #expect(await readError(captures) == .malformedObservation(observationID: captureID + 10, malformation: .valueKindMismatch("nodes_visited")))
        try await undo()
        try await insert("field_name, status", "'nodes_visited', 'observed'")
        #expect(await readError(captures) == .malformedObservation(observationID: captureID + 10, malformation: .missingColumn("value")))
        try await undo()
        try await insert("field_name, status, integer_value", "'nodes_visited', 'not_observed', 3")
        #expect(await readError(captures) == .malformedObservation(observationID: captureID + 10, malformation: .forbiddenColumn("integer_value")))
        try await undo()
        try await insert("field_name, status, integer_value", "'nodes_visited', 'complete', 3")
        #expect(await readError(captures) == .unknownStatus(kind: .captureField, status: "complete"))
        try await undo()
        try await insert("field_name, status, integer_value, surface_kind", "'nodes_visited', 'observed', 3, 'window'")
        #expect(await readError(captures) == .malformedObservation(observationID: captureID + 10, malformation: .forbiddenColumn("surface_kind")))
        await store.close()
    }

    @Test("a sample whose status disagrees with its fields, lacks its surface, or carries element columns is refused")
    func malformedCapture() async throws {
        let (store, captures, captureID) = try await stored()
        _ = try await store.write { transaction in
            try transaction.execute("UPDATE memory_event_observations SET status = 'partial' WHERE observation_id = ?", [.integer(captureID)])
        }
        #expect(await readError(captures) == .malformedObservation(observationID: captureID, malformation: .statusContradictsFields))
        _ = try await store.write { transaction in
            try transaction.execute("UPDATE memory_event_observations SET status = 'complete', surface_kind = NULL WHERE observation_id = ?", [.integer(captureID)])
        }
        #expect(await readError(captures) == .malformedObservation(observationID: captureID, malformation: .missingColumn("surface_kind")))
        _ = try await store.write { transaction in
            try transaction.execute("UPDATE memory_event_observations SET surface_kind = 'window', role = 'AXButton' WHERE observation_id = ?", [.integer(captureID)])
        }
        #expect(await readError(captures) == .malformedObservation(observationID: captureID, malformation: .forbiddenColumn("role")))
        await store.close()
    }

    @Test("an element without role, label, kind, path or bounds, under another child, or in a split collection group is refused")
    func malformedElements() async throws {
        let (store, captures, captureID) = try await stored()
        let elementID = captureID + 9
        func set(_ assignment: String) async throws {
            _ = try await store.write { transaction in
                try transaction.execute(
                    "UPDATE memory_event_observations SET \(assignment) WHERE observation_id = ?", [.integer(elementID)]
                )
            }
        }
        try await set("role = NULL")
        #expect(await readError(captures) == .malformedObservation(observationID: elementID, malformation: .missingRole))
        try await set("role = 'AXButton', label = NULL")
        #expect(await readError(captures) == .malformedObservation(observationID: elementID, malformation: .missingColumn("label")))
        try await set("label = 'OK', element_kind = NULL")
        #expect(await readError(captures) == .malformedObservation(observationID: elementID, malformation: .missingColumn("element_kind")))
        try await set("element_kind = 'widget'")
        #expect(await readError(captures) == .unknownElementKind("widget"))
        try await set("element_kind = 'control', bounds_x = NULL")
        #expect(await readError(captures) == .malformedObservation(observationID: elementID, malformation: .missingColumn("bounds")))
        try await set("bounds_x = 0.5, status = 'not_observed'")
        #expect(await readError(captures) == .malformedObservation(observationID: elementID, malformation: .forbiddenColumn("status")))
        try await set("status = 'observed', phase = 'after'")
        #expect(await readError(captures) == nil, "a row under another phase is another sample's business until it names this parent")
        try await set("phase = 'current', parent_observation_id = \(captureID + 1)")
        #expect(await readError(captures) == .malformedObservation(observationID: elementID, malformation: .nestedUnderChild))
        try await set("parent_observation_id = \(captureID), observation_group = 1")
        _ = try await store.write { transaction in
            try transaction.execute(
                """
                INSERT INTO memory_event_observations
                    (event_id, phase, sample_ordinal, observation_kind, parent_observation_id, status, observation_group,
                     label, label_origin, container_path, role, element_kind, bounds_x, bounds_y, bounds_width, bounds_height)
                VALUES ('ev', 'current', 0, 'element', ?, 'observed', 1, 'Alice', 'row_content', 'Other', 'AXRow', 'control', 0, 0, 0.1, 0.1)
                """,
                [.integer(captureID)]
            )
        }
        #expect(await readError(captures) == .malformedObservation(observationID: elementID + 1, malformation: .collectionGroupInconsistent(1)))
        await store.close()
    }
}
