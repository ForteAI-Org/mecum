//
//  SQLiteSceneRepository.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

import EngineCore
import Foundation
import Memory
import PerceptionCore

/// SQLiteSceneRepository is `SceneStoring` over `SQLiteMemoryStore`: structural scenes in
/// `brain_scenes` with their roles, labels and elements, associations in `memory_event_scenes`.
/// `associate` reads the stored sample, rebuilds its skeleton, reads the scenes of the sample's
/// application, runs `SceneStructureMatcher` and writes the decision, all inside one write
/// transaction: evaluation and insertion are serialized with every other writer of the file, so two
/// complete captures of one skeleton arriving together produce one scene, without any unique key on
/// the structural digest. The app scope (`scene_kind = 'app'`) is never read as a candidate.
///
/// A sample already decided is not decided again: the stored rows are answered as
/// `alreadyApplied`. A confirmed association counts one observation of its scene; a candidate
/// counts nothing and changes no scene. A new scene is written from the sample's own elements, with
/// the labels of its captions and nothing of its content: a label whose origin is a value is kept
/// as its origin only.
public struct SQLiteSceneRepository: SceneStoring {

    private let store: SQLiteMemoryStore
    private let makeSceneID: @Sendable () -> String

    /// Creates the repository. `makeSceneID` names a scene this repository creates; the default is
    /// a UUID, and a test supplies a deterministic one.
    public init(store: SQLiteMemoryStore, makeSceneID: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.store       = store
        self.makeSceneID = makeSceneID
    }

    public func scenes(of bundleID: String) async throws -> [SceneDefinition] {
        try await store.read { snapshot in
            guard let appID = try SQLiteIdentityRows.appID(snapshot, bundleID: bundleID) else { return [] }
            return try SQLiteSceneRows.scenes(snapshot, appID: appID, bundleID: bundleID)
        }
    }

    public func associate(_ key: CaptureSampleKey, at nowMS: Int64) async throws -> SceneAssociationOutcome {
        let makeSceneID = self.makeSceneID
        return try await store.write { transaction in
            guard let sample = try SQLiteObservationRows.sample(transaction, key: key) else {
                throw ObservationContractError.missingSample(key)
            }
            guard let appRow = try SQLiteEventRows.appID(transaction, eventID: key.eventID) else {
                throw ObservationContractError.missingEvent(eventID: key.eventID)
            }
            guard let appID = appRow else { throw ObservationContractError.eventWithoutApp(eventID: key.eventID) }
            let existing = try SQLiteSceneRows.associations(transaction, key: key)
            if !existing.isEmpty {
                let decision: SceneStructureMatcher.Decision
                if let confirmed = existing.first(where: { $0.status == .confirmed }) {
                    decision = .confirmed(sceneID: confirmed.sceneID)
                } else {
                    decision = .candidates(existing.map(\.sceneID))
                }
                return SceneAssociationOutcome(
                    receipt: .alreadyApplied, decision: decision, associations: existing, createdSceneID: nil
                )
            }
            let bundleID = try transaction.query(
                "SELECT bundle_id FROM brain_apps WHERE app_id = ?", [.integer(appID)]
            ) { try $0.text(0) ?? "" }.first ?? ""
            let known    = try SQLiteSceneRows.scenes(transaction, appID: appID, bundleID: bundleID)
            let observed = SceneSkeleton(sample: sample)
            let decision = SceneStructureMatcher.decide(
                observed  : observed,
                isComplete: sample.quality.isComplete,
                phase     : key.phase,
                among     : known.map { ($0.id, $0.skeleton) }
            )
            var created: String?
            switch decision {
                case .confirmed(let sceneID):
                    try SQLiteSceneRows.insertAssociation(transaction, key: key, appID: appID, sceneID: sceneID, status: .confirmed)
                    try SQLiteSceneRows.countObservation(transaction, sceneID: sceneID, nowMS: nowMS)
                case .candidates(let sceneIDs):
                    for sceneID in sceneIDs {
                        try SQLiteSceneRows.insertAssociation(transaction, key: key, appID: appID, sceneID: sceneID, status: .candidate)
                    }
                case .newScene:
                    let sceneID = makeSceneID()
                    try SQLiteSceneRows.insertScene(
                        transaction, sceneID: sceneID, appID: appID, sample: sample, skeleton: observed, nowMS: nowMS
                    )
                    try SQLiteSceneRows.insertAssociation(transaction, key: key, appID: appID, sceneID: sceneID, status: .confirmed)
                    created = sceneID
                case .none:
                    break
            }
            return SceneAssociationOutcome(
                receipt       : .committed,
                decision      : decision,
                associations  : try SQLiteSceneRows.associations(transaction, key: key),
                createdSceneID: created
            )
        }
    }

