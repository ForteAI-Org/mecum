//
//  RouteValidation.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import EngineCore
import PerceptionCore

extension RouteDefinition {

    /// The arguments that may name an anchor (a target the step's application shows) or a menu
    /// command (an item named by its leaf), by the call contract's names.
    public static let anchorArguments: Set<String> = ["target", "control", "from", "to"]
    public static let menuArguments: Set<String> = ["item"]

    /// Refuses a definition no store should keep, whatever its status: empty ids or texts, a repeated
    /// id or parameter name, positions that are not 0 ..< n in every ordered list, an instant out of
    /// the clock's range, a non-finite number, a reference to a parameter of no Route here or of the
    /// wrong type or direction, an argument its tool does not admit, a check of the wrong shape, a
    /// batch whose children are not batch steps, operations on a Route call, a call of itself.
    /// What only the store can check (callees, anchors, scenes, menus, another definition under an
    /// id) is checked there.
    public func validate() throws {
        func refuse(_ invalidity: RouteError.Invalidity) -> RouteError { .invalidDefinition(invalidity) }
        if routeID.isEmpty { throw refuse(.emptyID(field: "route_id")) }
        if name.isEmpty { throw refuse(.emptyText(field: "name")) }
        if let supersedesRouteID, supersedesRouteID.isEmpty || supersedesRouteID.utf8.elementsEqual(routeID.utf8) {
            throw refuse(.reference(kind: "supersedes", id: supersedesRouteID))
        }
        if !BrainClock.range.contains(createdAtMS) { throw refuse(.outOfRange(field: "created_at_ms")) }
        var ids = Set<[UInt8]>(), names = Set<[UInt8]>()
        func unique(_ id: String, _ field: String) throws {
            if id.isEmpty { throw refuse(.emptyID(field: field)) }
            guard ids.insert(Array(id.utf8)).inserted else { throw refuse(.repeatedID(id)) }
        }
        var byID: [[UInt8]: RouteParameter] = [:]
        for parameter in parameters {
            try unique(parameter.parameterID, "parameter_id")
            if parameter.name.isEmpty { throw refuse(.emptyText(field: "parameter name")) }
            guard names.insert(Array(parameter.name.utf8)).inserted else { throw refuse(.repeatedName(parameter.name)) }
            byID[Array(parameter.parameterID.utf8)] = parameter
        }
        func parameter(_ id: String) throws -> RouteParameter {
            guard let found = byID[Array(id.utf8)] else { throw refuse(.unknownParameter(id)) }
            return found
        }
        func contiguous(_ positions: [Int], _ list: String) throws {
            guard positions.enumerated().allSatisfy({ $0.offset == $0.element }) else { throw refuse(.positions(of: list)) }
        }
        try contiguous(steps.map(\.position), "steps")
        for step in steps {
            try unique(step.stepID, "step_id")
            if step.goalText.isEmpty { throw refuse(.emptyText(field: "goal_text")) }
            if let bundle = step.bundleID, bundle.isEmpty { throw refuse(.emptyText(field: "bundle_id")) }
            try contiguous(step.checks.map(\.position), "checks of \(step.stepID)")
            try contiguous(step.operations.map(\.position), "operations of \(step.stepID)")
            if case .routeCall(let callee, let bindings) = step.kind {
                if callee.isEmpty { throw refuse(.emptyID(field: "called_route_id")) }
                if callee.utf8.elementsEqual(routeID.utf8) { throw refuse(.selfCall(stepID: step.stepID)) }
                if !step.operations.isEmpty { throw refuse(.operationsOnRouteCall(stepID: step.stepID)) }
                var bound = Set<[UInt8]>()
                for binding in bindings {
                    guard !binding.calledParameterID.isEmpty, bound.insert(Array(binding.calledParameterID.utf8)).inserted else {
                        throw refuse(.binding(stepID: step.stepID, calledParameterID: binding.calledParameterID, problem: "repeated or empty"))
                    }
                    switch binding.source {
                        case .parameter(let id): _ = try parameter(id)
                        case .literal(.real(let value)) where !value.isFinite: throw refuse(.notFinite(field: "literal_real"))
                        case .literal: break
                    }
                }
            }
            for check in step.checks {
                try unique(check.checkID, "check_id")
                try Self.validate(check, in: step, parameter: parameter)
            }
            for operation in step.operations {
                try unique(operation.operationID, "operation_id")
                try Self.validate(operation, parameter: parameter, nested: false)
                try contiguous(operation.children.map(\.position), "children of \(operation.operationID)")
                for child in operation.children {
                    try unique(child.operationID, "operation_id")
                    try Self.validate(child, parameter: parameter, nested: true)
                }
            }
        }
    }

