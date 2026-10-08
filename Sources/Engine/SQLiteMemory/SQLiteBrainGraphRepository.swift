//
//  SQLiteBrainGraphRepository.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 04/10/2026.
//

import Foundation
import Memory
import PerceptionCore

/// SQLiteBrainGraphRepository is `BrainGraphStoring` over `SQLiteMemoryStore`: typed readings of
/// `brain_scene_elements` and their links to anchors, the general arcs in `brain_transitions` and
/// `brain_transition_menu_items`, the evidence rows of `brain_evidence`, and an overview of the file.
///
/// It shares the tables with the compatible projection (`SQLiteBrainRepository`): the projection
/// owns the transitions from the application's scope triggered by an anchor (no scene element, no
/// menu command), every other transition is a general arc. Neither writer touches the other's rows,
/// and both take the application's next `insertion_order` under the write lock. Nothing is learned
/// here: every arc, link and evidence is given by its caller.
public struct SQLiteBrainGraphRepository: BrainGraphStoring {

    private let store: SQLiteMemoryStore

    public init(store: SQLiteMemoryStore) {
        self.store = store
    }

    public func elements(ofScene sceneID: String) async throws -> [SceneElementRecord] {
        try await store.read { snapshot in try SQLiteGraphRows.elements(snapshot, sceneID: sceneID) }
    }

    public func link(element sceneElementID: String, toAnchor anchorID: String) async throws -> MemoryReceipt {
        try await store.write { transaction in
            guard let row = try transaction.query(
                "SELECT app_id, anchor_id FROM brain_scene_elements WHERE scene_element_id = ?", [.text(sceneElementID)],
                { (app: $0.integer(0) ?? 0, anchor: try $0.text(1)) }
            ).first else { throw EventFactError.missingDefinition(id: sceneElementID) }
            guard try transaction.query("SELECT count(*) FROM brain_anchors WHERE anchor_id = ? AND app_id = ?", [.text(anchorID), .integer(row.app)],
                                        { $0.integer(0) ?? 0 }).first ?? 0 > 0 else { throw EventFactError.missingDefinition(id: anchorID) }
            if let current = row.anchor {
                guard current.utf8.elementsEqual(anchorID.utf8) else { throw SQLiteFactRows.conflict(sceneElementID, stored: current, offered: anchorID) }
                return .alreadyApplied
            }
            try transaction.execute("UPDATE brain_scene_elements SET anchor_id = ? WHERE scene_element_id = ?", [.text(anchorID), .text(sceneElementID)])
            return .committed
        }
    }