    public func associations(of key: CaptureSampleKey) async throws -> [SceneAssociation] {
        try await store.read { snapshot in try SQLiteSceneRows.associations(snapshot, key: key) }
    }
}

/// SQLiteSceneRows reads and writes the structural rows of a scene and the association rows of a
/// sample. The element keys are canonical and say what a row is:
/// `container|<path>`, `control|<path>|<role>|<normalized caption or nothing>`,
/// `collection|<path>`, `item_template|<path>`; the structural path of a control is its parent
/// container's, and the root has no container. A skeleton is rebuilt from these rows alone.
enum SQLiteSceneRows {

    private static let separator = " / "

    // MARK: Reading

    static func scenes(_ handle: some SQLiteQuerying, appID: Int64, bundleID: String) throws -> [SceneDefinition] {
        let heads = try handle.query(
            """
            SELECT scene_id, scene_kind, title_bucket, structural_key, first_seen_ms, last_seen_ms, observation_count
            FROM brain_scenes WHERE app_id = ? AND scene_kind <> 'app'
            ORDER BY first_seen_ms, scene_id
            """,
            [.integer(appID)]
        ) { row in
            (
                id      : try row.text(0) ?? "",
                kind    : try row.text(1) ?? "",
                bucket  : try row.text(2) ?? "",
                key     : try row.text(3),
                first   : row.integer(4) ?? 0,
                last    : row.integer(5) ?? 0,
                count   : Int(row.integer(6) ?? 0)
            )
        }
        return try heads.map { head in
            guard let surface = CaptureSurface(rawValue: head.kind), surface != .popupUnion, surface != .unknown else {
                throw ObservationContractError.unknownSceneKind(head.kind)
            }
            return SceneDefinition(
                id              : head.id,
                bundleID        : bundleID,
                surface         : surface,
                titleBucket     : head.bucket,
                structuralKey   : head.key,
                firstSeenMS     : head.first,
                lastSeenMS      : head.last,
                observationCount: head.count,
                skeleton        : try skeleton(handle, sceneID: head.id, surface: surface)
            )
        }
    }

