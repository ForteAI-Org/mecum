//
//  SQLiteObservationRows.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

import EngineCore
import Foundation
import Memory
import PerceptionCore

/// SQLiteQuerying is what the observation codecs need from either handle of the store: one query,
/// mapped row by row inside the call. The write handle and the read handle both answer it, so a
/// sample is decoded the same way whether a repository checks it before an insert or reads it back.
protocol SQLiteQuerying {

    func query<T>(_ sql: String, _ bindings: [SQLiteValue], _ row: (SQLiteStatement.Row) throws -> T) throws -> [T]
}

extension SQLiteTransaction: SQLiteQuerying {}
extension SQLiteSnapshot: SQLiteQuerying {}

/// SQLiteIdentityRows finds or creates the identity rows an event hangs from: the application by
/// its bundle id and the context by version and locale, with the empty string standing for
/// "unknown" as the schema says. Always inside the caller's transaction, so the lookup and the
/// insert cannot be split by another writer.
enum SQLiteIdentityRows {

    static func ensureApp(_ transaction: SQLiteTransaction, bundleID: String) throws -> Int64 {
        if let found = try transaction.query(
            "SELECT app_id FROM brain_apps WHERE bundle_id = ?", [.text(bundleID)],
            { $0.integer(0) }
        ).first, let appID = found {
            return appID
        }
        try transaction.execute("INSERT INTO brain_apps (bundle_id) VALUES (?)", [.text(bundleID)])
        return try lastInsertedRow(transaction)
    }

    static func ensureContext(
        _ transaction: SQLiteTransaction,
        appID        : Int64,
        version      : String?,
        locale       : String?
    ) throws -> Int64 {
        let versionText = version ?? "", localeText = locale ?? ""
        if let found = try transaction.query(
            "SELECT context_id FROM brain_app_contexts WHERE app_id = ? AND app_version = ? AND app_locale = ?",
            [.integer(appID), .text(versionText), .text(localeText)],
            { $0.integer(0) }
        ).first, let contextID = found {
            return contextID
        }
        try transaction.execute(
            "INSERT INTO brain_app_contexts (app_id, app_version, app_locale) VALUES (?, ?, ?)",
            [.integer(appID), .text(versionText), .text(localeText)]
        )
        return try lastInsertedRow(transaction)
    }

    /// The application id of a bundle, or nil when the store has never seen it.
    static func appID(_ handle: some SQLiteQuerying, bundleID: String) throws -> Int64? {
        try handle.query("SELECT app_id FROM brain_apps WHERE bundle_id = ?", [.text(bundleID)]) { $0.integer(0) }
            .first ?? nil
    }

    static func lastInsertedRow(_ transaction: SQLiteTransaction) throws -> Int64 {
        try transaction.query("SELECT last_insert_rowid()", []) { $0.integer(0) ?? 0 }.first ?? 0
    }
}

/// SQLiteEventRows reads and writes `memory_events` as `MemoryEventRecord`, with the application
/// and context joined back to their names.
enum SQLiteEventRows {

