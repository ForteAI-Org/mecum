//
//  OccurrenceExperienceTests.swift
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

/// Step occurrences with their assignments, memberships and evidence, and experiences with their
/// bindings and uses: written as stated, read back after reopening, retried without rewriting the
/// facts, refused on conflicts and on rows the contracts do not admit.
@Suite("Occurrences, evidence and experiences", .serialized)
struct OccurrenceExperienceTests {

    private typealias F = ProcedureFixtures
    private typealias A = AttributionFixtures

    /// The parameters of every binding type, for the experiences.
    private static let typed: [RouteParameter] = [
        RouteParameter(parameterID: "x-text", name: "testo", direction: .input, valueType: .text, isRequired: true),
        RouteParameter(parameterID: "x-int", name: "quante", direction: .input, valueType: .integer, isRequired: false),
        RouteParameter(parameterID: "x-real", name: "zoom", direction: .inout, valueType: .real, isRequired: false),
        RouteParameter(parameterID: "x-bool", name: "sostituire", direction: .input, valueType: .boolean, isRequired: false),
        RouteParameter(parameterID: "x-who", name: "persona", direction: .input, valueType: .text, isRequired: false),
        RouteParameter(parameterID: "x-doc", name: "documento", direction: .input, valueType: .text, isRequired: false),
        RouteParameter(parameterID: "x-out", name: "esito", direction: .output, valueType: .boolean, isRequired: false),
    ]

    private func typedRoute(_ memory: F.Memory) async throws {
        let route = RouteDefinition(routeID: "r-typed", name: "Scrivere", createdAtMS: F.t0, parameters: Self.typed, steps: F.oneGoal("r-typed").steps)
        _ = try await memory.routes.record(route, state: RouteState(status: .active))
    }

