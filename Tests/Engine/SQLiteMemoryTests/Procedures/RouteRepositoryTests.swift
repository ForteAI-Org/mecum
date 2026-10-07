//
//  RouteRepositoryTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import EngineCore
import Foundation
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// The procedure repository: definitions written whole and read back exactly after reopening, with
/// their rows checked on their own; applied once, conflicts and rollbacks with nothing left;
/// publication and state changes against the state last read; composition rules of Route calls.
@Suite("Procedures: definitions, state and composition", .serialized)
struct RouteRepositoryTests {

    private typealias F = ProcedureFixtures

    private static let literalRequests: [AgentCallRequest] = [
        .status, .windows(app: "Mail"), .apps(query: "mail"), .openSession(app: "Mail", window: "Inbox – Zoë"), .observe(full: false),
        .act(target: "Wi-Fi", verb: .setToggle, value: .off, section: "Rete"), .select(control: "Formato", item: "H.264"),
        .typeText(target: "To", text: "cafe\u{301}\u{0}|", section: nil, replace: true), .pressKey(key: .character("s"), modifiers: [.shift, .cmd], count: 2),
        .scroll(direction: .up, lines: 7, target: "List", section: nil), .drag(from: "A", to: .target("B"), section: nil),
        .contextMenu(target: "Paragraph", item: "Copia", section: nil), .closeSession,
    ]

    /// A Route of three steps in two applications and none: parametric Mail operations with an
    /// anchor, a menu command and parameters; a Notes check on an anchor; the literal signatures
    /// and a batch of the seven step variants in a step of no application.
    private func multiStep(_ memory: F.Memory, id: String = "r-multi") async throws -> RouteDefinition {
        let to = try await memory.anchor("To", in: F.mail), title = try await memory.anchor("Title", in: F.notes)
        let batch = StepOperation(operationID: "\(id).batch", position: Self.literalRequests.count, tool: .batch, children: [
            .act(target: "Send", verb: .click, value: nil, section: nil), .select(control: "Format", item: "H.264"),
            .typeText(target: "To", text: "x", section: nil, replace: false), .pressKey(key: .return, modifiers: [], count: 1),
            .scroll(direction: .down, lines: 3, target: nil, section: nil), .drag(from: "A", to: .offset(dx: -0.0, dy: 2), section: nil),
            .contextMenu(target: "P", item: "Copy", section: nil),
        ].enumerated().map { StepOperation(operationID: "\(id).batch.\($0.offset)", position: $0.offset, request: $0.element) })
        return RouteDefinition(routeID: id, name: "Rispondere", createdAtMS: F.t0, parameters: [F.message, F.recipient, F.sent], steps: [
            ProcedureStep(stepID: "\(id).s0", position: 0, goalText: "Il destinatario e il testo sono scritti", bundleID: F.mail,
                          checks: [StepCheck(checkID: "\(id).c0", position: 0, kind: .value, anchorID: to, expected: .parameter("p-recipient")),
                                   StepCheck(checkID: "\(id).c1", position: 1, kind: .scene, sceneID: "scene-compose")],
                          operations: [
                            StepOperation(operationID: "\(id).o0", position: 0, tool: .typeText, arguments: [
                                OperationArgument(name: "target", position: 0, value: .anchor(to)),
                                OperationArgument(name: "text", position: 0, value: .parameter("p-message")),
                                OperationArgument(name: "replace", position: 0, value: .literal(.boolean(false)))]),
                            StepOperation(operationID: "\(id).o1", position: 1, tool: .contextMenu, arguments: [
                                OperationArgument(name: "target", position: 0, value: .literal(.text("Body"))),
                                OperationArgument(name: "item", position: 0, value: .menu("m-copy"))]),
                          ]),
            ProcedureStep(stepID: "\(id).s1", position: 1, goalText: "La nota ha un titolo", bundleID: F.notes,
                          checks: [StepCheck(checkID: "\(id).c2", position: 0, kind: .anchor, anchorID: title, expected: .state(.on))]),
            ProcedureStep(stepID: "\(id).s2", position: 2, goalText: "Ogni firma è descritta", checks: [F.textCheck("\(id).c3", "fatto")],
                          operations: Self.literalRequests.enumerated().map { StepOperation(operationID: "\(id).l\($0.offset)", position: $0.offset, request: $0.element) } + [batch]),
        ])
    }