    /// The skeleton of a stored scene, from its elements: controls add their role, and their
    /// caption when the role carries captions and the origin is a title or a description, at their
    /// container's path; collections add their path; containers and item templates carry no
    /// identity of their own. A control kept with its origin and no label is one whose label was
    /// content, not a caption.
    static func skeleton(_ handle: some SQLiteQuerying, sceneID: String, surface: CaptureSurface) throws -> SceneSkeleton {
        let rows = try handle.query(
            """
            SELECT scene_element_id, parent_element_id, element_key, element_scope, role, label, label_origin
            FROM brain_scene_elements WHERE scene_id = ? ORDER BY scene_element_id
            """,
            [.text(sceneID)]
        ) { row in
            (
                id    : try row.text(0) ?? "",
                parent: try row.text(1),
                key   : try row.text(2) ?? "",
                scope : try row.text(3) ?? "",
                role  : try row.text(4),
                label : try row.text(5),
                origin: try row.text(6)
            )
        }
        var containerPaths: [String: String] = [:]
        for row in rows where row.scope == "container" {
            guard row.key.hasPrefix("container|") else {
                throw ObservationContractError.malformedSceneElement(sceneElementID: row.id, malformation: .missingColumn("element_key"))
            }
            containerPaths[row.id] = String(row.key.dropFirst("container|".count))
        }
        func path(of parent: String?, for id: String) throws -> String {
            guard let parent else { return "" }
            guard let path = containerPaths[parent] else {
                throw ObservationContractError.malformedSceneElement(sceneElementID: id, malformation: .nestedUnderChild)
            }
            return path
        }
        var roles: [String: Set<String>] = [:]
        var captions: [String: Set<SceneSkeleton.Caption>] = [:]
        var collections: Set<String> = []
        for row in rows {
            switch row.scope {
                case "container", "item_template":
                    continue
                case "collection":
                    guard row.key.hasPrefix("collection|") else {
                        throw ObservationContractError.malformedSceneElement(sceneElementID: row.id, malformation: .missingColumn("element_key"))
                    }
                    collections.insert(String(row.key.dropFirst("collection|".count)))
                case "control":
                    guard let role = row.role, !role.isEmpty else {
                        throw ObservationContractError.malformedSceneElement(sceneElementID: row.id, malformation: .missingRole)
                    }
                    let at = try path(of: row.parent, for: row.id)
                    roles[at, default: []].insert(role)
                    if let code = row.origin {
                        guard let origin = LabelOrigin(rawValue: code) else { throw ObservationContractError.unknownLabelOrigin(code) }
                        if SceneSkeleton.captionRoles.contains(role), SceneSkeleton.captionOrigins.contains(origin) {
                            guard let label = row.label else {
                                throw ObservationContractError.malformedSceneElement(sceneElementID: row.id, malformation: .missingColumn("label"))
                            }
                            captions[at, default: []].insert(SceneSkeleton.Caption(role: role, label: label))
                        }
                    }
                default:
                    throw ObservationContractError.malformedSceneElement(sceneElementID: row.id, malformation: .forbiddenColumn("element_scope"))
            }
        }
        return SceneSkeleton(surface: surface, rolesByPath: roles, captionsByPath: captions, collections: collections)
    }

    static func associations(_ handle: some SQLiteQuerying, key: CaptureSampleKey) throws -> [SceneAssociation] {
        try handle.query(
            """
            SELECT scene_id, match_status, matched_by, matcher_version FROM memory_event_scenes
            WHERE event_id = ? AND phase = ? AND sample_ordinal = ? ORDER BY scene_id
            """,
            [.text(key.eventID), .text(key.phase.rawValue), .integer(Int64(key.ordinal))]
        ) { row in
            let statusCode = try row.text(1) ?? ""
            guard let status = SceneMatchStatus(rawValue: statusCode) else {
                throw ObservationContractError.unknownMatchStatus(statusCode)
            }
            return SceneAssociation(
                sample        : key,
                sceneID       : try row.text(0) ?? "",
                status        : status,
                matchedBy     : try row.text(2) ?? "",
                matcherVersion: try row.text(3) ?? ""
            )
        }
    }

    // MARK: Writing

    static func insertAssociation(
        _ transaction: SQLiteTransaction,
        key          : CaptureSampleKey,
        appID        : Int64,
        sceneID      : String,
        status       : SceneMatchStatus
    ) throws {
        try transaction.execute(
            """
            INSERT INTO memory_event_scenes
                (event_id, app_id, phase, sample_ordinal, scene_id, match_status, matched_by, matcher_version, confidence)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)
            """,
            [
                .text(key.eventID), .integer(appID), .text(key.phase.rawValue), .integer(Int64(key.ordinal)),
                .text(sceneID), .text(status.rawValue),
                .text(SceneStructureMatcher.method), .text(SceneStructureMatcher.version),
            ]
        )
    }

    /// Counts one confirmed observation of a scene: the count moves by one and the last sighting
    /// never moves backwards.
    static func countObservation(_ transaction: SQLiteTransaction, sceneID: String, nowMS: Int64) throws {
        try transaction.execute(
            """
            UPDATE brain_scenes
            SET observation_count = observation_count + 1, last_seen_ms = max(last_seen_ms, ?)
            WHERE scene_id = ?
            """,
            [.integer(nowMS), .text(sceneID)]
        )
    }

