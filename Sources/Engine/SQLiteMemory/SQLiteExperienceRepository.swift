//
//  SQLiteExperienceRepository.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import Foundation
import Memory

/// SQLiteExperienceRepository is `ExperienceStoring` over `SQLiteMemoryStore`: an experience and its
/// bindings in `memory_experiences` and `memory_experience_bindings`, in one transaction, after
/// checking that the step belongs to the Route and that every binding names a parameter of the Route
/// it may fill (an `input` or an `inout`) with its type, and that every required one is bound; uses in
/// `memory_experience_uses`. Counts are derived from the uses. Nothing ranks, matches or recalls.
public struct SQLiteExperienceRepository: ExperienceStoring {

    private let store: SQLiteMemoryStore

    public init(store: SQLiteMemoryStore) {
        self.store = store
    }

    public func record(_ experience: ExperienceRecord) async throws -> MemoryReceipt {
        try await store.write { transaction in
            let id = experience.experienceID
            if let stored = try SQLiteExperienceRows.experience(transaction, id: id) {
                guard stored.isExactly(experience) else { throw SQLiteFactRows.conflict(id, stored: "\(stored)", offered: "\(experience)") }
                return .alreadyApplied
            }
            guard try SQLiteRouteRows.status(transaction, experience.routeID) != nil else { throw EventFactError.missingDefinition(id: experience.routeID) }
            if let step = experience.stepID {
                guard try transaction.query("SELECT count(*) FROM memory_route_steps WHERE step_id = ? AND route_id = ?", [.text(step), .text(experience.routeID)],
                                            { $0.integer(0) ?? 0 }).first ?? 0 > 0 else {
                    throw EventFactError.missingDefinition(id: step)
                }
            }
            try SQLiteExperienceRows.checkBindings(transaction, experience)
            try transaction.execute(
                "INSERT INTO memory_experiences (experience_id, phrase, route_id, step_id, created_at_ms) VALUES (?, ?, ?, ?, ?)",
                [.text(id), .text(experience.phrase), .text(experience.routeID), experience.stepID.map(SQLiteValue.text) ?? .null,
                 .integer(experience.createdAtMS)]
            )
            for binding in experience.bindings {
                var values: [SQLiteValue] = Array(repeating: .null, count: 5)
                let kind: String
                switch binding.source {
                    case .literal(let value):
                        kind = "literal"
                        switch value {
                            case .text(let text)   : values[1] = .text(text)
                            case .integer(let v)   : values[2] = .integer(v)
                            case .real(let v)      : values[3] = .real(v)
                            case .boolean(let v)   : values[4] = .integer(v ? 1 : 0)
                        }
                    case .requestSlot(let name): kind = "request_slot"; values[0] = .text(name)
                    case .contextSlot(let name): kind = "context_slot"; values[0] = .text(name)
                }
                try transaction.execute(
                    """
                    INSERT INTO memory_experience_bindings (experience_id, route_id, parameter_id, value_type, binding_kind, binding_contract_version,
                        slot_name, literal_text, literal_integer, literal_real, literal_boolean) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [.text(id), .text(experience.routeID), .text(binding.parameterID), .text(binding.valueType.rawValue), .text(kind),
                     .integer(Int64(ExperienceBinding.contractVersion))] + values
                )
            }
            return .committed
        }
    }

    public func record(_ use: ExperienceUse) async throws -> MemoryReceipt {
        try await store.write { transaction in
            guard try SQLiteExperienceRows.experience(transaction, id: use.experienceID) != nil else { throw EventFactError.missingDefinition(id: use.experienceID) }
            guard try SQLiteFactRows.exists(transaction, "SELECT count(*) FROM memory_events WHERE event_id = ?", use.eventID) else {
                throw EventFactError.missingEvent(eventID: use.eventID)
            }
            if let stored = try SQLiteExperienceRows.uses(transaction, of: use.experienceID).first(where: { $0.eventID.utf8.elementsEqual(use.eventID.utf8) }) {
                guard stored.verdict == use.verdict else { throw SQLiteFactRows.conflict("\(use.experienceID):\(use.eventID)", stored: "\(stored)", offered: "\(use)") }
                return .alreadyApplied
            }
            try transaction.execute("INSERT INTO memory_experience_uses (experience_id, event_id, verdict) VALUES (?, ?, ?)",
                                    [.text(use.experienceID), .text(use.eventID), .text(use.verdict.rawValue)])
            return .committed
        }
    }

    public func experience(_ experienceID: String) async throws -> ExperienceRecord? {
        try await store.read { snapshot in try SQLiteExperienceRows.experience(snapshot, id: experienceID) }
    }

    public func experiences(ofRoute routeID: String) async throws -> [ExperienceRecord] {
        try await store.read { snapshot in
            try snapshot.query("SELECT experience_id FROM memory_experiences WHERE route_id = ? ORDER BY experience_id", [.text(routeID)]) { try $0.text(0) ?? "" }
                .compactMap { try SQLiteExperienceRows.experience(snapshot, id: $0) }
        }
    }

    public func experiences(phrase: String) async throws -> [ExperienceRecord] {
        try await store.read { snapshot in
            // TEXT equality in SQLite is binary: the bytes, no normalization.
            try snapshot.query("SELECT experience_id FROM memory_experiences WHERE phrase = ? ORDER BY experience_id", [.text(phrase)]) { try $0.text(0) ?? "" }
                .compactMap { try SQLiteExperienceRows.experience(snapshot, id: $0) }
        }
    }

    public func uses(of experienceID: String) async throws -> [ExperienceUse] {
        try await store.read { snapshot in try SQLiteExperienceRows.uses(snapshot, of: experienceID) }
    }

    public func useCounts(of experienceID: String) async throws -> ExperienceUseCounts {
        let uses = try await self.uses(of: experienceID)
        return ExperienceUseCounts(passed: uses.filter { $0.verdict == .passed }.count, failed: uses.filter { $0.verdict == .failed }.count,
                                   unknown: uses.filter { $0.verdict == .unknown }.count)
    }
}

/// SQLiteExperienceRows is the codec of experiences, their bindings and uses.
enum SQLiteExperienceRows {

    /// Every binding names a parameter of the Route that a binding may fill, `input` or `inout`,
    /// with its type, and every required one of those is bound.
    static func checkBindings(_ handle: some SQLiteQuerying, _ experience: ExperienceRecord) throws {
        let parameters = try SQLiteRouteRows.parameters(handle, routeID: experience.routeID)
        let byID = Dictionary(uniqueKeysWithValues: parameters.map { (Array($0.parameterID.utf8), $0) })
        for binding in experience.bindings {
            guard let parameter = byID[Array(binding.parameterID.utf8)] else { throw EventFactError.missingDefinition(id: binding.parameterID) }
            guard parameter.direction != .output, parameter.valueType == binding.valueType else {
                throw EventFactError.invalidRecord(.shape(field: "binding \(binding.parameterID)"))
            }
        }
        let bound = Set(experience.bindings.map { Array($0.parameterID.utf8) })
        for parameter in parameters where parameter.isRequired && parameter.direction != .output && !bound.contains(Array(parameter.parameterID.utf8)) {
            throw EventFactError.invalidRecord(.shape(field: "required \(parameter.parameterID)"))
        }
    }

    static func experience(_ handle: some SQLiteQuerying, id: String) throws -> ExperienceRecord? {
        guard let row = try handle.query(
            "SELECT phrase, route_id, step_id, created_at_ms FROM memory_experiences WHERE experience_id = ?", [.text(id)],
            { (phrase: try $0.text(0) ?? "", route: try $0.text(1) ?? "", step: try $0.text(2), created: $0.integer(3) ?? 0) }
        ).first else { return nil }
        func refuse(_ malformation: EventFactError.Malformation) -> EventFactError {
            .malformedRow(table: "memory_experience_bindings", id: id, malformation: malformation)
        }
        let bindings = try handle.query(
            """
            SELECT parameter_id, value_type, binding_kind, binding_contract_version, slot_name, literal_text, literal_integer, literal_real, literal_boolean
            FROM memory_experience_bindings WHERE experience_id = ? ORDER BY parameter_id
            """,
            [.text(id)]
        ) { row -> ExperienceBinding in
            let typeCode = try row.text(1) ?? "", kind = try row.text(2) ?? ""
            guard let type = SQLiteRouteRows.code(ParameterValueType.self, typeCode) else { throw refuse(.unknownCode(column: "value_type", code: typeCode)) }
            guard row.integer(3) == Int64(ExperienceBinding.contractVersion) else {
                throw refuse(.unknownCode(column: "binding_contract_version", code: "\(row.integer(3) ?? 0)"))
            }
            let source: ExperienceBinding.Source
            switch kind {
                case "literal":
                    if let text = try row.text(5) { source = .literal(.text(text)) }
                    else if let value = row.integer(6) { source = .literal(.integer(value)) }
                    else if let value = row.real(7) { source = .literal(.real(value)) }
                    else { source = .literal(.boolean(row.integer(8) == 1)) }
                case "request_slot": source = .requestSlot(try row.text(4) ?? "")
                case "context_slot": source = .contextSlot(try row.text(4) ?? "")
                default: throw refuse(.unknownCode(column: "binding_kind", code: kind))
            }
            do {
                return try ExperienceBinding(parameterID: try row.text(0) ?? "", valueType: type, source: source)
            } catch EventFactError.invalidRecord(let invalidity) {
                throw refuse(.invalid(invalidity))
            }
        }
        let record: ExperienceRecord
        do {
            record = try ExperienceRecord(experienceID: id, phrase: row.phrase, routeID: row.route, stepID: row.step, createdAtMS: row.created, bindings: bindings)
        } catch EventFactError.invalidRecord(let invalidity) {
            throw EventFactError.malformedRow(table: "memory_experiences", id: id, malformation: .invalid(invalidity))
        }
        // The rules of the writer, on the rows read: a binding the Route's parameters do not admit,
        // or a required parameter left without one, is no experience to give back.
        do {
            try checkBindings(handle, record)
        } catch EventFactError.invalidRecord(let invalidity) {
            throw refuse(.invalid(invalidity))
        } catch EventFactError.missingDefinition(let parameterID) {
            throw refuse(.invalid(.shape(field: "binding \(parameterID)")))
        }
        return record
    }

    static func uses(_ handle: some SQLiteQuerying, of experienceID: String) throws -> [ExperienceUse] {
        try handle.query(
            """
            SELECT u.event_id, u.verdict FROM memory_experience_uses u JOIN memory_events e ON e.event_id = u.event_id
            WHERE u.experience_id = ? ORDER BY e.local_order
            """,
            [.text(experienceID)]
        ) { row in
            let eventID = try row.text(0) ?? "", code = try row.text(1) ?? ""
            guard let verdict = SQLiteRouteRows.code(VerificationVerdict.self, code) else {
                throw EventFactError.malformedRow(table: "memory_experience_uses", id: eventID, malformation: .unknownCode(column: "verdict", code: code))
            }
            return try ExperienceUse(experienceID: experienceID, eventID: eventID, verdict: verdict)
        }
    }
}
