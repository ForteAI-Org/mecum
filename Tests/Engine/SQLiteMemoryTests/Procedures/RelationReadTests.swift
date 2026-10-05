//
//  RelationReadTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import EngineCore
import Foundation
import Memory
@testable import SQLiteMemory
import Testing

/// The readers of composed Routes and of experiences check the relations their writers check: a
/// binding agrees with the called Route's parameter in direction and type, an active caller binds
/// every required input, an experience binds every required parameter it may fill. Rows changed by
/// hand within the constraints are refused with a typed error, never read back as valid; a callee
/// retired later and a draft's declared incompleteness stay readable.
@Suite("Readers check the relations of calls and experiences", .serialized)
struct RelationReadTests {

    private typealias F = ProcedureFixtures

    private static let calledInput = RouteParameter(parameterID: "called-input", name: "input", direction: .input, valueType: .text, isRequired: true)
    private static let callerInput = RouteParameter(parameterID: "caller-in", name: "in", direction: .input, valueType: .text, isRequired: true)
    private static let callerOutput = RouteParameter(parameterID: "caller-out", name: "out", direction: .output, valueType: .text, isRequired: false)

    private static func caller(_ id: String, bindings: [RouteCallBinding], parameters: [RouteParameter] = []) -> RouteDefinition {
        RouteDefinition(routeID: id, name: "Caller", createdAtMS: F.t0, parameters: parameters, steps: [
            ProcedureStep(stepID: "\(id).s0", position: 0, goalText: "La Route chiamata ha ricevuto il testo", kind: .routeCall(calledRouteID: "callee", bindings: bindings)),
        ])
    }

    /// An active callee with one required text input, and an active caller that binds it to a literal.
    private func calls() async throws -> F.Memory {
        let memory = try await F.open()
        let callee = RouteDefinition(routeID: "callee", name: "Callee", createdAtMS: F.t0, parameters: [Self.calledInput], steps: F.oneGoal("callee").steps)
        _ = try await memory.routes.record(callee, state: RouteState(status: .active))
        _ = try await memory.routes.record(Self.caller("caller", bindings: [RouteCallBinding(calledParameterID: "called-input", source: .literal(.text("ciao")))]),
                                           state: RouteState(status: .active))
        return memory
    }

