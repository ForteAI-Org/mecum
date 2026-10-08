//
//  ProcedureContractTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import EngineCore
import Foundation
@testable import Memory
import PerceptionCore
import Testing

/// The procedure, occurrence, experience and arc contracts on their own: what a definition may hold
/// before any store, its publication rule, the argument templates over the fourteen signatures, and
/// the exact comparisons.
@Suite("Procedures, occurrences, experiences and arcs: the contracts")
struct ProcedureContractTests {

    static let text = RouteParameter(parameterID: "p-text", name: "message", direction: .input, valueType: .text, isRequired: true)
    static let flag = RouteParameter(parameterID: "p-flag", name: "replace", direction: .input, valueType: .boolean, isRequired: false)
    static let out  = RouteParameter(parameterID: "p-out", name: "result", direction: .output, valueType: .text, isRequired: false)

    static func check(_ id: String = "c1", position: Int = 0) -> StepCheck {
        StepCheck(checkID: id, position: position, kind: .text, expected: .text("Inviato"), comparison: .contains)
    }

    static func route(_ steps: [ProcedureStep], parameters: [RouteParameter] = [text, flag, out]) -> RouteDefinition {
        RouteDefinition(routeID: "r1", name: "Rispondere", createdAtMS: 1, parameters: parameters, steps: steps)
    }

    @Test("every literal signature is an operation the contract admits; a batch holds every step variant in order")
    func literalSignatures() throws {
        let requests: [AgentCallRequest] = [
            .status, .windows(app: "Mail"), .apps(query: nil), .openSession(app: "Mail", window: "Inbox"), .observe(full: false),
            .act(target: "Wi-Fi", verb: .setToggle, value: .on, section: nil), .select(control: "Format", item: "H.264"),
            .typeText(target: "To", text: "Zoë", section: nil, replace: false),
            .insertText(text: "Zoë", expectedValue: "Zoë"), .pressKey(key: .return, modifiers: [.cmd], count: 1),
            .scroll(direction: .down, lines: 3, target: nil, section: nil), .drag(from: "A", to: .offset(dx: 0, dy: 4), section: nil),
            .contextMenu(target: "P", item: "Copy", section: nil), .menu(path: "File > Save"),
            .press(button: "OK"), .closeSession,
        ]
        let operations = requests.enumerated().map { StepOperation(operationID: "o\($0.offset)", position: $0.offset, request: $0.element) }
        let children = requests.filter(\.tool.isBatchStep).enumerated().map { StepOperation(operationID: "b\($0.offset)", position: $0.offset, request: $0.element) }
        let batch = StepOperation(operationID: "o-batch", position: operations.count, tool: .batch, children: children)
        let definition = Self.route([ProcedureStep(stepID: "s1", position: 0, goalText: "Il messaggio è inviato", bundleID: "com.apple.mail",
                                                   checks: [Self.check()], operations: operations + [batch])])
        try definition.validate()
        #expect(definition.publicationProblem == nil)
        #expect(Set(requests.map(\.tool) + [.batch]) == Set(AgentTool.allCases))
        #expect(children.count == 8)
    }