    @Test("from a Watcher input with no task to an experience and its uses: episode and label, step occurrence assigned to task and step, verification and membership together, explicit evidence, a superseding version that leaves the old evidence valid; facts retried after every attribution are not rewritten")
    func path() async throws {
        let memory = try await F.open()
        let route = F.oneGoal("r-v1")
        _ = try await memory.routes.record(route, state: RouteState(status: .active))
        _ = try await memory.inputs.record(try ObservedInputRecord(event: A.watcherEvent("w1", app: AppContextIdentity(bundleID: F.mail)), input: try A.click()))
        let episode = try TaskOccurrenceRecord(taskOccurrenceID: "t1", startedAtMS: F.t0, status: .observed)
        _ = try await memory.tasks.attribute(try TaskAttribution(occurrence: episode,
            memberships: [try TaskMembership(taskOccurrenceID: "t1", eventID: "w1", position: 0, role: .observation)],
            labels: [try TaskLabelRecord(labelID: "l1", taskOccurrenceID: "t1", label: "Rispondere a Zoë", assignedBy: "fixture", status: .candidate, assignedAtMS: F.t0)]))
        let occurrence = try StepOccurrenceRecord(stepOccurrenceID: "so1", startedAtMS: F.t0, status: .observed)
        #expect(try await memory.steps.record(occurrence) == .committed)
        #expect(try await memory.steps.assign("so1", toTask: "t1", step: "r-v1.s0", by: "fixture") == .committed)
        #expect(try await memory.steps.assign("so1", toTask: "t1", step: "r-v1.s0", by: "fixture") == .alreadyApplied)
        #expect(try await memory.steps.record(occurrence) == .alreadyApplied, "the assignment is not part of the fact")
        let verification = try VerificationRecord(event: A.verificationEvent("v1", app: AppContextIdentity(bundleID: F.mail)), scope: .step, method: .sceneText,
                                                  verdict: .passed, expectedText: "Inviato", observedText: "Inviato")
        _ = try await memory.verifications.record(verification)
        let membership = try StepMembership(stepOccurrenceID: "so1", eventID: "v1", position: 1, attemptNumber: 1, role: .verification)
        #expect(try await memory.steps.attribute(verification: "v1", to: membership) == .committed)
        #expect(try await memory.steps.attribute(verification: "v1", to: membership) == .alreadyApplied)
        #expect(try await memory.verifications.record(verification) == .alreadyApplied, "the verification fact is not rewritten")
        #expect(try await memory.steps.record(try StepMembership(stepOccurrenceID: "so1", eventID: "w1", position: 0, attemptNumber: nil, role: .observation)) == .committed)
        let stepEvidence = try DefinitionEvidence(.step(stepID: "r-v1.s0", stepOccurrenceID: "so1"), relation: .supports, assessedBy: "fixture", assessedAtMS: F.t0 + 10)
        let routeEvidence = try DefinitionEvidence(.route(routeID: "r-v1", taskOccurrenceID: "t1"), relation: .supports, assessedBy: "fixture", assessedAtMS: F.t0 + 10)
        #expect(try await memory.steps.record(stepEvidence) == .committed)
        #expect(try await memory.steps.record(routeEvidence) == .committed)
        #expect(try await memory.steps.record(routeEvidence) == .alreadyApplied)
        let v2 = RouteDefinition(routeID: "r-v2", name: route.name, supersedesRouteID: "r-v1", createdAtMS: F.t0 + 20,
                                 steps: [ProcedureStep(stepID: "r-v2.s0", position: 0, goalText: "Il messaggio risulta inviato", checks: [F.textCheck("r-v2.c0")])])
        _ = try await memory.routes.record(v2, state: RouteState(status: .active))
        _ = try await memory.routes.update("r-v1", from: RouteState(status: .active), to: RouteState(status: .retired))
        let experience = try ExperienceRecord(experienceID: "x1", phrase: "rispondi a Zoë", routeID: "r-v2", stepID: "r-v2.s0", createdAtMS: F.t0 + 30)
        #expect(try await memory.experiences.record(experience) == .committed)
        _ = try await memory.calls.record(try A.agentCall("a1", app: AppContextIdentity(bundleID: F.mail)))
        #expect(try await memory.experiences.record(try ExperienceUse(experienceID: "x1", eventID: "a1", verdict: .unknown)) == .committed)
        #expect(try await memory.experiences.record(try ExperienceUse(experienceID: "x1", eventID: "v1", verdict: .passed)) == .committed)
        await memory.store.close()

        let reopened = try await F.open(at: memory.url)
        let stored = try #require(try await reopened.steps.occurrence("so1"))
        #expect(stored.record.isExactly(occurrence) && stored.taskOccurrenceID == "t1" && stored.stepID == "r-v1.s0" && stored.assignedBy == "fixture")
        #expect(try await reopened.steps.memberships(of: "so1").map(\.role) == [.observation, .verification])
        #expect(try await reopened.steps.memberships(of: "so1").first?.attemptNumber == nil, "no attempt number is not zero")
        #expect(try await reopened.verifications.verification("v1")?.stepOccurrenceID == "so1")
        #expect(try await reopened.steps.evidence(ofStep: "r-v1.s0").count == 1, "the old version's evidence stays valid")
        #expect(try await reopened.steps.evidence(ofRoute: "r-v1").first?.isExactly(routeEvidence) == true)
        #expect(try await reopened.routes.route("r-v1")?.state.status == .retired)
        #expect(try await reopened.experiences.experience("x1")?.isExactly(experience) == true)
        #expect(try await reopened.experiences.useCounts(of: "x1") == ExperienceUseCounts(passed: 1, failed: 0, unknown: 1), "derived from the uses")
        #expect(try await reopened.tasks.labels(of: "t1").map(\.status) == [.candidate])
        await reopened.store.close()
    }