    /// Why this definition may not be active, as far as its own values tell, or nil: no step, a goal
    /// without a check, a batch without a step. A goal may have no operation when its result
    /// already holds. Callees and their bindings are the store's to check.
    public var publicationProblem: RouteError.Invalidity? {
        if steps.isEmpty { return .noSteps }
        for step in steps {
            if case .goal = step.kind, step.checks.isEmpty { return .goalWithoutCheck(stepID: step.stepID) }
            for operation in step.operations where operation.tool == .batch && operation.children.isEmpty {
                return .batchChildren(operationID: operation.operationID)
            }
        }
        return nil
    }

    private static func validate(_ check: StepCheck, in step: ProcedureStep,
                                 parameter: (String) throws -> RouteParameter) throws {
        func refuse(_ problem: String) -> RouteError { .invalidDefinition(.checkShape(checkID: check.checkID, problem: problem)) }
        if (check.sceneID != nil || check.anchorID != nil), step.bundleID == nil { throw refuse("a scene or an anchor needs the step's application") }
        if let scene = check.sceneID, scene.isEmpty { throw refuse("empty scene") }
        if let anchor = check.anchorID, anchor.isEmpty { throw refuse("empty anchor") }
        if case .real(let value)? = check.expected, !value.isFinite { throw RouteError.invalidDefinition(.notFinite(field: "expected_real")) }
        switch check.kind {
            case .scene:
                guard check.sceneID != nil, check.anchorID == nil, check.expected == nil, check.comparison == nil else { throw refuse("scene only") }
            case .anchor:
                guard check.anchorID != nil, check.sceneID == nil, check.comparison == nil else { throw refuse("an anchor, at most a state") }
                switch check.expected {
                    case nil: break
                    case .state(let state)? where state != .unknown: break
                    default: throw refuse("an anchor's expectation is a known state")
                }
            case .text:
                guard check.sceneID == nil, check.comparison != nil else { throw refuse("a text and a comparison") }
                switch check.expected {
                    case .text?: break
                    case .parameter(let id)?:
                        guard try parameter(id).valueType == .text else {
                            throw RouteError.invalidDefinition(.parameterType(parameterID: id))
                        }
                    default: throw refuse("a text or a text parameter")
                }
            case .value:
                guard check.anchorID != nil, check.sceneID == nil, check.comparison == nil else { throw refuse("an anchor and a value") }
                switch check.expected {
                    case .text?, .integer?, .real?, .boolean?: break
                    case .parameter(let id)?: _ = try parameter(id)
                    default: throw refuse("a typed value or a parameter")
                }
        }
    }