    static func read(_ handle: some SQLiteQuerying, eventID: String) throws -> MemoryEventRecord? {
        try handle.query(
            """
            SELECT e.event_id, e.source, e.source_stream_id, e.source_key, e.trace_id, e.session_id,
                   e.parent_event_id, e.parent_position, e.event_kind, a.bundle_id, c.app_version, c.app_locale,
                   e.occurred_at_ms, e.monotonic_ns, e.capture_status, e.origin_event_id
            FROM memory_events e
            LEFT JOIN brain_apps a ON a.app_id = e.app_id
            LEFT JOIN brain_app_contexts c ON c.context_id = e.context_id
            WHERE e.event_id = ?
            """,
            [.text(eventID)]
        ) { row in
            let sourceCode = try row.text(1) ?? ""
            guard let source = MemoryEventSource(rawValue: sourceCode) else {
                throw ObservationContractError.unknownEventSource(sourceCode)
            }
            let kindCode = try row.text(8) ?? ""
            guard let kind = MemoryEventKind(rawValue: kindCode) else {
                throw ObservationContractError.unknownEventKind(kindCode)
            }
            let statusCode = try row.text(14) ?? ""
            guard let status = EventCaptureStatus(rawValue: statusCode) else {
                throw ObservationContractError.unknownCaptureStatus(statusCode)
            }
            var app: AppContextIdentity?
            if let bundleID = try row.text(9) {
                let version = try row.text(10), locale = try row.text(11)
                app = AppContextIdentity(
                    bundleID: bundleID,
                    version : version.flatMap { $0.isEmpty ? nil : $0 },
                    locale  : locale.flatMap { $0.isEmpty ? nil : $0 }
                )
            }
            return MemoryEventRecord(
                eventID       : try row.text(0) ?? "",
                source        : source,
                streamID      : try row.text(2) ?? "",
                sourceKey     : try row.text(3),
                traceID       : try row.text(4),
                sessionID     : try row.text(5),
                parentEventID : try row.text(6),
                parentPosition: row.integer(7).map(Int.init),
                kind          : kind,
                app           : app,
                occurredAtMS  : row.integer(12) ?? 0,
                monotonicNS   : row.integer(13),
                captureStatus : status,
                originEventID : try row.text(15)
            )
        }.first
    }

    /// Records an event inside the caller's transaction, the one decision every repository that
    /// writes events shares: a stored event with the same immutable content is already applied and
    /// is left as it is, capture summary included; other content under its id, or another event
    /// holding its source key, is `MemoryStoreError.identity`; a new event is inserted with its
    /// application and context found or created beside it.
    static func record(_ transaction: SQLiteTransaction, _ event: MemoryEventRecord) throws -> MemoryReceipt {
        if let stored = try read(transaction, eventID: event.eventID) {
            guard stored.hasSameImmutableContent(as: event) else {
                throw MemoryStoreError.identity(MemoryIdentityConflict(
                    identity          : event.eventID,
                    storedFingerprint : stored.contentDigest,
                    offeredFingerprint: event.contentDigest
                ))
            }
            return .alreadyApplied
        }
        if let key = event.sourceKey {
            let holder = try transaction.query(
                "SELECT event_id FROM memory_events WHERE source = ? AND source_stream_id = ? AND source_key = ?",
                [.text(event.source.rawValue), .text(event.streamID), .text(key)]
            ) { try $0.text(0) ?? "" }.first
            if let holder {
                throw MemoryStoreError.identity(MemoryIdentityConflict(
                    identity          : "\(event.source.rawValue):\(event.streamID):\(key)",
                    storedFingerprint : StructuralDigest.fnv1a(holder),
                    offeredFingerprint: StructuralDigest.fnv1a(event.eventID)
                ))
            }
        }
        var appID: Int64?, contextID: Int64?
        if let app = event.app {
            let foundApp = try SQLiteIdentityRows.ensureApp(transaction, bundleID: app.bundleID)
            appID     = foundApp
            contextID = try SQLiteIdentityRows.ensureContext(transaction, appID: foundApp, version: app.version, locale: app.locale)
        }
        try insert(transaction, event, appID: appID, contextID: contextID)
        return .committed
    }

    /// The application id of an event: nil when the event is unknown, `.some(nil)` when it names
    /// no application.
    static func appID(_ handle: some SQLiteQuerying, eventID: String) throws -> Int64?? {
        try handle.query("SELECT app_id FROM memory_events WHERE event_id = ?", [.text(eventID)]) { $0.integer(0) }
            .first
    }

