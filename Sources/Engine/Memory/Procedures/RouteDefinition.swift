//
//  RouteDefinition.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import EngineCore
import PerceptionCore

/// RouteStatus is a definition's standing: a `draft` may be incomplete in the declared ways, an
/// `active` one passed the structural publication check, a `retired` one is kept for its evidence.
/// None of them says the procedure works; publication authorizes no replay.
public enum RouteStatus: String, Sendable, Equatable, Hashable, CaseIterable {
    case draft, active, retired
}

/// ParameterDirection and ParameterValueType are a parameter's direction and its value's type.
public enum ParameterDirection: String, Sendable, Equatable, Hashable, CaseIterable {
    case input, output
    case `inout`
}

public enum ParameterValueType: String, Sendable, Equatable, Hashable, CaseIterable {
    case text, integer, real, boolean

    public init(_ kind: BrainArgument.Kind) {
        switch kind {
            case .text   : self = .text
            case .integer: self = .integer
            case .real   : self = .real
            case .boolean: self = .boolean
        }
    }
}

/// RouteParameter is one parameter of a Route: an id (never its name), the name a caller reads,
/// its direction, its value's type and whether a caller must supply it.
public struct RouteParameter: Sendable {
    public let parameterID: String
    public let name: String
    public let direction: ParameterDirection
    public let valueType: ParameterValueType
    public let isRequired: Bool

    public init(parameterID: String, name: String, direction: ParameterDirection, valueType: ParameterValueType, isRequired: Bool) {
        self.parameterID = parameterID
        self.name        = name
        self.direction   = direction
        self.valueType   = valueType
        self.isRequired  = isRequired
    }
}

/// OperationValue is one argument's value in a definition: a literal, or an explicit reference to a
/// parameter of the same Route, to an anchor or to a menu command of the step's application. A
/// reference is not a resolved live target and not an ephemeral element id.
public enum OperationValue: Sendable {
    case literal(BrainArgument.Value)
    case parameter(String)
    case anchor(String)
    case menu(String)
}

/// OperationArgument is one argument row of an operation, under the call contract's names.
public struct OperationArgument: Sendable {
    public let name: String
    public let position: Int
    public let value: OperationValue

    public init(name: String, position: Int, value: OperationValue) {
        self.name     = name
        self.position = position
        self.value    = value
    }
}

/// StepOperation is the definition of one call: one of the app's fourteen tools under
/// `AgentCallContract`'s version, its arguments, and for a batch its ordered child operations, each
/// an `act`, a `select` or one of the five inputs. It is a shape to revalidate once its references
/// have values, not a call ready to run.
public struct StepOperation: Sendable {
    public let operationID: String
    public let position: Int
    public let tool: AgentTool
    public let arguments: [OperationArgument]
    public let children: [StepOperation]

    public init(operationID: String, position: Int, tool: AgentTool, arguments: [OperationArgument] = [], children: [StepOperation] = []) {
        self.operationID = operationID
        self.position    = position
        self.tool        = tool
        self.arguments   = arguments
        self.children    = children
    }

    /// The operation of a literal call: the request's own arguments.
    public init(operationID: String, position: Int, request: AgentCallRequest, children: [StepOperation] = []) {
        self.init(operationID: operationID, position: position, tool: request.tool,
                  arguments: request.arguments.map { OperationArgument(name: $0.name, position: $0.position, value: .literal($0.value)) },
                  children: children)
    }
}

/// StepCheckKind is what a check compares, this contract's minimal vocabulary over the columns:
/// `scene` (the step ends on a structural scene), `anchor` (an anchor is present, in a state when
/// one is given), `text` (a text, literal or a text parameter, `equals` or `contains` what is read,
/// in an anchor when one is given), `value` (an anchor's value equals a typed literal or a parameter).
/// No verifier runs here.
public enum StepCheckKind: String, Sendable, Equatable, Hashable, CaseIterable {
    case scene, anchor, text, value
}

public enum CheckComparison: String, Sendable, Equatable, Hashable, CaseIterable {
    case equals, contains
}

public enum CheckExpectation: Sendable {
    case state(ControlState)
    case text(String)
    case integer(Int64)
    case real(Double)
    case boolean(Bool)
    case parameter(String)
}

public struct StepCheck: Sendable {
    public let checkID: String
    public let position: Int
    public let kind: StepCheckKind
    public let sceneID: String?
    public let anchorID: String?
    public let expected: CheckExpectation?
    public let comparison: CheckComparison?

    public init(checkID: String, position: Int, kind: StepCheckKind, sceneID: String? = nil, anchorID: String? = nil,
                expected: CheckExpectation? = nil, comparison: CheckComparison? = nil) {
        self.checkID    = checkID
        self.position   = position
        self.kind       = kind
        self.sceneID    = sceneID
        self.anchorID   = anchorID
        self.expected   = expected
        self.comparison = comparison
    }
}

/// BindingSource is what a Route call gives one of the called Route's parameters: a parameter of the
/// calling Route, or a typed literal.
public enum BindingSource: Sendable {
    case parameter(String)
    case literal(BrainArgument.Value)
}