    private static func validate(_ operation: StepOperation, parameter: (String) throws -> RouteParameter, nested: Bool) throws {
        func refuse(_ problem: String) -> RouteError {
            .invalidDefinition(.argument(operationID: operation.operationID, problem: problem))
        }
        if nested {
            guard operation.tool.isBatchStep, operation.children.isEmpty else {
                throw RouteError.invalidDefinition(.batchChildren(operationID: operation.operationID))
            }
        } else if operation.tool != .batch, !operation.children.isEmpty {
            throw RouteError.invalidDefinition(.batchChildren(operationID: operation.operationID))
        }
        let specs = Dictionary(uniqueKeysWithValues: AgentCallArguments.specs(of: operation.tool).map { ($0.name, $0) })
        var positions: [String: Set<Int>] = [:]
        var literals: [BrainArgument] = []
        for argument in operation.arguments {
            guard let spec = specs[argument.name], spec.name.utf8.elementsEqual(argument.name.utf8) else { throw refuse("\(argument.name) is not an argument of \(operation.tool.rawValue)") }
            guard argument.position >= 0, positions[spec.name, default: []].insert(argument.position).inserted else {
                throw refuse("\(spec.name) repeated at \(argument.position)")
            }
            switch argument.value {
                case .literal(let value):
                    guard value.kind == spec.kind else { throw refuse("\(spec.name) is \(spec.kind.rawValue)") }
                    if case .real(let real) = value, !real.isFinite { throw RouteError.invalidDefinition(.notFinite(field: spec.name)) }
                    literals.append(BrainArgument(name: spec.name, position: argument.position, value: value))
                case .parameter(let id):
                    let found = try parameter(id)
                    guard found.valueType == ParameterValueType(spec.kind) else { throw RouteError.invalidDefinition(.parameterType(parameterID: id)) }
                    guard found.direction != .output else { throw RouteError.invalidDefinition(.parameterDirection(parameterID: id)) }
                case .anchor(let id):
                    guard spec.kind == .text, anchorArguments.contains(spec.name), !id.isEmpty else { throw refuse("\(spec.name) cannot name an anchor") }
                case .menu(let id):
                    guard spec.kind == .text, menuArguments.contains(spec.name), !id.isEmpty else { throw refuse("\(spec.name) cannot name a menu command") }
            }
        }
        for spec in specs.values {
            let held = positions[spec.name] ?? []
            switch spec.rows {
                case .one, .optional:
                    if spec.rows == .one, held.isEmpty { throw refuse("\(spec.name) is required") }
                    if !held.allSatisfy({ $0 == 0 }) { throw refuse("\(spec.name) is a scalar") }
                case .list:
                    if !held.allSatisfy({ (0..<held.count).contains($0) }) { throw refuse("\(spec.name) has a gap") }
            }
        }
        if literals.count == operation.arguments.count {
            // A literal call is checked by the call contract itself, codes and alternatives included.
            do {
                _ = try AgentCallRequest(tool: operation.tool, arguments: literals, eventID: operation.operationID)
            } catch AgentCallError.malformedCall(_, let malformation) {
                throw refuse("\(malformation)")
            }
            return
        }
        // With references, what can be checked before the values are given: literal codes, counts,
        // and the alternatives by presence. The rest is revalidated once the values are known.
        func literal(_ name: String) -> BrainArgument.Value? { literals.first { $0.name == name }?.value }
        func present(_ name: String) -> Bool { positions[name] != nil }
        for argument in literals {
            switch (argument.name, argument.value) {
                case ("verb", .text(let code)) where ActionVerb(rawValue: code)?.rawValue.utf8.elementsEqual(code.utf8) != true,
                     ("direction", .text(let code)) where AgentScrollDirection(rawValue: code)?.rawValue.utf8.elementsEqual(code.utf8) != true,
                     ("modifiers", .text(let code)) where AgentKeyModifier(rawValue: code)?.rawValue.utf8.elementsEqual(code.utf8) != true,
                     ("key", .text(let code)) where KeyChord.Name(code)?.word.utf8.elementsEqual(code.utf8) != true:
                    throw refuse("unknown code \(code) for \(argument.name)")
                case ("value", .text(let code)) where code != "on" && code != "off":
                    throw refuse("unknown code \(code) for value")
                case ("count", .integer(let count)) where count < 1, ("lines", .integer(let count)) where count < 1:
                    throw refuse("\(argument.name) below one")
                default:
                    break
            }
        }
        if operation.tool == .drag, present("to") == (present("dx") || present("dy")) || present("dx") != present("dy") {
            throw refuse("drag takes to, or dx and dy")
        }
        if operation.tool == .act, case .text(let verb)? = literal("verb"), (verb == ActionVerb.setToggle.rawValue) != present("value") {
            throw refuse("value goes with set_toggle only")
        }
    }

    // MARK: Exact comparison

    /// Parameters have no order of their own: the schema keeps them by id, and they are compared
    /// and read back sorted by id, as UTF-8 bytes.
    public static func sorted(_ parameters: [RouteParameter]) -> [RouteParameter] {
        parameters.sorted { Array($0.parameterID.utf8).lexicographicallyPrecedes(Array($1.parameterID.utf8)) }
    }

