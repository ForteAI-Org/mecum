//
//  SQLiteRouteRepository.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import EngineCore
import Foundation
import Memory
import PerceptionCore

/// SQLiteRouteRepository is `RouteStoring` over `SQLiteMemoryStore`: a definition in `memory_routes`,
/// `memory_route_parameters`, `memory_route_steps`, `memory_step_checks`, `memory_step_operations`,
/// the operations' rows of `memory_operation_arguments` and `memory_route_call_bindings`, in one
/// write transaction, after the checks only the store can make: the superseded and called Routes
/// exist, every binding agrees with the called Route's parameters in direction and type, anchors,
/// scenes and menu commands belong to the step's application. Nothing in production calls it, and
/// no Route is run.
public struct SQLiteRouteRepository: RouteStoring {

    private let store: SQLiteMemoryStore

    public init(store: SQLiteMemoryStore) {
        self.store = store
    }

    public func record(_ definition: RouteDefinition, state: RouteState) async throws -> MemoryReceipt {
        try definition.validate()
        try SQLiteRouteRows.validate(state)
        if state.status == .active, let problem = definition.publicationProblem {
            throw RouteError.unpublishable(routeID: definition.routeID, reason: problem)
        }
        return try await store.write { transaction in
            if let stored = try SQLiteRouteRows.read(transaction, routeID: definition.routeID) {
                guard stored.definition.isExactly(definition) else {
                    throw SQLiteFactRows.conflict(definition.routeID, stored: "\(stored.definition)", offered: "\(definition)")
                }
                return .alreadyApplied
            }
            if let superseded = definition.supersedesRouteID, try SQLiteRouteRows.status(transaction, superseded) == nil {
                throw RouteError.missingRoute(routeID: superseded)
            }
            try SQLiteRouteRows.checkCalls(transaction, definition, publishing: state.status == .active)
            try SQLiteRouteRows.insert(transaction, definition, state: state)
            return .committed
        }
    }

    public func update(_ routeID: String, from expected: RouteState, to updated: RouteState) async throws -> MemoryReceipt {
        try SQLiteRouteRows.validate(updated)
        return try await store.write { transaction in
            guard let stored = try SQLiteRouteRows.read(transaction, routeID: routeID) else { throw RouteError.missingRoute(routeID: routeID) }
            if stored.state.isExactly(updated) { return .alreadyApplied }
            guard stored.state.isExactly(expected) else { throw RouteError.staleExpectation(routeID: routeID) }
            let from = stored.state.status, to = updated.status
            switch (from, to) {
                case (.draft, .draft), (.active, .active), (.retired, .retired), (.draft, .retired), (.active, .retired):
                    break
                case (.draft, .active):
                    if let problem = stored.definition.publicationProblem { throw RouteError.unpublishable(routeID: routeID, reason: problem) }
                    try SQLiteRouteRows.checkCalls(transaction, stored.definition, publishing: true)
                default:
                    throw RouteError.invalidStateChange(routeID: routeID, from: from, to: to)
            }
            switch (stored.state.lastUsedMS, updated.lastUsedMS) {
                case (let before?, let after?) where after < before: throw RouteError.invalidDefinition(.lastUsedBackwards)
                case (_?, nil): throw RouteError.invalidDefinition(.lastUsedBackwards)
                default: break
            }
            try transaction.execute(
                "UPDATE memory_routes SET status = ?, last_used_ms = ?, demoted_at_ms = ?, demotion_cause = ? WHERE route_id = ?",
                [.text(to.rawValue), updated.lastUsedMS.map(SQLiteValue.integer) ?? .null, updated.demotedAtMS.map(SQLiteValue.integer) ?? .null,
                 updated.demotionCause.map(SQLiteValue.text) ?? .null, .text(routeID)]
            )
            return .committed
        }
    }

    public func route(_ routeID: String) async throws -> StoredRoute? {
        try await store.read { snapshot in try SQLiteRouteRows.read(snapshot, routeID: routeID) }
    }
}

/// SQLiteRouteRows is the codec of a definition and the checks it needs the file for.
enum SQLiteRouteRows {