    public func record(_ arc: BrainArc) async throws -> MemoryReceipt {
        try await store.write { transaction in
            if let stored = try SQLiteGraphRows.arc(transaction, id: arc.transitionID) {
                guard stored.isExactly(arc) else { throw SQLiteFactRows.conflict(arc.transitionID, stored: "\(stored)", offered: "\(arc)") }
                return .alreadyApplied
            }
            let appID = try SQLiteGraphRows.checkArc(transaction, arc)
            let order = (try transaction.query("SELECT max(insertion_order) FROM brain_transitions WHERE app_id = ?", [.integer(appID)]) { $0.integer(0) }.first ?? nil)
                .map { $0 + 1 } ?? 0
            var anchor: SQLiteValue = .null, element: SQLiteValue = .null, menu: SQLiteValue = .null
            let code: String
            switch arc.trigger {
                case .anchor(let id, let gesture) : anchor = .text(id); code = gesture.rawValue
                case .element(let id, let gesture): element = .text(id); code = gesture.rawValue
                case .menu(let id)                : menu = .text(id); code = ArcTrigger.menuCode
            }
            try transaction.execute(
                """
                INSERT INTO brain_transitions (transition_id, app_id, insertion_order, from_scene_id, anchor_id, scene_element_id, menu_command_id,
                    trigger_kind, to_scene_id, effect_kind, effect_text, required_target_state, resulting_target_state, last_observed_epoch,
                    status, first_seen_ms, last_seen_ms, evidence_count)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [.text(arc.transitionID), .integer(appID), .integer(order), .text(arc.fromSceneID), anchor, element, menu, .text(code),
                 arc.toSceneID.map(SQLiteValue.text) ?? .null, .text(arc.effect.kind), arc.effect.text.map(SQLiteValue.text) ?? .null,
                 arc.effect.requiredState.map { .text($0.rawValue) } ?? .null, arc.effect.resultingState.map { .text($0.rawValue) } ?? .null,
                 arc.lastObservedEpoch.map(SQLiteValue.integer) ?? .null, .text(arc.status.rawValue), .integer(arc.firstSeenMS),
                 .integer(arc.lastSeenMS), .integer(arc.evidenceCount)]
            )
            for (position, title) in arc.effect.items.enumerated() {
                try transaction.execute("INSERT INTO brain_transition_menu_items (transition_id, position, title) VALUES (?, ?, ?)",
                                        [.text(arc.transitionID), .integer(Int64(position)), .text(title)])
            }
            return .committed
        }
    }

    public func update(from expected: BrainArc, to updated: BrainArc) async throws -> MemoryReceipt {
        guard expected.sameIdentity(as: updated) else { throw EventFactError.immutableField(id: expected.transitionID, field: "arc identity") }
        guard updated.lastSeenMS >= expected.lastSeenMS else { throw EventFactError.immutableField(id: expected.transitionID, field: "last_seen_ms") }
        return try await store.write { transaction in
            guard let stored = try SQLiteGraphRows.arc(transaction, id: expected.transitionID) else {
                throw EventFactError.missingDefinition(id: expected.transitionID)
            }
            if stored.isExactly(updated) { return .alreadyApplied }
            guard stored.isExactly(expected) else { throw EventFactError.staleExpectation(id: expected.transitionID) }
            try transaction.execute(
                "UPDATE brain_transitions SET status = ?, evidence_count = ?, last_seen_ms = ?, last_observed_epoch = ? WHERE transition_id = ?",
                [.text(updated.status.rawValue), .integer(updated.evidenceCount), .integer(updated.lastSeenMS),
                 updated.lastObservedEpoch.map(SQLiteValue.integer) ?? .null, .text(updated.transitionID)]
            )
            return .committed
        }
    }

    public func arc(_ transitionID: String) async throws -> BrainArc? {
        try await store.read { snapshot in try SQLiteGraphRows.arc(snapshot, id: transitionID) }
    }

    public func arcs(of bundleID: String) async throws -> [BrainArc] {
        try await store.read { snapshot in
            guard let appID = try SQLiteIdentityRows.appID(snapshot, bundleID: bundleID) else { return [] }
            let ids = try snapshot.query(
                "SELECT t.transition_id FROM brain_transitions t WHERE t.app_id = ? AND t.retired_at_ms IS NULL AND NOT \(SQLiteGraphRows.projectionOwned) ORDER BY t.insertion_order",
                [.integer(appID)]
            ) { try $0.text(0) ?? "" }
            return try ids.compactMap { try SQLiteGraphRows.arc(snapshot, id: $0) }
        }
    }

    public func record(_ evidence: BrainEvidenceRecord) async throws -> MemoryReceipt {
        try await store.write { transaction in
            let (column, appID) = try SQLiteGraphRows.checkEvidence(transaction, evidence)
            if let stored = try SQLiteGraphRows.evidence(transaction, ofEvent: evidence.eventID).first(where: {
                $0.relation == evidence.relation && SQLiteGraphRows.column(of: $0.target) == column && SQLiteGraphRows.id(of: $0.target).utf8.elementsEqual(SQLiteGraphRows.id(of: evidence.target).utf8)
            }) {
                guard stored.isExactly(evidence) else { throw SQLiteFactRows.conflict("\(column):\(evidence.eventID)", stored: "\(stored)", offered: "\(evidence)") }
                return .alreadyApplied
            }
            try transaction.execute(
                "INSERT INTO brain_evidence (app_id, event_id, relation, assessed_by, assessment_version, assessed_at_ms, \(column)) VALUES (?, ?, ?, ?, ?, ?, ?)",
                [.integer(appID), .text(evidence.eventID), .text(evidence.relation.rawValue), .text(evidence.assessedBy),
                 .text(evidence.assessmentVersion), .integer(evidence.assessedAtMS), .text(SQLiteGraphRows.id(of: evidence.target))]
            )
            return .committed
        }
    }

    public func evidence(ofEvent eventID: String) async throws -> [BrainEvidenceRecord] {
        try await store.read { snapshot in try SQLiteGraphRows.evidence(snapshot, ofEvent: eventID) }
    }

    public func overview() async throws -> MemoryOverview {
        try await store.read { snapshot in try SQLiteGraphRows.overview(snapshot) }
    }
}

/// SQLiteGraphRows is the codec of the graph's rows and the checks they need the file for.
enum SQLiteGraphRows {

    /// The transitions the compatible projection owns, over `brain_transitions t`.
    static let projectionOwned = """
        (t.scene_element_id IS NULL AND t.menu_command_id IS NULL
         AND t.from_scene_id IN (SELECT scene_id FROM brain_scenes WHERE app_id = t.app_id AND scene_kind = 'app'))
        """

    private static func count(_ handle: some SQLiteQuerying, _ sql: String, _ bindings: [SQLiteValue]) throws -> Int64 {
        try handle.query(sql, bindings) { $0.integer(0) ?? 0 }.first ?? 0
    }

    // MARK: Elements

    static func elements(_ handle: some SQLiteQuerying, sceneID: String) throws -> [SceneElementRecord] {
        try handle.query(
            """
            SELECT scene_element_id, element_key, element_scope, parent_element_id, edge_hash, cursor_affordance, anchor_id, label, label_origin,
                   role, kind, source, bounds_x, bounds_y, bounds_width, bounds_height, first_seen_ms, last_seen_ms, observation_count
            FROM brain_scene_elements WHERE scene_id = ? ORDER BY scene_element_id
            """,
            [.text(sceneID)]
        ) { row in
            let id = try row.text(0) ?? ""
            func refuse(_ malformation: EventFactError.Malformation) -> EventFactError {
                .malformedRow(table: "brain_scene_elements", id: id, malformation: malformation)
            }
            let scopeCode = try row.text(2) ?? ""
            guard let scope = SQLiteRouteRows.code(SceneElementScope.self, scopeCode) else { throw refuse(.unknownCode(column: "element_scope", code: scopeCode)) }
            var origin: LabelOrigin?
            if let raw = try row.text(8) {
                guard let known = SQLiteRouteRows.code(LabelOrigin.self, raw) else { throw refuse(.unknownCode(column: "label_origin", code: raw)) }
                origin = known
            }
            let corners = [row.real(12), row.real(13), row.real(14), row.real(15)]
            var bounds: NormalizedRect?
            if corners.allSatisfy({ $0 != nil }) {
                let values = corners.compactMap { $0 }
                guard values.allSatisfy(\.isFinite) else { throw refuse(.invalid(.notFinite)) }
                bounds = NormalizedRect(x: values[0], y: values[1], width: values[2], height: values[3])
            } else if corners.contains(where: { $0 != nil }) {
                throw refuse(.invalid(.shape(field: "bounds")))
            }
            let first = row.integer(16) ?? 0, last = row.integer(17) ?? 0
            guard BrainClock.range.contains(first), BrainClock.range.contains(last) else { throw refuse(.invalid(.outOfRange(field: "ms"))) }
            return SceneElementRecord(sceneElementID: id, sceneID: sceneID, elementKey: try row.text(1) ?? "", scope: scope, parentElementID: try row.text(3),
                                      edgeHash: try row.text(4), cursorAffordance: try row.text(5), anchorID: try row.text(6), label: try row.text(7),
                                      labelOrigin: origin, role: try row.text(9), kind: try row.text(10), source: try row.text(11), bounds: bounds,
                                      firstSeenMS: first, lastSeenMS: last, observationCount: row.integer(18) ?? 0)
        }
    }

    // MARK: Arcs

    /// Checks an arc against the file and answers its application: the source scene is the
    /// application's; an anchor trigger needs a structural source (from the scope it is the
    /// projection's), an anchor of the application; an element trigger an element of the source; a
    /// menu trigger a command of the application; a destination a structural scene of it.
    static func checkArc(_ transaction: SQLiteTransaction, _ arc: BrainArc) throws -> Int64 {
        guard let appID = try SQLiteIdentityRows.appID(transaction, bundleID: arc.bundleID) else { throw EventFactError.missingDefinition(id: arc.bundleID) }
        guard let kind = try transaction.query("SELECT scene_kind FROM brain_scenes WHERE scene_id = ? AND app_id = ?",
                                                [.text(arc.fromSceneID), .integer(appID)], { try $0.text(0) ?? "" }).first else {
            throw EventFactError.missingDefinition(id: arc.fromSceneID)
        }
        func exists(_ sql: String, _ bindings: [SQLiteValue], _ id: String) throws {
            guard try count(transaction, sql, bindings) > 0 else { throw EventFactError.missingDefinition(id: id) }
        }
        switch arc.trigger {
            case .anchor(let id, _):
                guard kind != "app" else { throw EventFactError.invalidRecord(.shape(field: "an anchor arc from the scope is the projection's")) }
                try exists("SELECT count(*) FROM brain_anchors WHERE anchor_id = ? AND app_id = ?", [.text(id), .integer(appID)], id)
            case .element(let id, _):
                try exists("SELECT count(*) FROM brain_scene_elements WHERE scene_element_id = ? AND scene_id = ? AND app_id = ?",
                           [.text(id), .text(arc.fromSceneID), .integer(appID)], id)
            case .menu(let id):
                try exists("SELECT count(*) FROM brain_menu_commands WHERE menu_command_id = ? AND app_id = ?", [.text(id), .integer(appID)], id)
        }
        if let destination = arc.toSceneID {
            try exists("SELECT count(*) FROM brain_scenes WHERE scene_id = ? AND app_id = ? AND scene_kind <> 'app'", [.text(destination), .integer(appID)], destination)
        }
        return appID
    }

    /// A general arc, or nil when no transition has the id or when it is the projection's.
    static func arc(_ handle: some SQLiteQuerying, id: String) throws -> BrainArc? {
        guard let row = try handle.query(
            """
            SELECT a.bundle_id, t.from_scene_id, t.anchor_id, t.scene_element_id, t.menu_command_id, t.trigger_kind, t.to_scene_id, t.effect_kind,
                   t.effect_text, t.required_target_state, t.resulting_target_state, t.last_observed_epoch, t.status, t.first_seen_ms, t.last_seen_ms,
                   t.evidence_count, \(projectionOwned)
            FROM brain_transitions t JOIN brain_apps a ON a.app_id = t.app_id WHERE t.transition_id = ?
            """,
            [.text(id)],
            { row in
                (bundle: try row.text(0) ?? "", from: try row.text(1) ?? "", anchor: try row.text(2), element: try row.text(3), menu: try row.text(4),
                 trigger: try row.text(5) ?? "", to: try row.text(6), kind: try row.text(7) ?? "", text: try row.text(8), required: try row.text(9),
                 resulting: try row.text(10), epoch: row.integer(11), status: try row.text(12) ?? "", first: row.integer(13) ?? 0, last: row.integer(14) ?? 0,
                 evidence: row.integer(15) ?? 0, owned: row.integer(16) == 1)
            }
        ).first else { return nil }
        if row.owned { return nil }
        func refuse(_ malformation: EventFactError.Malformation) -> EventFactError { .malformedRow(table: "brain_transitions", id: id, malformation: malformation) }
        func gesture() throws -> TransitionTrigger {
            guard let known = SQLiteRouteRows.code(TransitionTrigger.self, row.trigger) else { throw refuse(.unknownCode(column: "trigger_kind", code: row.trigger)) }
            return known
        }
        let trigger: ArcTrigger
        switch (row.anchor, row.element, row.menu) {
            case (let anchor?, nil, nil): trigger = .anchor(anchorID: anchor, gesture: try gesture())
            case (nil, let element?, nil): trigger = .element(sceneElementID: element, gesture: try gesture())
            case (nil, nil, let menu?):
                guard row.trigger == ArcTrigger.menuCode else { throw refuse(.unknownCode(column: "trigger_kind", code: row.trigger)) }
                trigger = .menu(menuCommandID: menu)
            default: throw refuse(.invalid(.shape(field: "trigger")))
        }
        guard let status = SQLiteRouteRows.code(ArcStatus.self, row.status) else { throw refuse(.unknownCode(column: "status", code: row.status)) }
        let items = try handle.query("SELECT position, title FROM brain_transition_menu_items WHERE transition_id = ? ORDER BY position", [.text(id)]) {
            (position: $0.integer(0) ?? -1, title: try $0.text(1) ?? "")
        }
        guard items.enumerated().allSatisfy({ Int64($0.offset) == $0.element.position }) else { throw refuse(.invalid(.shape(field: "items"))) }
        let effect: TransitionEffectRecord
        do {
            effect = try TransitionEffectRecord(kind: row.kind, text: row.text, requiredState: row.required, resultingState: row.resulting, items: items.map(\.title))
        } catch {
            throw refuse(.unknownCode(column: "effect", code: "\(error)"))
        }
        do {
            return try BrainArc(transitionID: id, bundleID: row.bundle, fromSceneID: row.from, trigger: trigger, toSceneID: row.to, effect: effect,
                                status: status, evidenceCount: row.evidence, firstSeenMS: row.first, lastSeenMS: row.last, lastObservedEpoch: row.epoch)
        } catch EventFactError.invalidRecord(let invalidity) {
            throw refuse(.invalid(invalidity))
        }
    }

    // MARK: Evidence

    static func column(of target: BrainEvidenceTarget) -> String {
        switch target {
            case .scene: "scene_id"
            case .anchor: "anchor_id"
            case .sceneElement: "scene_element_id"
            case .group: "group_id"
            case .menuCommand: "menu_command_id"
            case .transition: "transition_id"
        }
    }

    static func id(of target: BrainEvidenceTarget) -> String {
        switch target {
            case .scene(let id), .anchor(let id), .sceneElement(let id), .group(let id), .menuCommand(let id), .transition(let id): id
        }
    }

    /// Checks evidence against the file and answers its column and application: the target exists in
    /// the bundle's application and is not its scope; the event is of the same application; a
    /// structural source (a scene, an element's scene, an arc's source scene) is one the event has a
    /// confirmed association with. The writer checks it before a row is written, the reader on every
    /// row it gives back. Evidence on the projection's anchors, groups and transitions from the
    /// scope, as the applications register writes it, has no structural source to confirm.
    static func checkEvidence(_ transaction: some SQLiteQuerying, _ evidence: BrainEvidenceRecord) throws -> (String, Int64) {
        guard let appID = try SQLiteIdentityRows.appID(transaction, bundleID: evidence.bundleID) else { throw EventFactError.missingDefinition(id: evidence.bundleID) }
        let id = id(of: evidence.target)
        let table: String, key: String
        switch evidence.target {
            case .scene: (table, key) = ("brain_scenes", "scene_id")
            case .anchor: (table, key) = ("brain_anchors", "anchor_id")
            case .sceneElement: (table, key) = ("brain_scene_elements", "scene_element_id")
            case .group: (table, key) = ("brain_groups", "group_id")
            case .menuCommand: (table, key) = ("brain_menu_commands", "menu_command_id")
            case .transition: (table, key) = ("brain_transitions", "transition_id")
        }
        guard try count(transaction, "SELECT count(*) FROM \(table) WHERE \(key) = ? AND app_id = ?", [.text(id), .integer(appID)]) > 0 else {
            throw EventFactError.missingDefinition(id: id)
        }
        guard let eventApp = try SQLiteEventRows.appID(transaction, eventID: evidence.eventID) else { throw EventFactError.missingEvent(eventID: evidence.eventID) }
        guard eventApp == appID else { throw EventFactError.invalidRecord(.appContradiction) }
        var source: String?
        switch evidence.target {
            case .scene:
                guard try count(transaction, "SELECT count(*) FROM brain_scenes WHERE scene_id = ? AND scene_kind = 'app'", [.text(id)]) == 0 else {
                    throw EventFactError.invalidRecord(.shape(field: "the application's scope is never evidence"))
                }
                source = id
            case .sceneElement:
                source = try transaction.query("SELECT scene_id FROM brain_scene_elements WHERE scene_element_id = ?", [.text(id)]) { try $0.text(0) }.first ?? nil
            case .transition:
                source = try transaction.query(
                    "SELECT s.scene_id FROM brain_transitions t JOIN brain_scenes s ON s.scene_id = t.from_scene_id WHERE t.transition_id = ? AND s.scene_kind <> 'app'",
                    [.text(id)]) { try $0.text(0) }.first ?? nil
            default:
                break
        }
        if let source {
            guard try count(transaction, "SELECT count(*) FROM memory_event_scenes WHERE event_id = ? AND scene_id = ? AND match_status = 'confirmed'",
                            [.text(evidence.eventID), .text(source)]) > 0 else {
                throw EventFactError.invalidRecord(.shape(field: "unconfirmed structural source"))
            }
        }
        return (column(of: evidence.target), appID)
    }

    static func evidence(_ handle: some SQLiteQuerying, ofEvent eventID: String) throws -> [BrainEvidenceRecord] {
        try handle.query(
            """
            SELECT e.evidence_id, a.bundle_id, e.relation, e.assessed_by, e.assessment_version, e.assessed_at_ms, e.scene_id, e.anchor_id,
                   e.scene_element_id, e.group_id, e.menu_command_id, e.transition_id
            FROM brain_evidence e JOIN brain_apps a ON a.app_id = e.app_id WHERE e.event_id = ? ORDER BY e.evidence_id
            """,
            [.text(eventID)]
        ) { row in
            let id = "\(row.integer(0) ?? 0)"
            func refuse(_ malformation: EventFactError.Malformation) -> EventFactError { .malformedRow(table: "brain_evidence", id: id, malformation: malformation) }
            let targets: [BrainEvidenceTarget] = [try row.text(6).map(BrainEvidenceTarget.scene), try row.text(7).map(BrainEvidenceTarget.anchor),
                                                  try row.text(8).map(BrainEvidenceTarget.sceneElement), try row.text(9).map(BrainEvidenceTarget.group),
                                                  try row.text(10).map(BrainEvidenceTarget.menuCommand), try row.text(11).map(BrainEvidenceTarget.transition)].compactMap { $0 }
            guard targets.count == 1 else { throw refuse(.invalid(.shape(field: "target"))) }
            let relationCode = try row.text(2) ?? ""
            guard let relation = SQLiteRouteRows.code(EvidenceRelation.self, relationCode) else { throw refuse(.unknownCode(column: "relation", code: relationCode)) }
            do {
                let record = try BrainEvidenceRecord(bundleID: try row.text(1) ?? "", eventID: eventID, target: targets[0], relation: relation,
                                                     assessedBy: try row.text(3) ?? "", assessmentVersion: try row.text(4) ?? "", assessedAtMS: row.integer(5) ?? 0)
                _ = try checkEvidence(handle, record)
                return record
            } catch EventFactError.invalidRecord(let invalidity) {
                throw refuse(.invalid(invalidity))
            } catch EventFactError.missingDefinition {
                throw refuse(.invalid(.shape(field: "target")))
            } catch EventFactError.missingEvent {
                throw refuse(.invalid(.shape(field: "event")))
            }
        }
    }

    // MARK: Overview

    static func overview(_ handle: some SQLiteQuerying) throws -> MemoryOverview {
        let apps = try handle.query("SELECT app_id, bundle_id FROM brain_apps", []) { (id: $0.integer(0) ?? 0, bundle: try $0.text(1) ?? "") }
            .sorted { Array($0.bundle.utf8).lexicographicallyPrecedes(Array($1.bundle.utf8)) }
        func n(_ sql: String, _ app: Int64) throws -> Int { Int(try count(handle, sql, [.integer(app)])) }
        // brain_evidence has no index led by app_id: one grouped pass for every application, where a
        // count per application would read the whole table once for each.
        let evidence = Dictionary(uniqueKeysWithValues: try handle.query(
            "SELECT app_id, count(*) FROM brain_evidence GROUP BY app_id", []
        ) { (app: $0.integer(0) ?? 0, count: Int($0.integer(1) ?? 0)) }.map { ($0.app, $0.count) })
        let summaries = try apps.map { app in
            MemoryOverview.App(
                bundleID: app.bundle,
                contexts: try n("SELECT count(*) FROM brain_app_contexts WHERE app_id = ?", app.id),
                projectionAnchors: try n("SELECT count(*) FROM brain_anchors WHERE app_id = ? AND retired_at_ms IS NULL", app.id),
                projectionGroups: try n("SELECT count(*) FROM brain_groups WHERE app_id = ? AND retired_at_ms IS NULL", app.id),
                projectionTransitions: try n("SELECT count(*) FROM brain_transitions t WHERE t.app_id = ? AND t.retired_at_ms IS NULL AND \(projectionOwned)", app.id),
                structuralScenes: try n("SELECT count(*) FROM brain_scenes WHERE app_id = ? AND scene_kind <> 'app'", app.id),
                sceneElements: try n("SELECT count(*) FROM brain_scene_elements WHERE app_id = ?", app.id),
                generalArcs: try n("SELECT count(*) FROM brain_transitions t WHERE t.app_id = ? AND t.retired_at_ms IS NULL AND NOT \(projectionOwned)", app.id),
                menuCommands: try n("SELECT count(*) FROM brain_menu_commands WHERE app_id = ?", app.id),
                brainEvidence: evidence[app.id] ?? 0,
                events: try n("SELECT count(*) FROM memory_events WHERE app_id = ?", app.id),
                samples: try n("SELECT count(*) FROM memory_event_observations o JOIN memory_events e ON e.event_id = o.event_id WHERE e.app_id = ? AND o.observation_kind = 'capture'", app.id)
            )
        }
        var routes: [RouteStatus: Int] = [:]
        for status in RouteStatus.allCases {
            routes[status] = Int(try count(handle, "SELECT count(*) FROM memory_routes WHERE status = ?", [.text(status.rawValue)]))
        }
        return MemoryOverview(apps: summaries, routes: routes,
                              experiences: Int(try count(handle, "SELECT count(*) FROM memory_experiences", [])),
                              taskOccurrences: Int(try count(handle, "SELECT count(*) FROM memory_task_occurrences", [])),
                              stepOccurrences: Int(try count(handle, "SELECT count(*) FROM memory_step_occurrences", [])),
                              eventsWithoutApp: Int(try count(handle, "SELECT count(*) FROM memory_events WHERE app_id IS NULL", [])))
    }
}