    @Test("an occurrence is assigned once and never reassigned silently; a second author cannot complete a partial assignment, whose provenance stays; evidence for a step needs the occurrence of that step; a verification membership needs the verification's attribution; conflicts write nothing")
    func occurrenceRefusals() async throws {
        let memory = try await F.open()
        _ = try await memory.routes.record(F.oneGoal("r-a"), state: RouteState(status: .active))
        _ = try await memory.routes.record(F.oneGoal("r-b"), state: RouteState(status: .active))
        _ = try await memory.tasks.record(try TaskOccurrenceRecord(taskOccurrenceID: "t1", startedAtMS: F.t0, status: .observed))
        let so = try StepOccurrenceRecord(stepOccurrenceID: "so1", startedAtMS: F.t0, status: .inProgress)
        _ = try await memory.steps.record(so)
        let error = await storeError { _ = try await memory.steps.record(try StepOccurrenceRecord(stepOccurrenceID: "so1", startedAtMS: F.t0, status: .completed)) }
        guard case .identity? = error else {
            Issue.record("another fact under the id must be a conflict, got \(String(describing: error))")
            return
        }
        #expect(await factError { _ = try await memory.steps.record(try DefinitionEvidence(.step(stepID: "r-a.s0", stepOccurrenceID: "so1"), relation: .supports,
                                                                                         assessedBy: "fixture", assessedAtMS: 0)) }
                == .occurrenceNotOfStep(stepOccurrenceID: "so1", stepID: "r-a.s0"))
        _ = try await memory.steps.assign("so1", toTask: nil, step: "r-a.s0", by: "fixture")
        #expect(await factError { _ = try await memory.steps.assign("so1", toTask: nil, step: "r-b.s0", by: "fixture") } == .alreadyAssigned(id: "so1"))
        #expect(await factError { _ = try await memory.steps.assign("so1", toTask: "t1", step: nil, by: "someone else") } == .alreadyAssigned(id: "so1"),
                "a second author may not complete a partial assignment: one assigned_by keeps one provenance")
        #expect(await factError { _ = try await memory.steps.assign("so1", toTask: nil, step: "r-a.s0", by: "someone else") } == .alreadyAssigned(id: "so1"),
                "nor repeat it under another name")
        let partial = try #require(try await memory.steps.occurrence("so1"))
        #expect(partial.stepID == "r-a.s0" && partial.taskOccurrenceID == nil && partial.assignedBy == "fixture", "the refusal leaves the first author's partial assignment as it was")
        #expect(try await memory.steps.assign("so1", toTask: "t1", step: nil, by: "fixture") == .committed, "the task assigned later, by the same author")
        #expect(try await memory.steps.assign("so1", toTask: "t1", step: "r-a.s0", by: "fixture") == .alreadyApplied)
        #expect(await factError { _ = try await memory.steps.assign("so1", toTask: "t9", step: nil, by: "fixture") } == .missingOccurrence(id: "t9"))
        #expect(await factError { _ = try await memory.steps.assign("so1", toTask: nil, step: "r-z.s0", by: "fixture") } == .missingDefinition(id: "r-z.s0"))
        #expect(try await memory.steps.update(from: so, to: try StepOccurrenceRecord(stepOccurrenceID: "so1", startedAtMS: F.t0, endedAtMS: F.t0 + 5, status: .completed)) == .committed)
        #expect(await factError { _ = try await memory.steps.update(from: so, to: try StepOccurrenceRecord(stepOccurrenceID: "so1", startedAtMS: F.t0, status: .failed)) }
                == .staleExpectation(id: "so1"))
        _ = try await memory.verifications.record(try VerificationRecord(event: A.verificationEvent("v1"), scope: .step, method: .person, verdict: .unknown))
        #expect(await factError { _ = try await memory.steps.record(try StepMembership(stepOccurrenceID: "so1", eventID: "v1", position: 0, role: .verification)) }
                == .wrongEvent(eventID: "v1", expected: "a verification attributed to this occurrence"))
        let evidence = try DefinitionEvidence(.step(stepID: "r-a.s0", stepOccurrenceID: "so1"), relation: .contradicts, assessedBy: "fixture", assessedAtMS: 1)
        _ = try await memory.steps.record(evidence)
        let other = await storeError { _ = try await memory.steps.record(try DefinitionEvidence(.step(stepID: "r-a.s0", stepOccurrenceID: "so1"), relation: .contradicts,
                                                                                             assessedBy: "another", assessedAtMS: 1)) }
        guard case .identity? = other else {
            Issue.record("the same key with another author must be a conflict, got \(String(describing: other))")
            return
        }
        #expect(try await memory.steps.record(try DefinitionEvidence(.step(stepID: "r-a.s0", stepOccurrenceID: "so1"), relation: .supports, assessedBy: "fixture",
                                                                       assessedAtMS: 2)) == .committed, "the other relation is another key")
        await memory.store.close()
    }

    @Test("an experience's bindings are literals of the four types or named slots; every required parameter it may fill is bound, with its type; an output, another Route's step or a missing parameter is refused; the phrase is found by its exact bytes; uses are idempotent; an infinite literal or an unknown version written by hand is refused")
    func experiences() async throws {
        let memory = try await F.open()
        try await typedRoute(memory)
        _ = try await memory.routes.record(F.oneGoal("r-other"), state: RouteState(status: .active))
        let bindings = [
            try ExperienceBinding(parameterID: "x-text", valueType: .text, source: .literal(.text("Ciao\u{0} cafe\u{301}"))),
            try ExperienceBinding(parameterID: "x-int", valueType: .integer, source: .literal(.integer(0))),
            try ExperienceBinding(parameterID: "x-real", valueType: .real, source: .literal(.real(-0.0))),
            try ExperienceBinding(parameterID: "x-bool", valueType: .boolean, source: .literal(.boolean(false))),
            try ExperienceBinding(parameterID: "x-who", valueType: .text, source: .requestSlot("destinatario")),
            try ExperienceBinding(parameterID: "x-doc", valueType: .text, source: .contextSlot("documento corrente")),
        ]
        let experience = try ExperienceRecord(experienceID: "x1", phrase: "scrivi a Zoë", routeID: "r-typed", createdAtMS: F.t0, bindings: bindings)
        #expect(try await memory.experiences.record(experience) == .committed)
        #expect(try await memory.experiences.record(experience) == .alreadyApplied)
        #expect(try await memory.texts("SELECT binding_kind || ' ' || coalesce(slot_name, '') || ' ' || typeof(literal_text) || typeof(literal_integer) || typeof(literal_real) || typeof(literal_boolean) FROM memory_experience_bindings ORDER BY parameter_id")
                == ["literal  nullnullnullinteger", "context_slot documento corrente nullnullnullnull", "literal  nullintegernullnull",
                    "literal  nullnullrealnull", "literal  textnullnullnull", "request_slot destinatario nullnullnullnull"])
        func refused(_ record: ExperienceRecord, _ expected: EventFactError) async {
            #expect(await factError { _ = try await memory.experiences.record(record) } == expected)
        }
        await refused(try ExperienceRecord(experienceID: "x2", phrase: "p", routeID: "r-typed", createdAtMS: 0), .invalidRecord(.shape(field: "required x-text")))
        await refused(try ExperienceRecord(experienceID: "x3", phrase: "p", routeID: "r-typed", createdAtMS: 0, bindings: [bindings[0],
                      try ExperienceBinding(parameterID: "x-out", valueType: .boolean, source: .literal(.boolean(true)))]), .invalidRecord(.shape(field: "binding x-out")))
        await refused(try ExperienceRecord(experienceID: "x4", phrase: "p", routeID: "r-typed", createdAtMS: 0, bindings: [
                      try ExperienceBinding(parameterID: "x-text", valueType: .integer, source: .literal(.integer(1)))]), .invalidRecord(.shape(field: "binding x-text")))
        await refused(try ExperienceRecord(experienceID: "x5", phrase: "p", routeID: "r-typed", stepID: "r-other.s0", createdAtMS: 0, bindings: [bindings[0]]),
                      .missingDefinition(id: "r-other.s0"))
        await refused(try ExperienceRecord(experienceID: "x6", phrase: "p", routeID: "r-typed", createdAtMS: 0, bindings: [bindings[0],
                      try ExperienceBinding(parameterID: "x-none", valueType: .text, source: .requestSlot("s"))]), .missingDefinition(id: "x-none"))
        let changed = await storeError { _ = try await memory.experiences.record(try ExperienceRecord(experienceID: "x1", phrase: "scrivi a Zoe\u{308}", routeID: "r-typed",
                                                                                                    createdAtMS: F.t0, bindings: bindings)) }
        guard case .identity? = changed else {
            Issue.record("another phrase under the id must be a conflict, got \(String(describing: changed))")
            return
        }
        #expect(try await memory.experiences.experiences(phrase: "scrivi a Zoë").map(\.experienceID) == ["x1"])
        #expect(try await memory.experiences.experiences(phrase: "scrivi a Zoe\u{308}").isEmpty, "the decomposed phrase is other bytes")
        #expect(try await memory.experiences.experiences(ofRoute: "r-typed").count == 1)
        _ = try await memory.calls.record(try A.agentCall("a1"))
        #expect(try await memory.experiences.record(try ExperienceUse(experienceID: "x1", eventID: "a1", verdict: .failed)) == .committed)
        #expect(try await memory.experiences.record(try ExperienceUse(experienceID: "x1", eventID: "a1", verdict: .failed)) == .alreadyApplied)
        let flipped = await storeError { _ = try await memory.experiences.record(try ExperienceUse(experienceID: "x1", eventID: "a1", verdict: .passed)) }
        guard case .identity? = flipped else {
            Issue.record("another verdict for the same use must be a conflict, got \(String(describing: flipped))")
            return
        }
        #expect(try await memory.experiences.useCounts(of: "x1") == ExperienceUseCounts(passed: 0, failed: 1, unknown: 0))
        #expect(await factError { _ = try await memory.experiences.record(try ExperienceUse(experienceID: "x1", eventID: "nobody", verdict: .unknown)) } == .missingEvent(eventID: "nobody"))
        try await memory.plant("UPDATE memory_experience_bindings SET literal_real = 9e999 WHERE parameter_id = 'x-real'")
        #expect(await factError { _ = try await memory.experiences.experience("x1") }
                == .malformedRow(table: "memory_experience_bindings", id: "x1", malformation: .invalid(.notFinite)), "an infinite literal is not a value")
        try await memory.plant("UPDATE memory_experience_bindings SET literal_real = -0.0 WHERE parameter_id = 'x-real'")
        try await memory.plant("UPDATE memory_experience_bindings SET binding_contract_version = 2 WHERE parameter_id = 'x-int'")
        #expect(await factError { _ = try await memory.experiences.experience("x1") }
                == .malformedRow(table: "memory_experience_bindings", id: "x1", malformation: .unknownCode(column: "binding_contract_version", code: "2")))
        await memory.store.close()
    }

    @Test("one parametric Route, its value given once by the request and once by the current context: two experiences bind the same typed parameter to a request slot and to a context slot, the two calls carry their own values, and all of it reads back after reopening")
    func aParameterFromTheRequestAndFromTheContext() async throws {
        let memory = try await F.prepared()
        let to = try await memory.anchor("To", in: F.mail)
        let recipient = RouteParameter(parameterID: "p-to", name: "destinatario", direction: .input, valueType: .text, isRequired: true)
        let route = RouteDefinition(routeID: "r-write", name: "Scrivere a qualcuno", createdAtMS: F.t0, parameters: [recipient], steps: [
            ProcedureStep(stepID: "r-write.s0", position: 0, goalText: "Il destinatario è scritto", bundleID: F.mail,
                          checks: [StepCheck(checkID: "r-write.c0", position: 0, kind: .value, anchorID: to, expected: .parameter("p-to"))],
                          operations: [StepOperation(operationID: "r-write.o0", position: 0, tool: .typeText, arguments: [
                              OperationArgument(name: "target", position: 0, value: .anchor(to)),
                              OperationArgument(name: "text", position: 0, value: .parameter("p-to")),
                              OperationArgument(name: "replace", position: 0, value: .literal(.boolean(true)))])]),
        ])
        #expect(try await memory.routes.record(route, state: RouteState(status: .active)) == .committed)
        // The inputs are stated by the fixture, never extracted: the request named Carla, the open conversation was Dino's.
        let fromRequest = try ExperienceRecord(experienceID: "x-request", phrase: "scrivi a Carla", routeID: "r-write", createdAtMS: F.t0,
            bindings: [try ExperienceBinding(parameterID: "p-to", valueType: .text, source: .requestSlot("destinatario"))])
        let fromContext = try ExperienceRecord(experienceID: "x-context", phrase: "scrivi a chi è aperto", routeID: "r-write", createdAtMS: F.t0 + 1,
            bindings: [try ExperienceBinding(parameterID: "p-to", valueType: .text, source: .contextSlot("conversazione aperta"))])
        for experience in [fromRequest, fromContext] {
            #expect(try await memory.experiences.record(experience) == .committed)
        }
        for (id, value, ms) in [("a-request", "Carla", F.t0 + 10), ("a-context", "Dino", F.t0 + 20)] {
            let call = try AgentCallRecord(
                event: MemoryEventRecord(eventID: id, source: .cli, streamID: "chat-1", traceID: "trace-\(id)", sessionID: "session-1",
                                         kind: .action, app: AppContextIdentity(bundleID: F.mail), occurredAtMS: ms),
                request: .typeText(target: "To", text: value, section: nil, replace: true))
            #expect(try await memory.calls.record(call) == .committed)
        }
        #expect(try await memory.experiences.record(try ExperienceUse(experienceID: "x-request", eventID: "a-request", verdict: .passed)) == .committed)
        #expect(try await memory.experiences.record(try ExperienceUse(experienceID: "x-context", eventID: "a-context", verdict: .passed)) == .committed)
        await memory.store.close()

        let reopened = try await F.open(at: memory.url)
        let stored = try #require(try await reopened.routes.route("r-write"))
        #expect(stored.definition.isExactly(route), "the Route keeps the parameter as a reference, never a value")
        let experiences = try await reopened.experiences.experiences(ofRoute: "r-write")
        #expect(Set(experiences.map(\.experienceID)) == ["x-context", "x-request"] && experiences.count == 2)
        let request = try #require(try await reopened.experiences.experience("x-request"))
        let context = try #require(try await reopened.experiences.experience("x-context"))
        #expect(request.isExactly(fromRequest) && context.isExactly(fromContext))
        #expect(request.bindings.map(\.parameterID) == ["p-to"] && context.bindings.map(\.parameterID) == ["p-to"], "one parameter, bound twice")
        #expect(request.bindings[0].valueType == .text && context.bindings[0].valueType == .text)
        guard case .requestSlot("destinatario") = request.bindings[0].source, case .contextSlot("conversazione aperta") = context.bindings[0].source else {
            Issue.record("the two sources must read back as a request slot and a context slot")
            return
        }
        #expect(try await reopened.experiences.uses(of: "x-request").map(\.eventID) == ["a-request"])
        #expect(try await reopened.experiences.uses(of: "x-context").map(\.eventID) == ["a-context"])
        var values: [String] = []
        for id in ["a-request", "a-context"] {
            let call = try #require(try await reopened.calls.call(id))
            guard case .typeText(target: "To", text: let text, section: nil, replace: true) = call.request else {
                Issue.record("\(id) must read back as the typing it was")
                return
            }
            values.append(text)
        }
        #expect(values == ["Carla", "Dino"], "each call keeps its own value; nothing in the archive copies it into the binding")
        #expect(try await reopened.count("SELECT count(*) FROM memory_experience_bindings") == 2)
        await reopened.store.close()
    }
}