    @Test("references are explicit and typed: a parameter of its type that the operation can read, an anchor for a target, a menu for an item; nothing else")
    func parametricOperations() throws {
        func step(_ arguments: [OperationArgument], tool: AgentTool = .typeText) -> ProcedureStep {
            ProcedureStep(stepID: "s1", position: 0, goalText: "Scritto", bundleID: "com.apple.mail", checks: [Self.check()],
                          operations: [StepOperation(operationID: "o1", position: 0, tool: tool, arguments: arguments)])
        }
        let good = step([OperationArgument(name: "target", position: 0, value: .anchor("anchor-to")),
                         OperationArgument(name: "text", position: 0, value: .parameter("p-text")),
                         OperationArgument(name: "replace", position: 0, value: .parameter("p-flag"))])
        try Self.route([good]).validate()
        try Self.route([step([OperationArgument(name: "target", position: 0, value: .literal(.text("P"))),
                              OperationArgument(name: "item", position: 0, value: .menu("menu-copy"))], tool: .contextMenu)]).validate()
        func refused(_ arguments: [OperationArgument], tool: AgentTool = .typeText, _ expected: RouteError.Invalidity) {
            #expect(throws: RouteError.invalidDefinition(expected)) { try Self.route([step(arguments, tool: tool)]).validate() }
        }
        let base: [OperationArgument] = [OperationArgument(name: "target", position: 0, value: .literal(.text("To"))),
                                         OperationArgument(name: "replace", position: 0, value: .literal(.boolean(true)))]
        refused(base + [OperationArgument(name: "text", position: 0, value: .parameter("p-flag"))], .parameterType(parameterID: "p-flag"))
        refused(base + [OperationArgument(name: "text", position: 0, value: .parameter("p-out"))], .parameterDirection(parameterID: "p-out"))
        refused(base + [OperationArgument(name: "text", position: 0, value: .parameter("p-elsewhere"))], .unknownParameter("p-elsewhere"))
        refused(base + [OperationArgument(name: "text", position: 0, value: .anchor("a"))], .argument(operationID: "o1", problem: "text cannot name an anchor"))
        refused([OperationArgument(name: "target", position: 0, value: .menu("m")), OperationArgument(name: "item", position: 0, value: .literal(.text("x")))],
                tool: .contextMenu, .argument(operationID: "o1", problem: "target cannot name a menu command"))
        refused([OperationArgument(name: "from", position: 0, value: .anchor("a")), OperationArgument(name: "dx", position: 0, value: .literal(.real(1)))],
                tool: .drag, .argument(operationID: "o1", problem: "drag takes to, or dx and dy"))
        refused([OperationArgument(name: "target", position: 0, value: .anchor("a")), OperationArgument(name: "verb", position: 0, value: .literal(.text("set_toggle")))],
                tool: .act, .argument(operationID: "o1", problem: "value goes with set_toggle only"))
        refused([OperationArgument(name: "target", position: 0, value: .anchor("a")), OperationArgument(name: "verb", position: 0, value: .literal(.text("tap")))],
                tool: .act, .argument(operationID: "o1", problem: "unknown code tap for verb"))
        refused([OperationArgument(name: "target", position: 0, value: .anchor("a")), OperationArgument(name: "text", position: 0, value: .parameter("p-text"))],
                .argument(operationID: "o1", problem: "replace is required"))
        refused([OperationArgument(name: "key", position: 0, value: .literal(.text("tab"))), OperationArgument(name: "modifiers", position: 1, value: .literal(.text("cmd"))),
                 OperationArgument(name: "count", position: 0, value: .literal(.integer(1)))], tool: .pressKey,
                .argument(operationID: "o1", problem: "modifiers has a gap"))
        refused(base + [OperationArgument(name: "text", position: 0, value: .literal(.real(.nan)))], .argument(operationID: "o1", problem: "text is text"))
    }