    @Test("a Route of one goal with one check and no operation is published and read back exactly after reopening; its rows are what was given")
    func oneGoal() async throws {
        let memory = try await F.open()
        let route = F.oneGoal()
        #expect(try await memory.routes.record(route, state: RouteState(status: .active)) == .committed)
        #expect(try await memory.texts("SELECT status || ' ' || coalesce(supersedes_route_id, 'NULL') FROM memory_routes") == ["active NULL"])
        #expect(try await memory.texts("SELECT step_kind || ' ' || coalesce(app_id, 'NULL') || ' ' || goal_text FROM memory_route_steps") == ["goal NULL Il messaggio risulta inviato"])
        #expect(try await memory.texts("SELECT check_kind || ' ' || expected_text || ' ' || comparison FROM memory_step_checks") == ["text Inviato contains"])
        #expect(try await memory.count("SELECT count(*) FROM memory_step_operations") == 0)
        await memory.store.close()
        let reopened = try await F.open(at: memory.url)
        let back = try #require(try await reopened.routes.route("r-one"))
        #expect(back.definition.isExactly(route) && back.state.isExactly(RouteState(status: .active)))
        #expect(try await reopened.routes.route("nothing") == nil)
        await reopened.store.close()
    }

    @Test("a Route over two applications and none keeps its parameters, steps, checks, the fourteen literal signatures, an ordered batch and typed references, read back exactly after reopening")
    func multiStepRoundTrip() async throws {
        let memory = try await F.prepared()
        let route = try await multiStep(memory)
        #expect(try await memory.routes.record(route, state: RouteState(status: .active)) == .committed)
        #expect(try await memory.texts("SELECT value_kind || ' ' || coalesce(parameter_id, anchor_id, menu_command_id) FROM memory_operation_arguments WHERE value_kind IN ('parameter', 'anchor', 'menu') ORDER BY argument_id")
                == ["anchor \(try await memory.anchor("To", in: F.mail))", "parameter p-message", "menu m-copy"])
        #expect(try await memory.count("SELECT count(*) FROM memory_step_operations WHERE parent_operation_id = 'r-multi.batch'") == 7)
        #expect(try await memory.count("SELECT count(*) FROM memory_step_operations WHERE app_id IS NULL") == Int64(Self.literalRequests.count + 8))
        #expect(try await memory.count("SELECT count(DISTINCT app_id) FROM memory_route_steps WHERE app_id IS NOT NULL") == 2)
        await memory.store.close()
        let reopened = try await F.open(at: memory.url)
        let back = try #require(try await reopened.routes.route("r-multi"))
        #expect(back.definition.isExactly(route), "every row rebuilt")
        let literal = back.definition.steps[2].operations
        for (operation, request) in zip(literal, Self.literalRequests) {
            let arguments = operation.arguments.map { argument -> BrainArgument in
                guard case .literal(let value) = argument.value else { return BrainArgument(name: "x", position: 0, value: .text("reference")) }
                return BrainArgument(name: argument.name, position: argument.position, value: value)
            }
            #expect(try AgentCallRequest(tool: operation.tool, arguments: arguments, eventID: operation.operationID).isExactly(request), Comment(rawValue: request.tool.rawValue))
        }
        #expect(literal.last?.children.map(\.tool) == [.act, .select, .typeText, .pressKey, .scroll, .drag, .contextMenu])
        await reopened.store.close()
    }

    @Test("the same definition is already applied whatever its state became; another one under the id is a conflict; a definition whose last reference is of another application is rolled back whole, and the store goes on")
    func retryConflictRollback() async throws {
        let memory = try await F.prepared()
        let route = try await multiStep(memory)
        _ = try await memory.routes.record(route, state: RouteState(status: .active))
        #expect(try await memory.routes.update("r-multi", from: RouteState(status: .active), to: RouteState(status: .active, lastUsedMS: F.t0 + 5)) == .committed)
        #expect(try await memory.routes.record(route, state: RouteState(status: .active)) == .alreadyApplied, "the state moved, the definition is the same")
        let before = try await memory.ledger()
        let renamed = RouteDefinition(routeID: route.routeID, name: "Rispondere ", createdAtMS: route.createdAtMS, parameters: route.parameters, steps: route.steps)
        let conflict = await storeError { _ = try await memory.routes.record(renamed, state: RouteState(status: .active)) }
        guard case .identity? = conflict else {
            Issue.record("expected a conflict, got \(String(describing: conflict))")
            return
        }
        let title = try await memory.anchor("Title", in: F.notes)
        let foreign = RouteDefinition(routeID: "r-foreign", name: "Altrove", createdAtMS: F.t0, steps: [
            F.oneGoal().steps[0],
            ProcedureStep(stepID: "r-foreign.s1", position: 1, goalText: "Scritto", bundleID: F.mail, checks: [F.textCheck("r-foreign.c1")],
                          operations: [StepOperation(operationID: "r-foreign.o0", position: 0, tool: .act, arguments: [
                            OperationArgument(name: "target", position: 0, value: .anchor(title)),
                            OperationArgument(name: "verb", position: 0, value: .literal(.text("click")))])]),
        ])
        #expect(await routeError { _ = try await memory.routes.record(foreign, state: RouteState(status: .draft)) }
                == .invalidDefinition(.reference(kind: "anchor", id: title)), "an anchor of Notes in a Mail step")
        #expect(try await memory.ledger() == before, "nothing of the refused definition remains")
        #expect(try await memory.routes.record(F.oneGoal(), state: RouteState(status: .draft)) == .committed)
        await memory.store.close()
    }

    @Test("a draft may be incomplete only in the declared ways; becoming active checks publication again; states move only forward against the state last read, never losing another writer's change")
    func publicationAndState() async throws {
        let memory = try await F.open()
        let empty = RouteDefinition(routeID: "r-empty", name: "Vuota", createdAtMS: F.t0)
        let unchecked = RouteDefinition(routeID: "r-unchecked", name: "Senza verifica", createdAtMS: F.t0,
                                        steps: [ProcedureStep(stepID: "u.s0", position: 0, goalText: "Fatto")])
        #expect(await routeError { _ = try await memory.routes.record(empty, state: RouteState(status: .active)) } == .unpublishable(routeID: "r-empty", reason: .noSteps))
        #expect(await routeError { _ = try await memory.routes.record(unchecked, state: RouteState(status: .active)) }
                == .unpublishable(routeID: "r-unchecked", reason: .goalWithoutCheck(stepID: "u.s0")))
        #expect(try await memory.routes.record(empty, state: RouteState(status: .draft)) == .committed)
        #expect(try await memory.routes.record(unchecked, state: RouteState(status: .draft)) == .committed)
        #expect(await routeError { _ = try await memory.routes.update("r-unchecked", from: RouteState(status: .draft), to: RouteState(status: .active)) }
                == .unpublishable(routeID: "r-unchecked", reason: .goalWithoutCheck(stepID: "u.s0")))
        _ = try await memory.routes.record(F.oneGoal(), state: RouteState(status: .draft))
        #expect(try await memory.routes.update("r-one", from: RouteState(status: .draft), to: RouteState(status: .active, lastUsedMS: F.t0)) == .committed)
        #expect(try await memory.routes.update("r-one", from: RouteState(status: .draft), to: RouteState(status: .active, lastUsedMS: F.t0)) == .alreadyApplied)
        #expect(await routeError { _ = try await memory.routes.update("r-one", from: RouteState(status: .draft), to: RouteState(status: .retired)) }
                == .staleExpectation(routeID: "r-one"))
        #expect(await routeError { _ = try await memory.routes.update("r-one", from: RouteState(status: .active, lastUsedMS: F.t0), to: RouteState(status: .draft, lastUsedMS: F.t0)) }
                == .invalidStateChange(routeID: "r-one", from: .active, to: .draft))
        #expect(await routeError { _ = try await memory.routes.update("r-one", from: RouteState(status: .active, lastUsedMS: F.t0), to: RouteState(status: .active, lastUsedMS: F.t0 - 1)) }
                == .invalidDefinition(.lastUsedBackwards))
        #expect(await routeError { _ = try await memory.routes.update("r-one", from: RouteState(status: .active, lastUsedMS: F.t0),
                                                                       to: RouteState(status: .active, lastUsedMS: F.t0, demotedAtMS: F.t0)) } == .invalidDefinition(.demotionHalf))
        let demoted = RouteState(status: .retired, lastUsedMS: F.t0, demotedAtMS: F.t0 + 9, demotionCause: "contraddetta")
        let second = try await F.open(at: memory.url)
        async let a = routeError { _ = try await memory.routes.update("r-one", from: RouteState(status: .active, lastUsedMS: F.t0), to: demoted) }
        async let b = routeError { _ = try await second.routes.update("r-one", from: RouteState(status: .active, lastUsedMS: F.t0), to: RouteState(status: .active, lastUsedMS: F.t0 + 3)) }
        let outcomes = await [a, b]
        #expect(outcomes.filter { $0 == nil }.count == 1 && outcomes.filter { $0 == .staleExpectation(routeID: "r-one") }.count == 1)
        #expect(await routeError { _ = try await memory.routes.update("r-none", from: RouteState(status: .draft), to: RouteState(status: .active)) } == .missingRoute(routeID: "r-none"))
        await second.store.close()
        await memory.store.close()
    }

    @Test("a Route call binds the called Route's parameters by direction and type: inputs from literals or readable parameters, outputs into writable ones, inouts both ways; required inputs bound and an active callee before publication")
    func composition() async throws {
        let memory = try await F.open()
        let calledIn = RouteParameter(parameterID: "k-in", name: "in", direction: .input, valueType: .text, isRequired: true)
        let calledOut = RouteParameter(parameterID: "k-out", name: "out", direction: .output, valueType: .boolean, isRequired: false)
        let calledIO = RouteParameter(parameterID: "k-io", name: "io", direction: .inout, valueType: .text, isRequired: false)
        let callee = RouteDefinition(routeID: "r-callee", name: "Chiamata", createdAtMS: F.t0, parameters: [calledIn, calledOut, calledIO],
                                     steps: F.oneGoal("r-callee").steps)
        _ = try await memory.routes.record(callee, state: RouteState(status: .draft))
        let own = [RouteParameter(parameterID: "c-in", name: "in", direction: .input, valueType: .text, isRequired: true),
                   RouteParameter(parameterID: "c-out", name: "out", direction: .output, valueType: .boolean, isRequired: false),
                   RouteParameter(parameterID: "c-io", name: "io", direction: .inout, valueType: .text, isRequired: false),
                   RouteParameter(parameterID: "c-num", name: "num", direction: .input, valueType: .integer, isRequired: false),
                   RouteParameter(parameterID: "c-said", name: "said", direction: .output, valueType: .text, isRequired: false)]
        func caller(_ id: String, _ bindings: [RouteCallBinding], callee: String = "r-callee") -> RouteDefinition {
            // Parameter ids are the file's: each caller has its own, the same names.
            let mine = own.map { RouteParameter(parameterID: "\(id).\($0.parameterID)", name: $0.name, direction: $0.direction, valueType: $0.valueType, isRequired: $0.isRequired) }
            let rebound = bindings.map { binding -> RouteCallBinding in
                guard case .parameter(let source) = binding.source else { return binding }
                return RouteCallBinding(calledParameterID: binding.calledParameterID, source: .parameter("\(id).\(source)"))
            }
            return RouteDefinition(routeID: id, name: "Chiamante", createdAtMS: F.t0, parameters: mine, steps: [
                ProcedureStep(stepID: "\(id).s0", position: 0, goalText: "La chiamata è conclusa", kind: .routeCall(calledRouteID: callee, bindings: rebound)),
            ])
        }
        let good = [RouteCallBinding(calledParameterID: "k-in", source: .parameter("c-in")), RouteCallBinding(calledParameterID: "k-out", source: .parameter("c-out")),
                    RouteCallBinding(calledParameterID: "k-io", source: .parameter("c-io"))]
        #expect(await routeError { _ = try await memory.routes.record(caller("r-a", good), state: RouteState(status: .active)) }
                == .unpublishable(routeID: "r-a", reason: .inactiveCallee(stepID: "r-a.s0")))
        _ = try await memory.routes.update("r-callee", from: RouteState(status: .draft), to: RouteState(status: .active))
        #expect(try await memory.routes.record(caller("r-a", good), state: RouteState(status: .active)) == .committed)
        #expect(try await memory.routes.record(caller("r-literal", [RouteCallBinding(calledParameterID: "k-in", source: .literal(.text("ciao")))]),
                                               state: RouteState(status: .active)) == .committed)
        let wrong: [(String, RouteCallBinding, String)] = [
            ("type", RouteCallBinding(calledParameterID: "k-in", source: .parameter("c-num")), "parameter of another type"),
            ("output as input", RouteCallBinding(calledParameterID: "k-in", source: .parameter("c-said")), "direction output"),
            ("literal output", RouteCallBinding(calledParameterID: "k-out", source: .literal(.boolean(true))), "a literal is no destination"),
            ("input into output", RouteCallBinding(calledParameterID: "k-io", source: .parameter("c-in")), "direction input"),
            ("literal type", RouteCallBinding(calledParameterID: "k-in", source: .literal(.integer(3))), "literal of another type"),
            ("unknown", RouteCallBinding(calledParameterID: "k-none", source: .literal(.text("x"))), "not a parameter of the called Route"),
        ]
        for (name, binding, problem) in wrong {
            #expect(await routeError { _ = try await memory.routes.record(caller("r-\(name)", [binding]), state: RouteState(status: .draft)) }
                    == .invalidDefinition(.binding(stepID: "r-\(name).s0", calledParameterID: binding.calledParameterID, problem: problem)), Comment(rawValue: name))
        }
        #expect(try await memory.routes.record(caller("r-unbound", []), state: RouteState(status: .draft)) == .committed, "a draft may lack a required binding")
        #expect(await routeError { _ = try await memory.routes.update("r-unbound", from: RouteState(status: .draft), to: RouteState(status: .active)) }
                == .unpublishable(routeID: "r-unbound", reason: .missingBinding(stepID: "r-unbound.s0", calledParameterID: "k-in")))
        #expect(await routeError { _ = try await memory.routes.record(caller("r-ghost", [], callee: "r-ghost-callee"), state: RouteState(status: .draft)) }
                == .missingRoute(routeID: "r-ghost-callee"))
        #expect(await routeError { _ = try await memory.routes.record(caller("r-self", [], callee: "r-self"), state: RouteState(status: .draft)) }
                == .invalidDefinition(.selfCall(stepID: "r-self.s0")))
        let back = try #require(try await memory.routes.route("r-a"))
        #expect(back.definition.isExactly(caller("r-a", good.reversed())), "bindings compare by the called parameter, whatever their order")
        let shared = RouteDefinition(routeID: "r-shared", name: "x", createdAtMS: F.t0, parameters: [RouteParameter(parameterID: "r-a.c-in", name: "in", direction: .input, valueType: .text, isRequired: false)])
        #expect(await routeError { _ = try await memory.routes.record(shared, state: RouteState(status: .draft)) } == .invalidDefinition(.repeatedID("r-a.c-in")),
                "a parameter id another Route holds is refused before any row")
        await memory.store.close()
    }

    @Test("a new version supersedes the old with new ids and leaves the old readable; a superseded Route that does not exist is refused")
    func versions() async throws {
        let memory = try await F.open()
        _ = try await memory.routes.record(F.oneGoal("r-v1"), state: RouteState(status: .active))
        let v2 = RouteDefinition(routeID: "r-v2", name: "Già inviato", supersedesRouteID: "r-v1", createdAtMS: F.t0 + 1, steps: [
            ProcedureStep(stepID: "r-v2.s0", position: 0, goalText: "Il messaggio risulta inviato", checks: [F.textCheck("r-v2.c0", "Inviato ✓")]),
        ])
        #expect(try await memory.routes.record(v2, state: RouteState(status: .active)) == .committed)
        _ = try await memory.routes.update("r-v1", from: RouteState(status: .active), to: RouteState(status: .retired))
        #expect(try await memory.routes.route("r-v1")?.definition.isExactly(F.oneGoal("r-v1")) == true)
        #expect(try await memory.routes.route("r-v2")?.definition.supersedesRouteID == "r-v1")
        let orphan = RouteDefinition(routeID: "r-v3", name: "x", supersedesRouteID: "r-v0", createdAtMS: F.t0, steps: [])
        #expect(await routeError { _ = try await memory.routes.record(orphan, state: RouteState(status: .draft)) } == .missingRoute(routeID: "r-v0"))
        await memory.store.close()
    }

    @Test("rows written by hand that a definition may not have are refused by the reader with a typed error: an unknown check or tool, an unsupported version, a gap in steps or operations, a huge position, an infinite number, a text that is not UTF-8, an active Route without a step")
    func malformedRows() async throws {
        let cases: [(String, String, RouteError.Malformation)] = [
            ("check", "UPDATE memory_step_checks SET check_kind = 'pixel'", .unknownCode(column: "check_kind", code: "pixel")),
            ("tool", "UPDATE memory_step_operations SET tool_kind = 'run_menu' WHERE operation_id = 'r-multi.l0'", .unknownCode(column: "tool_kind", code: "run_menu")),
            ("version", "UPDATE memory_step_operations SET contract_version = 2 WHERE operation_id = 'r-multi.l0'", .unsupportedContractVersion(2)),
            ("step gap", "UPDATE memory_route_steps SET position = 7 WHERE step_id = 'r-multi.s2'", .invalid(.positions(of: "steps"))),
            ("operation gap", "UPDATE memory_step_operations SET position = 40 WHERE operation_id = 'r-multi.l0'", .invalid(.positions(of: "operations of r-multi.s2"))),
            ("huge position", "UPDATE memory_route_steps SET position = 9223372036854775807 WHERE step_id = 'r-multi.s2'", .invalid(.positions(of: "steps"))),
            ("infinite literal", "UPDATE memory_operation_arguments SET real_value = 9e999 WHERE value_kind = 'real'", .invalid(.notFinite(field: "dx"))),
        ]
        for (name, sql, malformation) in cases {
            let memory = try await F.prepared()
            _ = try await memory.routes.record(try await multiStep(memory), state: RouteState(status: .active))
            try await memory.plant(sql)
            let error = await routeError { _ = try await memory.routes.route("r-multi") }
            switch (error, malformation) {
                case (.malformedRow(_, _, let found)?, _) where found == malformation: break
                default: Issue.record("\(name): expected \(malformation), got \(String(describing: error))")
            }
            #expect(try await memory.routes.record(F.oneGoal(), state: RouteState(status: .draft)) == .committed, "the store goes on")
            await memory.store.close()
        }
        let memory = try await F.open()
        try await memory.plant("INSERT INTO memory_routes (route_id, name, status, created_at_ms) VALUES ('r-hollow', 'x', 'active', 0)")
        #expect(await routeError { _ = try await memory.routes.route("r-hollow") } == .malformedRow(table: "memory_routes", id: "r-hollow", malformation: .invalid(.noSteps)))
        _ = try await memory.routes.record(F.oneGoal(), state: RouteState(status: .draft))
        try await memory.plant("UPDATE memory_route_steps SET goal_text = CAST(x'6162ff' AS TEXT) WHERE route_id = 'r-one'")
        guard case .malformedText? = await storeError({ _ = try await memory.routes.route("r-one") }) else {
            Issue.record("a goal that is not UTF-8 must be refused as malformed text")
            return
        }
        await memory.store.close()
    }
}