    static func insert(_ transaction: SQLiteTransaction, _ event: MemoryEventRecord, appID: Int64?, contextID: Int64?) throws {
        try transaction.execute(
            """
            INSERT INTO memory_events
                (event_id, source, source_stream_id, source_key, trace_id, session_id, parent_event_id, parent_position,
                 event_kind, app_id, context_id, occurred_at_ms, monotonic_ns, capture_status, origin_event_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(event.eventID), .text(event.source.rawValue), .text(event.streamID),
                event.sourceKey.map(SQLiteValue.text) ?? .null, event.traceID.map(SQLiteValue.text) ?? .null,
                event.sessionID.map(SQLiteValue.text) ?? .null, event.parentEventID.map(SQLiteValue.text) ?? .null,
                event.parentPosition.map { .integer(Int64($0)) } ?? .null, .text(event.kind.rawValue),
                appID.map(SQLiteValue.integer) ?? .null, contextID.map(SQLiteValue.integer) ?? .null,
                .integer(event.occurredAtMS), event.monotonicNS.map(SQLiteValue.integer) ?? .null,
                .text(event.captureStatus.rawValue), event.originEventID.map(SQLiteValue.text) ?? .null,
            ]
        )
    }

    /// Rewrites the event's capture summary from its samples, the one column that may change.
    static func refreshCaptureStatus(_ transaction: SQLiteTransaction, eventID: String) throws {
        let statuses = try transaction.query(
            "SELECT status FROM memory_event_observations WHERE event_id = ? AND observation_kind = 'capture'",
            [.text(eventID)]
        ) { try $0.text(0) ?? "" }
        let completenesses = try statuses.map { code -> CaptureQuality.Completeness in
            guard let completeness = CaptureQuality.Completeness(rawValue: code) else {
                throw ObservationContractError.unknownCaptureStatus(code)
            }
            return completeness
        }
        let summary = EventCaptureStatus.summary(of: completenesses)
        try transaction.execute(
            "UPDATE memory_events SET capture_status = ? WHERE event_id = ? AND capture_status <> ?",
            [.text(summary.rawValue), .text(eventID), .text(summary.rawValue)]
        )
    }
}

/// SQLiteObservationRows is the codec of `memory_event_observations` for the kinds the registry
/// lists: it writes a sample with its fields and elements, and reads a sample back by rebuilding
/// it from its rows, refusing every row whose kind, version, status or shape this build does not
/// know, quality facts that contradict each other or their sample's status, and bounds that are
/// not finite numbers. The refusals are the contract's (`ObservationContractError`); nothing is
/// read as a lesser row and no code is mapped to a default.
enum SQLiteObservationRows {

    /// One stored row, every column by name, before its kind decides which columns matter.
    struct StoredRow {
        let observationID: Int64
        let eventID: String
        let phase: String
        let ordinal: Int64
        let kindCode: String
        let version: Int64
        let fieldName: String?
        let textValue: String?
        let integerValue: Int64?
        let realValue: Double?
        let booleanValue: Int64?
        let group: Int64?
        let parentID: Int64?
        let windowTitle: String?
        let sessionRevision: Int64?
        let surfaceCode: String?
        let status: String
        let candidateRank: Int64?
        let label: String?
        let labelOriginCode: String?
        let containerPath: String?
        let role: String?
        let elementKindCode: String?
        let oldState: String?
        let newState: String?
        let boundsX: Double?
        let boundsY: Double?
        let boundsWidth: Double?
        let boundsHeight: Double?
        let sceneAgeMS: Double?
        let nameResolution: String?
        let labelSource: String?

        /// Which value columns hold a value, by name.
        var valueColumns: [String] {
            var names: [String] = []
            if textValue != nil { names.append("text_value") }
            if integerValue != nil { names.append("integer_value") }
            if realValue != nil { names.append("real_value") }
            if booleanValue != nil { names.append("boolean_value") }
            return names
        }
    }

    private static let columns = """
        observation_id, event_id, phase, sample_ordinal, observation_kind, observation_contract_version,
        field_name, text_value, integer_value, real_value, boolean_value, observation_group, parent_observation_id,
        window_title, session_revision, surface_kind, status, candidate_rank, label, label_origin, container_path,
        role, element_kind, old_state, new_state, bounds_x, bounds_y, bounds_width, bounds_height, scene_age_ms,
        name_resolution, label_source
        """

    private static func stored(_ row: SQLiteStatement.Row) throws -> StoredRow {
        StoredRow(
            observationID  : row.integer(0) ?? 0,
            eventID        : try row.text(1) ?? "",
            phase          : try row.text(2) ?? "",
            ordinal        : row.integer(3) ?? 0,
            kindCode       : try row.text(4) ?? "",
            version        : row.integer(5) ?? 0,
            fieldName      : try row.text(6),
            textValue      : try row.text(7),
            integerValue   : row.integer(8),
            realValue      : row.real(9),
            booleanValue   : row.integer(10),
            group          : row.integer(11),
            parentID       : row.integer(12),
            windowTitle    : try row.text(13),
            sessionRevision: row.integer(14),
            surfaceCode    : try row.text(15),
            status         : try row.text(16) ?? "",
            candidateRank  : row.integer(17),
            label          : try row.text(18),
            labelOriginCode: try row.text(19),
            containerPath  : try row.text(20),
            role           : try row.text(21),
            elementKindCode: try row.text(22),
            oldState       : try row.text(23),
            newState       : try row.text(24),
            boundsX        : row.real(25),
            boundsY        : row.real(26),
            boundsWidth    : row.real(27),
            boundsHeight   : row.real(28),
            sceneAgeMS     : row.real(29),
            nameResolution : try row.text(30),
            labelSource    : try row.text(31)
        )
    }

    // MARK: Reading

    /// Every row stored under a sample key, the capture first, in insertion order.
    static func rows(_ handle: some SQLiteQuerying, key: CaptureSampleKey) throws -> [StoredRow] {
        try handle.query(
            """
            SELECT \(columns) FROM memory_event_observations
            WHERE event_id = ? AND phase = ? AND sample_ordinal = ?
            ORDER BY parent_observation_id IS NOT NULL, observation_id
            """,
            [.text(key.eventID), .text(key.phase.rawValue), .integer(Int64(key.ordinal))],
            stored
        )
    }

    /// The sample stored under a key, rebuilt from its rows, or nil when no capture row exists.
    /// Every row under the key must be the capture or one of its children at a known kind and
    /// version, in the shape the registry documents.
    static func sample(_ handle: some SQLiteQuerying, key: CaptureSampleKey) throws -> CaptureSample? {
        let rows = try rows(handle, key: key)
        guard let capture = rows.first(where: { $0.parentID == nil && $0.kindCode == ObservationKind.capture.rawValue }) else {
            for row in rows { _ = try ObservationKind.resolve(code: row.kindCode, version: Int(row.version)) }
            if let stray = rows.first {
                throw ObservationContractError.malformedObservation(observationID: stray.observationID, malformation: .orphanChild)
            }
            return nil
        }
        _ = try ObservationKind.resolve(code: capture.kindCode, version: Int(capture.version))
        try requireNull(capture, [
            ("field_name", capture.fieldName != nil), ("observation_group", capture.group != nil),
            ("candidate_rank", capture.candidateRank != nil), ("label", capture.label != nil),
            ("label_origin", capture.labelOriginCode != nil), ("container_path", capture.containerPath != nil),
            ("role", capture.role != nil), ("element_kind", capture.elementKindCode != nil),
            ("old_state", capture.oldState != nil), ("new_state", capture.newState != nil),
            ("bounds", capture.boundsX != nil || capture.boundsY != nil || capture.boundsWidth != nil || capture.boundsHeight != nil),
            ("scene_age_ms", capture.sceneAgeMS != nil), ("name_resolution", capture.nameResolution != nil),
            ("label_source", capture.labelSource != nil),
        ])
        if !capture.valueColumns.isEmpty {
            throw ObservationContractError.malformedObservation(
                observationID: capture.observationID, malformation: .forbiddenColumn(capture.valueColumns[0]))
        }
        guard let completeness = CaptureQuality.Completeness(rawValue: capture.status) else {
            throw ObservationContractError.unknownStatus(kind: .capture, status: capture.status)
        }
        guard let surfaceCode = capture.surfaceCode else {
            throw ObservationContractError.malformedObservation(observationID: capture.observationID, malformation: .missingColumn("surface_kind"))
        }
        guard let surface = CaptureSurface(rawValue: surfaceCode) else {
            throw ObservationContractError.unknownSurface(surfaceCode)
        }

        var fields: [CaptureField: CaptureFieldValue] = [:]
        var elements: [CaptureElement] = []
        var groupPaths: [Int64: String] = [:]
        for row in rows where row.observationID != capture.observationID {
            let kind = try ObservationKind.resolve(code: row.kindCode, version: Int(row.version))
            guard let parentID = row.parentID else {
                throw ObservationContractError.malformedObservation(observationID: row.observationID, malformation: .orphanChild)
            }
            guard parentID == capture.observationID else {
                throw ObservationContractError.malformedObservation(observationID: row.observationID, malformation: .nestedUnderChild)
            }
            guard row.phase == capture.phase, row.ordinal == capture.ordinal else {
                throw ObservationContractError.malformedObservation(observationID: row.observationID, malformation: .parentMismatch)
            }
            switch kind {
                case .capture:
                    throw ObservationContractError.malformedObservation(observationID: row.observationID, malformation: .nestedUnderChild)
                case .captureField:
                    let (field, value) = try captureField(row)
                    guard fields[field] == nil else {
                        throw ObservationContractError.malformedObservation(observationID: row.observationID, malformation: .duplicateField(field.rawValue))
                    }
                    fields[field] = value
                case .element:
                    let element = try element(row)
                    if let group = row.group {
                        if let path = groupPaths[group], path != element.containerPath {
                            throw ObservationContractError.malformedObservation(
                                observationID: row.observationID, malformation: .collectionGroupInconsistent(group))
                        }
                        groupPaths[group] = element.containerPath
                    }
                    elements.append(element)
            }
        }
        for field in CaptureField.allCases where fields[field] == nil {
            throw ObservationContractError.malformedObservation(observationID: capture.observationID, malformation: .missingColumn(field.rawValue))
        }
        let quality: CaptureQuality
        do {
            quality = try CaptureQuality(fields: fields)
        } catch ObservationContractError.malformedObservation(_, let malformation) {
            throw ObservationContractError.malformedObservation(observationID: capture.observationID, malformation: malformation)
        }
        if let inconsistency = quality.inconsistency {
            throw ObservationContractError.malformedObservation(
                observationID: capture.observationID, malformation: .inconsistentQuality(inconsistency))
        }
        guard quality.completeness == completeness else {
            throw ObservationContractError.malformedObservation(observationID: capture.observationID, malformation: .statusContradictsFields)
        }
        return CaptureSample(
            key            : key,
            windowTitle    : capture.windowTitle,
            sessionRevision: capture.sessionRevision,
            surface        : surface,
            quality        : quality,
            elements       : elements
        )
    }

    private static func captureField(_ row: StoredRow) throws -> (CaptureField, CaptureFieldValue) {
        guard let name = row.fieldName else {
            throw ObservationContractError.malformedObservation(observationID: row.observationID, malformation: .missingColumn("field_name"))
        }
        guard let field = CaptureField(rawValue: name) else { throw ObservationContractError.unknownCaptureField(name) }
        guard let status = ObservationStatus(rawValue: row.status) else {
            throw ObservationContractError.unknownStatus(kind: .captureField, status: row.status)
        }
        try requireNull(row, [
            ("surface_kind", row.surfaceCode != nil), ("window_title", row.windowTitle != nil),
            ("session_revision", row.sessionRevision != nil), ("observation_group", row.group != nil),
            ("candidate_rank", row.candidateRank != nil), ("label", row.label != nil),
            ("label_origin", row.labelOriginCode != nil), ("container_path", row.containerPath != nil),
            ("role", row.role != nil), ("element_kind", row.elementKindCode != nil),
            ("old_state", row.oldState != nil), ("new_state", row.newState != nil),
            ("bounds", row.boundsX != nil || row.boundsY != nil || row.boundsWidth != nil || row.boundsHeight != nil),
            ("scene_age_ms", row.sceneAgeMS != nil), ("name_resolution", row.nameResolution != nil),
            ("label_source", row.labelSource != nil), ("real_value", row.realValue != nil),
        ])
        switch status {
            case .notObserved:
                if let extra = row.valueColumns.first {
                    throw ObservationContractError.malformedObservation(observationID: row.observationID, malformation: .forbiddenColumn(extra))
                }
                return (field, .notObserved)
            case .observed:
                guard let column = row.valueColumns.first else {
                    throw ObservationContractError.malformedObservation(observationID: row.observationID, malformation: .missingColumn("value"))
                }
                switch (field.valueKind, column) {
                    case (.boolean, "boolean_value"): return (field, .boolean(row.booleanValue == 1))
                    case (.text, "text_value")      : return (field, .text(row.textValue ?? ""))
                    case (.integer, "integer_value"): return (field, .integer(row.integerValue ?? 0))
                    default:
                        throw ObservationContractError.malformedObservation(
                            observationID: row.observationID, malformation: .valueKindMismatch(field.rawValue))
                }
        }
    }

    private static func element(_ row: StoredRow) throws -> CaptureElement {
        guard let status = ObservationStatus(rawValue: row.status) else {
            throw ObservationContractError.unknownStatus(kind: .element, status: row.status)
        }
        guard status == .observed else {
            throw ObservationContractError.malformedObservation(observationID: row.observationID, malformation: .forbiddenColumn("status"))
        }
        try requireNull(row, [
            ("field_name", row.fieldName != nil), ("value", !row.valueColumns.isEmpty),
            ("surface_kind", row.surfaceCode != nil), ("window_title", row.windowTitle != nil),
            ("session_revision", row.sessionRevision != nil), ("candidate_rank", row.candidateRank != nil),
            ("old_state", row.oldState != nil), ("scene_age_ms", row.sceneAgeMS != nil),
            ("name_resolution", row.nameResolution != nil), ("label_source", row.labelSource != nil),
        ])
        guard let role = row.role, !role.isEmpty else {
            throw ObservationContractError.malformedObservation(observationID: row.observationID, malformation: .missingRole)
        }
        guard let label = row.label else {
            throw ObservationContractError.malformedObservation(observationID: row.observationID, malformation: .missingColumn("label"))
        }
        guard let kindCode = row.elementKindCode else {
            throw ObservationContractError.malformedObservation(observationID: row.observationID, malformation: .missingColumn("element_kind"))
        }
        guard let kind = ElementKind(rawValue: kindCode) else { throw ObservationContractError.unknownElementKind(kindCode) }
        guard let containerPath = row.containerPath else {
            throw ObservationContractError.malformedObservation(observationID: row.observationID, malformation: .missingColumn("container_path"))
        }
        var origin: LabelOrigin?
        if let code = row.labelOriginCode {
            guard let known = LabelOrigin(rawValue: code) else { throw ObservationContractError.unknownLabelOrigin(code) }
            origin = known
        }
        var state: ControlState?
        if let code = row.newState {
            guard let known = ControlState(rawValue: code) else { throw ObservationContractError.unknownControlState(code) }
            state = known
        }
        guard let x = row.boundsX, let y = row.boundsY, let width = row.boundsWidth, let height = row.boundsHeight else {
            throw ObservationContractError.malformedObservation(observationID: row.observationID, malformation: .missingColumn("bounds"))
        }
        let bounds = NormalizedRect(x: x, y: y, width: width, height: height)
        guard bounds.isFinite else {
            throw ObservationContractError.malformedObservation(observationID: row.observationID, malformation: .nonFiniteBounds)
        }
        if let group = row.group, group < 1 {
            throw ObservationContractError.malformedObservation(observationID: row.observationID, malformation: .forbiddenColumn("observation_group"))
        }
        return CaptureElement(
            kind             : kind,
            role             : role,
            label            : label,
            labelOrigin      : origin,
            containerPath    : containerPath,
            isUnderCollection: row.group != nil,
            state            : state,
            bounds           : bounds
        )
    }

    private static func requireNull(_ row: StoredRow, _ checks: [(String, Bool)]) throws {
        for (column, isSet) in checks where isSet {
            throw ObservationContractError.malformedObservation(observationID: row.observationID, malformation: .forbiddenColumn(column))
        }
    }

    // MARK: Writing

    /// Inserts a sample: the capture row, its eight quality fields and its elements, in this order,
    /// all under the caller's transaction. Elements inside a collection share one group number per
    /// collection path, numbered in order of first appearance.
    static func insert(_ transaction: SQLiteTransaction, _ sample: CaptureSample) throws {
        try transaction.execute(
            """
            INSERT INTO memory_event_observations
                (event_id, phase, sample_ordinal, observation_kind, observation_contract_version,
                 status, surface_kind, window_title, session_revision)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(sample.key.eventID), .text(sample.key.phase.rawValue), .integer(Int64(sample.key.ordinal)),
                .text(ObservationKind.capture.rawValue), .integer(Int64(ObservationKind.contractVersion)),
                .text(sample.quality.completeness.rawValue), .text(sample.surface.rawValue),
                sample.windowTitle.map(SQLiteValue.text) ?? .null, sample.sessionRevision.map(SQLiteValue.integer) ?? .null,
            ]
        )
        let captureID = try SQLiteIdentityRows.lastInsertedRow(transaction)
        for (field, value) in sample.fields {
            var text: SQLiteValue = .null, integer: SQLiteValue = .null, boolean: SQLiteValue = .null
            var status = ObservationStatus.observed
            switch value {
                case .boolean(let flag) : boolean = .integer(flag ? 1 : 0)
                case .text(let string)  : text = .text(string)
                case .integer(let count): integer = .integer(count)
                case .notObserved       : status = .notObserved
            }
            try transaction.execute(
                """
                INSERT INTO memory_event_observations
                    (event_id, phase, sample_ordinal, observation_kind, observation_contract_version,
                     parent_observation_id, field_name, text_value, integer_value, boolean_value, status)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(sample.key.eventID), .text(sample.key.phase.rawValue), .integer(Int64(sample.key.ordinal)),
                    .text(ObservationKind.captureField.rawValue), .integer(Int64(ObservationKind.contractVersion)),
                    .integer(captureID), .text(field.rawValue), text, integer, boolean, .text(status.rawValue),
                ]
            )
        }
        var groups: [String: Int64] = [:]
        for element in sample.elements {
            var group: SQLiteValue = .null
            if element.isUnderCollection {
                let number = groups[element.containerPath] ?? Int64(groups.count + 1)
                groups[element.containerPath] = number
                group = .integer(number)
            }
            try transaction.execute(
                """
                INSERT INTO memory_event_observations
                    (event_id, phase, sample_ordinal, observation_kind, observation_contract_version,
                     parent_observation_id, status, observation_group, label, label_origin, container_path, role,
                     element_kind, new_state, bounds_x, bounds_y, bounds_width, bounds_height)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(sample.key.eventID), .text(sample.key.phase.rawValue), .integer(Int64(sample.key.ordinal)),
                    .text(ObservationKind.element.rawValue), .integer(Int64(ObservationKind.contractVersion)),
                    .integer(captureID), .text(ObservationStatus.observed.rawValue), group,
                    .text(element.label), element.labelOrigin.map { .text($0.rawValue) } ?? .null,
                    .text(element.containerPath), .text(element.role), .text(element.kind.rawValue),
                    element.state.map { .text($0.rawValue) } ?? .null,
                    .real(element.bounds.x), .real(element.bounds.y), .real(element.bounds.width), .real(element.bounds.height),
                ]
            )
        }
    }
}