    @Test("a definition is refused before any store when its ids, positions, checks, batches or calls are not of a definition, and a draft's declared incompleteness stays visible as the reason it may not be active")
    func definitions() throws {
        func refused(_ definition: RouteDefinition, _ expected: RouteError.Invalidity) {
            #expect(throws: RouteError.invalidDefinition(expected)) { try definition.validate() }
        }
        let step = ProcedureStep(stepID: "s1", position: 0, goalText: "Fatto", checks: [Self.check()])
        refused(Self.route([ProcedureStep(stepID: "s1", position: 1, goalText: "Fatto", checks: [Self.check()])]), .positions(of: "steps"))
        refused(Self.route([step, ProcedureStep(stepID: "s1", position: 1, goalText: "Altro", checks: [Self.check("c2")])]), .repeatedID("s1"))
        refused(Self.route([step], parameters: [Self.text, RouteParameter(parameterID: "p2", name: "message", direction: .input, valueType: .text, isRequired: false)]),
                .repeatedName("message"))
        refused(Self.route([ProcedureStep(stepID: "s1", position: 0, goalText: "", checks: [Self.check()])]), .emptyText(field: "goal_text"))
        refused(Self.route([ProcedureStep(stepID: "s1", position: 0, goalText: "Fatto", checks: [StepCheck(checkID: "c1", position: 0, kind: .scene, sceneID: "scene-1")])]),
                .checkShape(checkID: "c1", problem: "a scene or an anchor needs the step's application"))
        refused(Self.route([ProcedureStep(stepID: "s1", position: 0, goalText: "Fatto", bundleID: "x", checks: [StepCheck(checkID: "c1", position: 0, kind: .text, expected: .text("a"))])]),
                .checkShape(checkID: "c1", problem: "a text and a comparison"))
        refused(Self.route([ProcedureStep(stepID: "s1", position: 0, goalText: "Fatto", bundleID: "x", checks: [StepCheck(checkID: "c1", position: 0, kind: .value, anchorID: "a",
                                                                                                                       expected: .real(.infinity))])]),
                .notFinite(field: "expected_real"))
        refused(Self.route([ProcedureStep(stepID: "s1", position: 0, goalText: "Chiama", kind: .routeCall(calledRouteID: "r1", bindings: []))]), .selfCall(stepID: "s1"))
        refused(Self.route([ProcedureStep(stepID: "s1", position: 0, goalText: "Chiama", kind: .routeCall(calledRouteID: "r2", bindings: []),
                                          operations: [StepOperation(operationID: "o1", position: 0, request: .observe(full: false))])]), .operationsOnRouteCall(stepID: "s1"))
        refused(Self.route([ProcedureStep(stepID: "s1", position: 0, goalText: "Fatto", checks: [Self.check()],
                                          operations: [StepOperation(operationID: "o1", position: 0, tool: .batch,
                                                                     children: [StepOperation(operationID: "o2", position: 0, request: .observe(full: false))])])]),
                .batchChildren(operationID: "o2"))
        #expect(Self.route([]).publicationProblem == .noSteps)
        #expect(Self.route([ProcedureStep(stepID: "s1", position: 0, goalText: "Fatto")]).publicationProblem == .goalWithoutCheck(stepID: "s1"))
        #expect(Self.route([ProcedureStep(stepID: "s1", position: 0, goalText: "Fatto", checks: [Self.check()])]).publicationProblem == nil,
                "a goal with a check and no operation: its result already holds")
    }

    @Test("definitions compare byte for byte, with parameters and bindings by id whatever their order; NUL and decomposed texts are other definitions")
    func exactDefinitions() throws {
        let step = ProcedureStep(stepID: "s1", position: 0, goalText: "Café", checks: [Self.check()])
        let base = Self.route([step])
        #expect(base.isExactly(Self.route([step], parameters: [Self.out, Self.text, Self.flag])))
        #expect(!base.isExactly(Self.route([ProcedureStep(stepID: "s1", position: 0, goalText: "Cafe\u{301}", checks: [Self.check()])])))
        #expect(!base.isExactly(Self.route([ProcedureStep(stepID: "s1", position: 0, goalText: "Café\u{0}", checks: [Self.check()])])))
        #expect(!base.isExactly(Self.route([ProcedureStep(stepID: "s1", position: 0, goalText: "Café", bundleID: "x", checks: [Self.check()])])))
    }

    @Test("experiences, bindings, evidence, memberships and arcs refuse what no store should keep")
    func records() throws {
        #expect(throws: EventFactError.invalidRecord(.emptyText(field: "slot_name"))) { _ = try ExperienceBinding(parameterID: "p", valueType: .text, source: .requestSlot("   ")) }
        #expect(throws: EventFactError.invalidRecord(.shape(field: "literal"))) { _ = try ExperienceBinding(parameterID: "p", valueType: .text, source: .literal(.integer(0))) }
        #expect(throws: EventFactError.invalidRecord(.notFinite)) { _ = try ExperienceBinding(parameterID: "p", valueType: .real, source: .literal(.real(.nan))) }
        let zero = try ExperienceBinding(parameterID: "p", valueType: .integer, source: .literal(.integer(0)))
        let one = try ExperienceBinding(parameterID: "p", valueType: .integer, source: .literal(.integer(1)))
        let a = try ExperienceRecord(experienceID: "x", phrase: "rispondi a Zoë", routeID: "r1", createdAtMS: 0, bindings: [zero])
        #expect(!a.isExactly(try ExperienceRecord(experienceID: "x", phrase: "rispondi a Zoë", routeID: "r1", createdAtMS: 0, bindings: [one])))
        #expect(!a.isExactly(try ExperienceRecord(experienceID: "x", phrase: "rispondi a Zoe\u{308}", routeID: "r1", createdAtMS: 0, bindings: [zero])))
        #expect(throws: EventFactError.invalidRecord(.outOfRange(field: "attempt_number"))) {
            _ = try StepMembership(stepOccurrenceID: "so", eventID: "e", position: 0, attemptNumber: -1, role: .action)
        }
        #expect(throws: EventFactError.invalidRecord(.emptyText(field: "assessed_by"))) {
            _ = try DefinitionEvidence(.route(routeID: "r", taskOccurrenceID: "t"), relation: .supports, assessedBy: "", assessedAtMS: 0)
        }
        let effect = try TransitionEffectRecord(effect: "menuOpened:Copia|Incolla")
        #expect(throws: EventFactError.invalidRecord(.outOfOrder(field: "last_seen_ms"))) {
            _ = try BrainArc(transitionID: "t", bundleID: "b", fromSceneID: "s", trigger: .menu(menuCommandID: "m"), effect: effect, status: .candidate,
                             evidenceCount: 0, firstSeenMS: 10, lastSeenMS: 9)
        }
        #expect(throws: EventFactError.invalidRecord(.outOfRange(field: "evidence_count"))) {
            _ = try BrainArc(transitionID: "t", bundleID: "b", fromSceneID: "s", trigger: .menu(menuCommandID: "m"), effect: effect, status: .candidate,
                             evidenceCount: -1, firstSeenMS: 0, lastSeenMS: 0)
        }
    }
}