public struct RouteCallBinding: Sendable {
    public let calledParameterID: String
    public let source: BindingSource

    public init(calledParameterID: String, source: BindingSource) {
        self.calledParameterID = calledParameterID
        self.source            = source
    }
}

/// StepKind is a step's kind: a goal, reached by the step's own operations (possibly none when it
/// already holds), or a call of another Route, with its bindings and no operations of its own.
public enum StepKind: Sendable {
    case goal
    case routeCall(calledRouteID: String, bindings: [RouteCallBinding])
}

/// ProcedureStep is one verifiable result: its goal text describes the result expected, also for a call;
/// the actions are its operations, never words in the goal. Its application is optional, and its
/// checks and operations belong to it.
public struct ProcedureStep: Sendable {
    public let stepID: String
    public let position: Int
    public let goalText: String
    public let bundleID: String?
    public let kind: StepKind
    public let checks: [StepCheck]
    public let operations: [StepOperation]

    public init(stepID: String, position: Int, goalText: String, bundleID: String? = nil, kind: StepKind = .goal,
                checks: [StepCheck] = [], operations: [StepOperation] = []) {
        self.stepID     = stepID
        self.position   = position
        self.goalText   = goalText
        self.bundleID   = bundleID
        self.kind       = kind
        self.checks     = checks
        self.operations = operations
    }
}

/// RouteDefinition is the immutable part of a procedure: its id, its name (never an identity), the
/// definition it supersedes, its creation instant, its parameters and its ordered steps. Changing a
/// step of a published definition is a new definition with a new id and new child ids, superseding
/// the old one, whose evidence stays where it is. Compared with `isExactly(_:)`.
public struct RouteDefinition: Sendable {
    public let routeID: String
    public let name: String
    public let supersedesRouteID: String?
    public let createdAtMS: Int64
    public let parameters: [RouteParameter]
    public let steps: [ProcedureStep]

    public init(routeID: String, name: String, supersedesRouteID: String? = nil, createdAtMS: Int64,
                parameters: [RouteParameter] = [], steps: [ProcedureStep] = []) {
        self.routeID           = routeID
        self.name              = name
        self.supersedesRouteID = supersedesRouteID
        self.createdAtMS       = createdAtMS
        self.parameters        = parameters
        self.steps             = steps
    }
}

/// RouteState is what may change of a definition, deliberately, against the state last read: its
/// status (draft → active, draft → retired, active → retired), its last use (never earlier) and a
/// demotion (instant and cause together).
public struct RouteState: Sendable, Equatable {
    public let status: RouteStatus
    public let lastUsedMS: Int64?
    public let demotedAtMS: Int64?
    public let demotionCause: String?

    public init(status: RouteStatus, lastUsedMS: Int64? = nil, demotedAtMS: Int64? = nil, demotionCause: String? = nil) {
        self.status        = status
        self.lastUsedMS    = lastUsedMS
        self.demotedAtMS   = demotedAtMS
        self.demotionCause = demotionCause
    }

    public func isExactly(_ other: RouteState) -> Bool {
        status == other.status && lastUsedMS == other.lastUsedMS && demotedAtMS == other.demotedAtMS
            && EventFactText.same(demotionCause, other.demotionCause)
    }
}

public struct StoredRoute: Sendable {
    public let definition: RouteDefinition
    public let state: RouteState

    public init(definition: RouteDefinition, state: RouteState) {
        self.definition = definition
        self.state      = state
    }
}

/// RouteError is a definition the store refuses to write, a state it refuses to reach, or a stored
/// definition it refuses to read.
public enum RouteError: Error, Sendable, Equatable {
    case invalidDefinition(Invalidity)
    case unpublishable(routeID: String, reason: Invalidity)
    case missingRoute(routeID: String)
    case invalidStateChange(routeID: String, from: RouteStatus, to: RouteStatus)
    case staleExpectation(routeID: String)
    case malformedRow(table: String, id: String, malformation: Malformation)

    public enum Invalidity: Sendable, Equatable {
        case emptyID(field: String)
        case emptyText(field: String)
        case repeatedID(String)
        case repeatedName(String)
        case positions(of: String)
        case outOfRange(field: String)
        case notFinite(field: String)
        case unknownParameter(String)
        case parameterType(parameterID: String)
        case parameterDirection(parameterID: String)
        case argument(operationID: String, problem: String)
        case reference(kind: String, id: String)
        case batchChildren(operationID: String)
        case operationsOnRouteCall(stepID: String)
        case checkShape(checkID: String, problem: String)
        case binding(stepID: String, calledParameterID: String, problem: String)
        case missingBinding(stepID: String, calledParameterID: String)
        case selfCall(stepID: String)
        case noSteps
        case goalWithoutCheck(stepID: String)
        case inactiveCallee(stepID: String)
        case lastUsedBackwards
        case demotionHalf
    }

    public enum Malformation: Sendable, Equatable {
        case unknownCode(column: String, code: String)
        case invalid(Invalidity)
        case unsupportedContractVersion(Int64)
        case forbiddenColumn(String)
    }
}