    /// Writes a new structural scene from a sample: the scene row with the title as a bucket hint and
    /// the structural digest as a search hint, the global role set, the caption labels, and the
    /// element tree. Everything inside a collection stays out, except the collection itself and one
    /// row template under it.
    static func insertScene(
        _ transaction: SQLiteTransaction,
        sceneID      : String,
        appID        : Int64,
        sample       : CaptureSample,
        skeleton     : SceneSkeleton,
        nowMS        : Int64
    ) throws {
        try transaction.execute(
            """
            INSERT INTO brain_scenes
                (scene_id, app_id, window_title_pattern, title_bucket, scene_kind, structural_key,
                 first_seen_ms, last_seen_ms, observation_count)
            VALUES (?, ?, NULL, ?, ?, ?, ?, ?, 1)
            """,
            [
                .text(sceneID), .integer(appID), .text(LabelText.letters(sample.windowTitle ?? "")),
                .text(skeleton.surface.rawValue), .text(skeleton.structuralKey), .integer(nowMS), .integer(nowMS),
            ]
        )
        for role in skeleton.roles.sorted() {
            try transaction.execute(
                "INSERT INTO brain_scene_roles (scene_id, role, count_bucket) VALUES (?, ?, NULL)",
                [.text(sceneID), .text(role)]
            )
        }
        for label in Set(skeleton.captions.map(\.label)).sorted() where !label.isEmpty {
            try transaction.execute(
                "INSERT INTO brain_scene_labels (scene_id, label_token) VALUES (?, ?)",
                [.text(sceneID), .text(label)]
            )
        }

        var elementIDs: [String: String] = [:]
        var next = 0
        func insert(key: String, scope: String, parent: String?, role: String?, label: String?, origin: LabelOrigin?, kind: String?) throws -> String {
            if let existing = elementIDs[key] { return existing }
            let id = "\(sceneID)#\(next)"
            next += 1
            try transaction.execute(
                """
                INSERT INTO brain_scene_elements
                    (scene_element_id, app_id, scene_id, element_key, element_scope, parent_element_id,
                     label, label_origin, role, kind, first_seen_ms, last_seen_ms, observation_count)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
                """,
                [
                    .text(id), .integer(appID), .text(sceneID), .text(key), .text(scope),
                    parent.map(SQLiteValue.text) ?? .null, label.map(SQLiteValue.text) ?? .null,
                    origin.map { .text($0.rawValue) } ?? .null, role.map(SQLiteValue.text) ?? .null,
                    kind.map(SQLiteValue.text) ?? .null, .integer(nowMS), .integer(nowMS),
                ]
            )
            elementIDs[key] = id
            return id
        }
        /// The container element of a path, creating its chain parent first; nil for the root.
        func container(_ path: String) throws -> String? {
            guard !path.isEmpty else { return nil }
            var parent: String?
            var built = ""
            for segment in path.components(separatedBy: separator) {
                built = built.isEmpty ? segment : built + separator + segment
                parent = try insert(key: "container|\(built)", scope: "container", parent: parent, role: nil,
                                    label: nil, origin: nil, kind: nil)
            }
            return parent
        }
        for element in sample.elements where !element.isUnderCollection
            && !SceneSkeleton.excludedRoles.contains(element.role) {
            let parent    = try container(element.containerPath)
            let isCaption = SceneSkeleton.captionRoles.contains(element.role)
                && element.labelOrigin.map(SceneSkeleton.captionOrigins.contains) == true
            let caption   = isCaption ? LabelText.normalize(element.label) : ""
            _ = try insert(
                key   : "control|\(element.containerPath)|\(element.role)|\(caption)",
                scope : "control",
                parent: parent,
                role  : element.role,
                label : isCaption ? element.label : nil,
                origin: element.labelOrigin,
                kind  : element.kind.rawValue
            )
        }
        for path in skeleton.collections.sorted() {
            let segments = path.components(separatedBy: separator)
            let parent   = try container(segments.dropLast().joined(separator: separator))
            let collection = try insert(key: "collection|\(path)", scope: "collection", parent: parent,
                                        role: nil, label: nil, origin: nil, kind: nil)
            _ = try insert(key: "item_template|\(path)", scope: "item_template", parent: collection,
                           role: "AXRow", label: nil, origin: nil, kind: nil)
        }
    }
}