    @Test("a binding changed by hand to a literal of another type, or to a calling parameter of the wrong direction, is refused by the reader of the caller; the read writes nothing and the store goes on")
    func bindingTypeAndDirection() async throws {
        let memory = try await calls()
        #expect(await routeError { _ = try await memory.routes.record(Self.caller("bad", bindings: [RouteCallBinding(calledParameterID: "called-input", source: .literal(.integer(7)))]),
                                                                       state: RouteState(status: .active)) }
                == .invalidDefinition(.binding(stepID: "bad.s0", calledParameterID: "called-input", problem: "literal of another type")))
        try await memory.plant("UPDATE memory_route_call_bindings SET literal_text = NULL, literal_integer = 7 WHERE step_id = 'caller.s0'")
        let before = try await memory.ledger()
        #expect(await routeError { _ = try await memory.routes.route("caller") }
                == .malformedRow(table: "memory_route_call_bindings", id: "caller.s0",
                                 malformation: .invalid(.binding(stepID: "caller.s0", calledParameterID: "called-input", problem: "literal of another type"))))
        #expect(try await memory.ledger() == before, "a refused read writes nothing")
        #expect(await routeError { _ = try await memory.routes.record(Self.caller("caller", bindings: [RouteCallBinding(calledParameterID: "called-input", source: .literal(.text("ciao")))]),
                                                                       state: RouteState(status: .active)) }
                == .malformedRow(table: "memory_route_call_bindings", id: "caller.s0",
                                 malformation: .invalid(.binding(stepID: "caller.s0", calledParameterID: "called-input", problem: "literal of another type"))),
                "a retry reads the stored definition as the reader does")

        let routed = Self.caller("routed", bindings: [RouteCallBinding(calledParameterID: "called-input", source: .parameter("caller-in"))],
                                 parameters: [Self.callerInput, Self.callerOutput])
        #expect(try await memory.routes.record(routed, state: RouteState(status: .active)) == .committed)
        #expect(try await memory.routes.route("routed")?.definition.isExactly(routed) == true)
        try await memory.plant("UPDATE memory_route_call_bindings SET source_parameter_id = 'caller-out' WHERE step_id = 'routed.s0'")
        #expect(await routeError { _ = try await memory.routes.route("routed") }
                == .malformedRow(table: "memory_route_call_bindings", id: "routed.s0",
                                 malformation: .invalid(.binding(stepID: "routed.s0", calledParameterID: "called-input", problem: "direction output"))),
                "an output of the caller is no input available to the call")
        #expect(try await memory.routes.record(F.oneGoal("r-after"), state: RouteState(status: .active)) == .committed, "the store goes on")
        await memory.store.close()
    }

    @Test("an active caller whose required binding was deleted by hand is refused by its reader; a draft without it and an active caller whose callee was retired later stay readable")
    func requiredBinding() async throws {
        let memory = try await calls()
        #expect(await routeError { _ = try await memory.routes.record(Self.caller("bad", bindings: []), state: RouteState(status: .active)) }
                == .unpublishable(routeID: "bad", reason: .missingBinding(stepID: "bad.s0", calledParameterID: "called-input")))
        let draft = Self.caller("draft", bindings: [])
        #expect(try await memory.routes.record(draft, state: RouteState(status: .draft)) == .committed)
        #expect(try await memory.routes.route("draft")?.definition.isExactly(draft) == true, "a draft may lack a required binding")

        #expect(try await memory.routes.update("callee", from: RouteState(status: .active), to: RouteState(status: .retired)) == .committed)
        let stored = try #require(try await memory.routes.route("caller"))
        #expect(stored.state.status == .active, "a callee retired later does not break the caller's definition")
        #expect(await routeError { _ = try await memory.routes.update("draft", from: RouteState(status: .draft), to: RouteState(status: .active)) }
                == .unpublishable(routeID: "draft", reason: .inactiveCallee(stepID: "draft.s0")),
                "publication, unlike reading, still asks for an active callee")

        try await memory.plant("DELETE FROM memory_route_call_bindings WHERE step_id = 'caller.s0'")
        #expect(await routeError { _ = try await memory.routes.route("caller") }
                == .malformedRow(table: "memory_route_call_bindings", id: "caller.s0",
                                 malformation: .invalid(.missingBinding(stepID: "caller.s0", calledParameterID: "called-input"))))
        #expect(try await memory.routes.route("draft") != nil, "the draft is still read")
        await memory.store.close()
    }

    @Test("an experience whose required binding was deleted by hand, or bound to an output, is refused by every reader and by a retry; the store goes on")
    func experienceBindings() async throws {
        let memory = try await calls()
        let typed = RouteDefinition(routeID: "typed", name: "Typed", createdAtMS: F.t0, parameters: [Self.callerInput, Self.callerOutput], steps: F.oneGoal("typed").steps)
        _ = try await memory.routes.record(typed, state: RouteState(status: .active))
        let record = try ExperienceRecord(experienceID: "x", phrase: "saluta", routeID: "callee", createdAtMS: F.t0, bindings: [
            try ExperienceBinding(parameterID: "called-input", valueType: .text, source: .requestSlot("messaggio")),
        ])
        #expect(try await memory.experiences.record(record) == .committed)
        #expect(await factError { _ = try await memory.experiences.record(try ExperienceRecord(experienceID: "bad", phrase: "b", routeID: "callee", createdAtMS: F.t0)) }
                == .invalidRecord(.shape(field: "required called-input")))
        _ = try await memory.calls.record(try AttributionFixtures.agentCall("a1"))

        try await memory.plant("DELETE FROM memory_experience_bindings WHERE experience_id = 'x'")
        let missing = EventFactError.malformedRow(table: "memory_experience_bindings", id: "x", malformation: .invalid(.shape(field: "required called-input")))
        #expect(await factError { _ = try await memory.experiences.experience("x") } == missing)
        #expect(await factError { _ = try await memory.experiences.experiences(ofRoute: "callee") } == missing)
        #expect(await factError { _ = try await memory.experiences.experiences(phrase: "saluta") } == missing)
        #expect(await factError { _ = try await memory.experiences.record(record) } == missing, "a retry reads the stored record as the reader does")
        #expect(await factError { _ = try await memory.experiences.record(try ExperienceUse(experienceID: "x", eventID: "a1", verdict: .unknown)) } == missing)

        let filled = try ExperienceRecord(experienceID: "y", phrase: "scrivi", routeID: "typed", createdAtMS: F.t0, bindings: [
            try ExperienceBinding(parameterID: "caller-in", valueType: .text, source: .literal(.text("ciao"))),
        ])
        #expect(try await memory.experiences.record(filled) == .committed)
        try await memory.plant(
            """
            INSERT INTO memory_experience_bindings (experience_id, route_id, parameter_id, value_type, binding_kind, slot_name)
            VALUES ('y', 'typed', 'caller-out', 'text', 'request_slot', 'risultato')
            """)
        #expect(await factError { _ = try await memory.experiences.experience("y") }
                == .malformedRow(table: "memory_experience_bindings", id: "y", malformation: .invalid(.shape(field: "binding caller-out"))),
                "an output is no value an experience gives")
        #expect(try await memory.experiences.record(try ExperienceRecord(experienceID: "z", phrase: "saluta ancora", routeID: "callee", createdAtMS: F.t0, bindings: [
            try ExperienceBinding(parameterID: "called-input", valueType: .text, source: .literal(.text("ciao"))),
        ])) == .committed, "the store goes on")
        #expect(try await memory.experiences.experience("z") != nil)
        await memory.store.close()
    }
}