    /// Whether the other definition is this one exactly: every id, text and code byte for byte, every
    /// list in order, absent apart from empty, numbers as IEEE values.
    public func isExactly(_ other: RouteDefinition) -> Bool {
        func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
        func sameValue(_ a: BrainArgument.Value, _ b: BrainArgument.Value) -> Bool {
            BrainArgument.exactlyEqual([BrainArgument(name: "v", position: 0, value: a)], [BrainArgument(name: "v", position: 0, value: b)])
        }
        func sameExpectation(_ a: CheckExpectation?, _ b: CheckExpectation?) -> Bool {
            switch (a, b) {
                case (nil, nil): true
                case (.state(let x)?, .state(let y)?): x == y
                case (.text(let x)?, .text(let y)?), (.parameter(let x)?, .parameter(let y)?): same(x, y)
                case (.integer(let x)?, .integer(let y)?): x == y
                case (.real(let x)?, .real(let y)?): x == y
                case (.boolean(let x)?, .boolean(let y)?): x == y
                default: false
            }
        }
        func sameOperation(_ a: StepOperation, _ b: StepOperation) -> Bool {
            same(a.operationID, b.operationID) && a.position == b.position && a.tool == b.tool
                && a.arguments.count == b.arguments.count
                && zip(a.arguments, b.arguments).allSatisfy { x, y in
                    guard same(x.name, y.name), x.position == y.position else { return false }
                    switch (x.value, y.value) {
                        case (.literal(let p), .literal(let q)): return sameValue(p, q)
                        case (.parameter(let p), .parameter(let q)), (.anchor(let p), .anchor(let q)), (.menu(let p), .menu(let q)): return same(p, q)
                        default: return false
                    }
                }
                && a.children.count == b.children.count && zip(a.children, b.children).allSatisfy(sameOperation)
        }
        func sameStep(_ a: ProcedureStep, _ b: ProcedureStep) -> Bool {
            let kinds: Bool
            switch (a.kind, b.kind) {
                case (.goal, .goal): kinds = true
                case (.routeCall(let p, let x), .routeCall(let q, let y)):
                    // Bindings have no order of their own (the schema keys them by the called parameter).
                    let byID = { (list: [RouteCallBinding]) in list.sorted { Array($0.calledParameterID.utf8).lexicographicallyPrecedes(Array($1.calledParameterID.utf8)) } }
                    kinds = same(p, q) && x.count == y.count && zip(byID(x), byID(y)).allSatisfy { m, n in
                        guard same(m.calledParameterID, n.calledParameterID) else { return false }
                        switch (m.source, n.source) {
                            case (.parameter(let s), .parameter(let t)): return same(s, t)
                            case (.literal(let s), .literal(let t)): return sameValue(s, t)
                            default: return false
                        }
                    }
                default: kinds = false
            }
            return kinds && same(a.stepID, b.stepID) && a.position == b.position && same(a.goalText, b.goalText)
                && EventFactText.same(a.bundleID, b.bundleID)
                && a.checks.count == b.checks.count && zip(a.checks, b.checks).allSatisfy { x, y in
                    same(x.checkID, y.checkID) && x.position == y.position && x.kind == y.kind && EventFactText.same(x.sceneID, y.sceneID)
                        && EventFactText.same(x.anchorID, y.anchorID) && sameExpectation(x.expected, y.expected) && x.comparison == y.comparison
                }
                && a.operations.count == b.operations.count && zip(a.operations, b.operations).allSatisfy(sameOperation)
        }
        return same(routeID, other.routeID) && same(name, other.name) && EventFactText.same(supersedesRouteID, other.supersedesRouteID)
            && createdAtMS == other.createdAtMS
            && parameters.count == other.parameters.count && zip(Self.sorted(parameters), Self.sorted(other.parameters)).allSatisfy { x, y in
                same(x.parameterID, y.parameterID) && same(x.name, y.name) && x.direction == y.direction && x.valueType == y.valueType
                    && x.isRequired == y.isRequired
            }
            && steps.count == other.steps.count && zip(steps, other.steps).allSatisfy(sameStep)
    }
}