    static func validate(_ state: RouteState) throws {
        for instant in [state.lastUsedMS, state.demotedAtMS].compactMap({ $0 }) where !BrainClock.range.contains(instant) {
            throw RouteError.invalidDefinition(.outOfRange(field: "ms"))
        }
        if (state.demotedAtMS == nil) != (state.demotionCause == nil) { throw RouteError.invalidDefinition(.demotionHalf) }
        if let cause = state.demotionCause, cause.isEmpty { throw RouteError.invalidDefinition(.emptyText(field: "demotion_cause")) }
    }

    static func status(_ handle: some SQLiteQuerying, _ routeID: String) throws -> String? {
        try handle.query("SELECT status FROM memory_routes WHERE route_id = ?", [.text(routeID)]) { try $0.text(0) ?? "" }.first
    }

    /// Every call of the definition: the called Route exists, each binding names one of its
    /// parameters and agrees in direction and type, and, when publishing, the called Route is
    /// active and every required parameter it reads is bound.
    ///
    /// The composition rules: a called `input` takes a literal of its type or a calling parameter
    /// of its type that the calling Route can read (`input` or `inout`); a called `output` gives
    /// its value to a calling `output` or `inout` parameter of its type, never to a literal; a called
    /// `inout` is bound to a calling `inout` of its type, in both directions. A required called
    /// `input` or `inout` must be bound before publication; an output need not be.
    static func checkCalls(_ handle: some SQLiteQuerying, _ definition: RouteDefinition, publishing: Bool) throws {
        for step in definition.steps {
            guard case .routeCall(let callee, let bindings) = step.kind else { continue }
            guard let calleeStatus = try status(handle, callee) else { throw RouteError.missingRoute(routeID: callee) }
            let params = try relations(handle, definition, stepID: step.stepID, callee: callee, bindings: bindings)
            guard publishing else { continue }
            guard calleeStatus == RouteStatus.active.rawValue else {
                throw RouteError.unpublishable(routeID: definition.routeID, reason: .inactiveCallee(stepID: step.stepID))
            }
            try requiredBound(definition, stepID: step.stepID, params: params, bindings: bindings)
        }
    }

    /// The relations a stored definition keeps whatever happened since: every binding agrees with
    /// the called Route's parameters, and a definition stored `active` binds every required one.
    /// The called Route's status is not read: a callee retired later leaves the caller's definition
    /// what it was. Only the called Route's parameters are read, in the same snapshot, never its
    /// definition, so composed Routes are read without recursion.
    static func checkCallRelations(_ handle: some SQLiteQuerying, _ definition: RouteDefinition, status: RouteStatus) throws {
        for step in definition.steps {
            guard case .routeCall(let callee, let bindings) = step.kind else { continue }
            let params = try relations(handle, definition, stepID: step.stepID, callee: callee, bindings: bindings)
            if status == .active { try requiredBound(definition, stepID: step.stepID, params: params, bindings: bindings) }
        }
    }

    /// Each binding of one call against the called Route's parameters, which it answers.
    private static func relations(_ handle: some SQLiteQuerying, _ definition: RouteDefinition, stepID: String, callee: String,
                                  bindings: [RouteCallBinding]) throws -> [RouteParameter] {
        let own = Dictionary(uniqueKeysWithValues: definition.parameters.map { (Array($0.parameterID.utf8), $0) })
        let params = try parameters(handle, routeID: callee)
        let byID = Dictionary(uniqueKeysWithValues: params.map { (Array($0.parameterID.utf8), $0) })
        func refuse(_ id: String, _ problem: String) -> RouteError {
            .invalidDefinition(.binding(stepID: stepID, calledParameterID: id, problem: problem))
        }
        for binding in bindings {
            guard let called = byID[Array(binding.calledParameterID.utf8)] else { throw refuse(binding.calledParameterID, "not a parameter of the called Route") }
            switch binding.source {
                case .literal(let value):
                    guard called.direction == .input else { throw refuse(called.parameterID, "a literal is no destination") }
                    guard ParameterValueType(value.kind) == called.valueType else { throw refuse(called.parameterID, "literal of another type") }
                case .parameter(let id):
                    guard let source = own[Array(id.utf8)] else { throw RouteError.invalidDefinition(.unknownParameter(id)) }
                    guard source.valueType == called.valueType else { throw refuse(called.parameterID, "parameter of another type") }
                    let allowed: Set<ParameterDirection> = switch called.direction {
                        case .input : [.input, .inout]
                        case .output: [.output, .inout]
                        case .inout : [.inout]
                    }
                    guard allowed.contains(source.direction) else { throw refuse(called.parameterID, "direction \(source.direction.rawValue)") }
            }
        }
        return params
    }

    private static func requiredBound(_ definition: RouteDefinition, stepID: String, params: [RouteParameter], bindings: [RouteCallBinding]) throws {
        let bound = Set(bindings.map { Array($0.calledParameterID.utf8) })
        for param in params where param.isRequired && param.direction != .output && !bound.contains(Array(param.parameterID.utf8)) {
            throw RouteError.unpublishable(routeID: definition.routeID, reason: .missingBinding(stepID: stepID, calledParameterID: param.parameterID))
        }
    }

    // MARK: Writing

    static func insert(_ transaction: SQLiteTransaction, _ definition: RouteDefinition, state: RouteState) throws {
        let routeID = definition.routeID
        // Parameter, step, check and operation ids are identities of the whole file, not of the
        // Route: one another definition already holds is a typed refusal, before any row is written.
        var owned: [(String, String, String)] = definition.parameters.map { ("memory_route_parameters", "parameter_id", $0.parameterID) }
        for step in definition.steps {
            owned.append(("memory_route_steps", "step_id", step.stepID))
            owned += step.checks.map { ("memory_step_checks", "check_id", $0.checkID) }
            for operation in step.operations {
                owned.append(("memory_step_operations", "operation_id", operation.operationID))
                owned += operation.children.map { ("memory_step_operations", "operation_id", $0.operationID) }
            }
        }
        for (table, column, id) in owned
        where try transaction.query("SELECT count(*) FROM \(table) WHERE \(column) = ?", [.text(id)], { $0.integer(0) ?? 0 }).first ?? 0 > 0 {
            throw RouteError.invalidDefinition(.repeatedID(id))
        }
        try transaction.execute(
            """
            INSERT INTO memory_routes (route_id, name, status, supersedes_route_id, created_at_ms, last_used_ms, demoted_at_ms, demotion_cause)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(routeID), .text(definition.name), .text(state.status.rawValue), definition.supersedesRouteID.map(SQLiteValue.text) ?? .null,
             .integer(definition.createdAtMS), state.lastUsedMS.map(SQLiteValue.integer) ?? .null,
             state.demotedAtMS.map(SQLiteValue.integer) ?? .null, state.demotionCause.map(SQLiteValue.text) ?? .null]
        )
        for parameter in definition.parameters {
            try transaction.execute(
                "INSERT INTO memory_route_parameters (parameter_id, route_id, name, direction, value_type, is_required) VALUES (?, ?, ?, ?, ?, ?)",
                [.text(parameter.parameterID), .text(routeID), .text(parameter.name), .text(parameter.direction.rawValue),
                 .text(parameter.valueType.rawValue), .integer(parameter.isRequired ? 1 : 0)]
            )
        }
        for step in definition.steps {
            let appID = try step.bundleID.map { try SQLiteIdentityRows.ensureApp(transaction, bundleID: $0) }
            var callee: String?
            if case .routeCall(let called, _) = step.kind { callee = called }
            try transaction.execute(
                "INSERT INTO memory_route_steps (step_id, route_id, position, step_kind, goal_text, app_id, called_route_id) VALUES (?, ?, ?, ?, ?, ?, ?)",
                [.text(step.stepID), .text(routeID), .integer(Int64(step.position)), .text(callee == nil ? "goal" : "route_call"),
                 .text(step.goalText), appID.map(SQLiteValue.integer) ?? .null, callee.map(SQLiteValue.text) ?? .null]
            )
            for check in step.checks {
                if let scene = check.sceneID { try reference(transaction, "scene", scene, appID: appID) }
                if let anchor = check.anchorID { try reference(transaction, "anchor", anchor, appID: appID) }
                var expected: [SQLiteValue] = Array(repeating: .null, count: 6)
                switch check.expected {
                    case .state(let state)?   : expected[0] = .text(state.rawValue)
                    case .text(let text)?     : expected[1] = .text(text)
                    case .integer(let value)? : expected[2] = .integer(value)
                    case .real(let value)?    : expected[3] = .real(value)
                    case .boolean(let flag)?  : expected[4] = .integer(flag ? 1 : 0)
                    case .parameter(let id)?  : expected[5] = .text(id)
                    case nil                  : break
                }
                try transaction.execute(
                    """
                    INSERT INTO memory_step_checks (check_id, route_id, step_id, app_id, position, check_kind, expected_scene_id, expected_anchor_id,
                        expected_state, expected_text, expected_integer, expected_real, expected_bool, expected_parameter_id, comparison)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [.text(check.checkID), .text(routeID), .text(step.stepID), appID.map(SQLiteValue.integer) ?? .null, .integer(Int64(check.position)),
                     .text(check.kind.rawValue), check.sceneID.map(SQLiteValue.text) ?? .null, check.anchorID.map(SQLiteValue.text) ?? .null]
                        + expected + [check.comparison.map { .text($0.rawValue) } ?? .null]
                )
            }
            for operation in step.operations {
                try insert(transaction, operation, parent: nil, routeID: routeID, stepID: step.stepID, appID: appID)
                for child in operation.children {
                    try insert(transaction, child, parent: operation.operationID, routeID: routeID, stepID: step.stepID, appID: appID)
                }
            }
            if case .routeCall(let called, let bindings) = step.kind {
                for binding in bindings {
                    var values: [SQLiteValue] = Array(repeating: .null, count: 5)
                    switch binding.source {
                        case .parameter(let id)         : values[0] = .text(id)
                        case .literal(.text(let text))  : values[1] = .text(text)
                        case .literal(.integer(let v))  : values[2] = .integer(v)
                        case .literal(.real(let v))     : values[3] = .real(v)
                        case .literal(.boolean(let v))  : values[4] = .integer(v ? 1 : 0)
                    }
                    try transaction.execute(
                        """
                        INSERT INTO memory_route_call_bindings (step_id, route_id, called_route_id, called_parameter_id, source_parameter_id,
                            literal_text, literal_integer, literal_real, literal_bool) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        [.text(step.stepID), .text(routeID), .text(called), .text(binding.calledParameterID)] + values
                    )
                }
            }
        }
    }

    private static func insert(_ transaction: SQLiteTransaction, _ operation: StepOperation, parent: String?, routeID: String, stepID: String,
                               appID: Int64?) throws {
        try transaction.execute(
            """
            INSERT INTO memory_step_operations (operation_id, route_id, step_id, parent_operation_id, position, tool_kind, contract_version, app_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(operation.operationID), .text(routeID), .text(stepID), parent.map(SQLiteValue.text) ?? .null, .integer(Int64(operation.position)),
             .text(operation.tool.rawValue), .integer(Int64(AgentCallContract.version)), appID.map(SQLiteValue.integer) ?? .null]
        )
        for argument in operation.arguments {
            let (kind, column, value): (String, String, SQLiteValue)
            switch argument.value {
                case .literal(.text(let text))   : (kind, column, value) = ("text", "text_value", .text(text))
                case .literal(.integer(let v))   : (kind, column, value) = ("integer", "integer_value", .integer(v))
                case .literal(.real(let v))      : (kind, column, value) = ("real", "real_value", .real(v))
                case .literal(.boolean(let v))   : (kind, column, value) = ("boolean", "boolean_value", .integer(v ? 1 : 0))
                case .parameter(let id)          : (kind, column, value) = ("parameter", "parameter_id", .text(id))
                case .anchor(let id):
                    try reference(transaction, "anchor", id, appID: appID)
                    (kind, column, value) = ("anchor", "anchor_id", .text(id))
                case .menu(let id):
                    try reference(transaction, "menu", id, appID: appID)
                    (kind, column, value) = ("menu", "menu_command_id", .text(id))
            }
            try transaction.execute(
                """
                INSERT INTO memory_operation_arguments (operation_id, route_id, app_id, argument_name, position, value_kind, \(column))
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [.text(operation.operationID), .text(routeID), appID.map(SQLiteValue.integer) ?? .null, .text(argument.name),
                 .integer(Int64(argument.position)), .text(kind), value]
            )
        }
    }

    /// Checks that an anchor, a structural scene or a menu command belongs to the step's application.
    private static func reference(_ handle: some SQLiteQuerying, _ kind: String, _ id: String, appID: Int64?) throws {
        guard let appID else { throw RouteError.invalidDefinition(.reference(kind: kind, id: id)) }
        let sql = switch kind {
            case "anchor": "SELECT count(*) FROM brain_anchors WHERE anchor_id = ? AND app_id = ?"
            case "scene" : "SELECT count(*) FROM brain_scenes WHERE scene_id = ? AND app_id = ? AND scene_kind <> 'app'"
            default      : "SELECT count(*) FROM brain_menu_commands WHERE menu_command_id = ? AND app_id = ?"
        }
        guard try handle.query(sql, [.text(id), .integer(appID)], { $0.integer(0) ?? 0 }).first ?? 0 > 0 else {
            throw RouteError.invalidDefinition(.reference(kind: kind, id: id))
        }
    }

    // MARK: Reading

    static func parameters(_ handle: some SQLiteQuerying, routeID: String) throws -> [RouteParameter] {
        let rows = try handle.query(
            "SELECT parameter_id, name, direction, value_type, is_required FROM memory_route_parameters WHERE route_id = ?", [.text(routeID)]
        ) { row in
            let id = try row.text(0) ?? ""
            guard let direction = code(ParameterDirection.self, try row.text(2)), let type = code(ParameterValueType.self, try row.text(3)) else {
                throw RouteError.malformedRow(table: "memory_route_parameters", id: id, malformation: .unknownCode(column: "direction/value_type", code: id))
            }
            return RouteParameter(parameterID: id, name: try row.text(1) ?? "", direction: direction, valueType: type, isRequired: row.integer(4) == 1)
        }
        return RouteDefinition.sorted(rows)
    }

    /// The stored definition and state, rebuilt from every row and validated as a write is: a code
    /// this contract does not know, a contract version it does not read, a position that is not
    /// 0 ..< n, a reference or a shape a definition may not have, are typed refusals.
    static func read(_ handle: some SQLiteQuerying, routeID: String) throws -> StoredRoute? {
        guard let route = try handle.query(
            "SELECT name, status, supersedes_route_id, created_at_ms, last_used_ms, demoted_at_ms, demotion_cause FROM memory_routes WHERE route_id = ?",
            [.text(routeID)],
            { row in (name: try row.text(0) ?? "", status: try row.text(1) ?? "", supersedes: try row.text(2), created: row.integer(3) ?? 0,
                      lastUsed: row.integer(4), demoted: row.integer(5), cause: try row.text(6)) }
        ).first else { return nil }
        func refuse(_ table: String, _ id: String, _ malformation: RouteError.Malformation) -> RouteError {
            .malformedRow(table: table, id: id, malformation: malformation)
        }
        guard let status = code(RouteStatus.self, route.status) else {
            throw refuse("memory_routes", routeID, .unknownCode(column: "status", code: route.status))
        }
        let parameters = try self.parameters(handle, routeID: routeID)
        let stepRows = try handle.query(
            """
            SELECT s.step_id, s.position, s.step_kind, s.goal_text, a.bundle_id, s.called_route_id
            FROM memory_route_steps s LEFT JOIN brain_apps a ON a.app_id = s.app_id WHERE s.route_id = ? ORDER BY s.position
            """,
            [.text(routeID)]
        ) { (id: try $0.text(0) ?? "", position: $0.integer(1) ?? -1, kind: try $0.text(2) ?? "", goal: try $0.text(3) ?? "",
             bundle: try $0.text(4), callee: try $0.text(5)) }
        var steps: [ProcedureStep] = []
        for row in stepRows {
            guard let position = Int(exactly: row.position) else { throw refuse("memory_route_steps", row.id, .invalid(.positions(of: "steps"))) }
            let checks = try self.checks(handle, stepID: row.id)
            let operations = try self.operations(handle, stepID: row.id)
            let kind: StepKind
            switch (row.kind, row.callee) {
                case ("goal", nil): kind = .goal
                case ("route_call", let callee?): kind = .routeCall(calledRouteID: callee, bindings: try bindings(handle, stepID: row.id))
                default: throw refuse("memory_route_steps", row.id, .unknownCode(column: "step_kind", code: row.kind))
            }
            steps.append(ProcedureStep(stepID: row.id, position: position, goalText: row.goal, bundleID: row.bundle, kind: kind,
                                       checks: checks, operations: operations))
        }
        let definition = RouteDefinition(routeID: routeID, name: route.name, supersedesRouteID: route.supersedes, createdAtMS: route.created,
                                         parameters: parameters, steps: steps)
        let state = RouteState(status: status, lastUsedMS: route.lastUsed, demotedAtMS: route.demoted, demotionCause: route.cause)
        do {
            try definition.validate()
            try validate(state)
            if status == .active, let problem = definition.publicationProblem { throw RouteError.invalidDefinition(problem) }
        } catch RouteError.invalidDefinition(let invalidity) {
            throw refuse("memory_routes", routeID, .invalid(invalidity))
        }
        do {
            try checkCallRelations(handle, definition, status: status)
        } catch RouteError.invalidDefinition(let invalidity) {
            throw refuse("memory_route_call_bindings", Self.stepID(of: invalidity) ?? routeID, .invalid(invalidity))
        } catch RouteError.unpublishable(_, let reason) {
            throw refuse("memory_route_call_bindings", Self.stepID(of: reason) ?? routeID, .invalid(reason))
        }
        return StoredRoute(definition: definition, state: state)
    }

    /// The call step a refusal of its bindings names.
    private static func stepID(of invalidity: RouteError.Invalidity) -> String? {
        switch invalidity {
            case .binding(let stepID, _, _), .missingBinding(let stepID, _): stepID
            default: nil
        }
    }

    private static func checks(_ handle: some SQLiteQuerying, stepID: String) throws -> [StepCheck] {
        try handle.query(
            """
            SELECT check_id, position, check_kind, expected_scene_id, expected_anchor_id, expected_state, expected_text, expected_integer,
                   expected_real, expected_bool, expected_parameter_id, comparison
            FROM memory_step_checks WHERE step_id = ? ORDER BY position
            """,
            [.text(stepID)]
        ) { row in
            let id = try row.text(0) ?? ""
            func refuse(_ column: String, _ value: String) -> RouteError {
                .malformedRow(table: "memory_step_checks", id: id, malformation: .unknownCode(column: column, code: value))
            }
            let kindCode = try row.text(2) ?? ""
            guard let kind = code(StepCheckKind.self, kindCode) else { throw refuse("check_kind", kindCode) }
            var expected: CheckExpectation?
            if let state = try row.text(5) {
                guard let value = code(ControlState.self, state) else { throw refuse("expected_state", state) }
                expected = .state(value)
            } else if let text = try row.text(6) {
                expected = .text(text)
            } else if let value = row.integer(7) {
                expected = .integer(value)
            } else if let value = row.real(8) {
                expected = .real(value)
            } else if let value = row.integer(9) {
                expected = .boolean(value == 1)
            } else if let parameter = try row.text(10) {
                expected = .parameter(parameter)
            }
            var comparison: CheckComparison?
            if let raw = try row.text(11) {
                guard let value = code(CheckComparison.self, raw) else { throw refuse("comparison", raw) }
                comparison = value
            }
            guard let position = Int(exactly: row.integer(1) ?? -1) else { throw refuse("position", id) }
            return StepCheck(checkID: id, position: position, kind: kind, sceneID: try row.text(3), anchorID: try row.text(4),
                             expected: expected, comparison: comparison)
        }
    }

    private static func operations(_ handle: some SQLiteQuerying, stepID: String) throws -> [StepOperation] {
        let rows = try handle.query(
            "SELECT operation_id, parent_operation_id, position, tool_kind, contract_version FROM memory_step_operations WHERE step_id = ? ORDER BY position, operation_id",
            [.text(stepID)]
        ) { (id: try $0.text(0) ?? "", parent: try $0.text(1), position: $0.integer(2) ?? -1, tool: try $0.text(3) ?? "", version: $0.integer(4) ?? 0) }
        func build(_ row: (id: String, parent: String?, position: Int64, tool: String, version: Int64), children: [StepOperation]) throws -> StepOperation {
            guard row.version == Int64(AgentCallContract.version) else {
                throw RouteError.malformedRow(table: "memory_step_operations", id: row.id, malformation: .unsupportedContractVersion(row.version))
            }
            guard let tool = code(AgentTool.self, row.tool) else {
                throw RouteError.malformedRow(table: "memory_step_operations", id: row.id, malformation: .unknownCode(column: "tool_kind", code: row.tool))
            }
            guard let position = Int(exactly: row.position) else {
                throw RouteError.malformedRow(table: "memory_step_operations", id: row.id, malformation: .invalid(.positions(of: "operations")))
            }
            return StepOperation(operationID: row.id, position: position, tool: tool, arguments: try arguments(handle, operationID: row.id),
                                 children: children)
        }
        let known = Set(rows.map { Array($0.id.utf8) })
        for row in rows {
            if let parent = row.parent, !known.contains(Array(parent.utf8)) {
                throw RouteError.malformedRow(table: "memory_step_operations", id: row.id, malformation: .invalid(.batchChildren(operationID: parent)))
            }
        }
        return try rows.filter { $0.parent == nil }.map { top in
            let children = try rows.filter { $0.parent.map { Array($0.utf8) } == Array(top.id.utf8) }.map { try build($0, children: []) }
            // A child's own children would have no place in a definition: the validation refuses them.
            if rows.contains(where: { row in row.parent.map { p in children.contains { Array($0.operationID.utf8) == Array(p.utf8) } } == true }) {
                throw RouteError.malformedRow(table: "memory_step_operations", id: top.id, malformation: .invalid(.batchChildren(operationID: top.id)))
            }
            return try build(top, children: children)
        }
    }

    private static func arguments(_ handle: some SQLiteQuerying, operationID: String) throws -> [OperationArgument] {
        try handle.query(
            """
            SELECT argument_name, position, value_kind, text_value, integer_value, real_value, boolean_value, parameter_id, anchor_id,
                   menu_command_id, event_id, brain_application_id
            FROM memory_operation_arguments WHERE operation_id = ? ORDER BY argument_id
            """,
            [.text(operationID)]
        ) { row in
            let name = try row.text(0) ?? ""
            func refuse(_ malformation: RouteError.Malformation) -> RouteError {
                .malformedRow(table: "memory_operation_arguments", id: "\(operationID):\(name)", malformation: malformation)
            }
            for (index, column) in [(10, "event_id"), (11, "brain_application_id")] where !row.isNull(index) { throw refuse(.forbiddenColumn(column)) }
            let kind = try row.text(2) ?? ""
            let value: OperationValue
            switch kind {
                case "text"     : value = .literal(.text(try row.text(3) ?? ""))
                case "integer"  : value = .literal(.integer(row.integer(4) ?? 0))
                case "real"     : value = .literal(.real(row.real(5) ?? 0))
                case "boolean"  : value = .literal(.boolean(row.integer(6) == 1))
                case "parameter": value = .parameter(try row.text(7) ?? "")
                case "anchor"   : value = .anchor(try row.text(8) ?? "")
                case "menu"     : value = .menu(try row.text(9) ?? "")
                default         : throw refuse(.unknownCode(column: "value_kind", code: kind))
            }
            guard let position = Int(exactly: row.integer(1) ?? -1) else { throw refuse(.invalid(.positions(of: name))) }
            return OperationArgument(name: name, position: position, value: value)
        }
    }

    private static func bindings(_ handle: some SQLiteQuerying, stepID: String) throws -> [RouteCallBinding] {
        try handle.query(
            """
            SELECT called_parameter_id, source_parameter_id, literal_text, literal_integer, literal_real, literal_bool
            FROM memory_route_call_bindings WHERE step_id = ? ORDER BY called_parameter_id
            """,
            [.text(stepID)]
        ) { row in
            let called = try row.text(0) ?? ""
            let source: BindingSource
            if let parameter = try row.text(1) { source = .parameter(parameter) }
            else if let text = try row.text(2) { source = .literal(.text(text)) }
            else if let value = row.integer(3) { source = .literal(.integer(value)) }
            else if let value = row.real(4) { source = .literal(.real(value)) }
            else { source = .literal(.boolean(row.integer(5) == 1)) }
            return RouteCallBinding(calledParameterID: called, source: source)
        }
    }

    static func code<T: RawRepresentable>(_ type: T.Type, _ raw: String?) -> T? where T.RawValue == String {
        guard let raw, let value = T(rawValue: raw), value.rawValue.utf8.elementsEqual(raw.utf8) else { return nil }
        return value
    }
}
