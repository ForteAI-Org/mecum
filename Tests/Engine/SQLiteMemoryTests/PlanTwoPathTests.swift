//
//  PlanTwoPathTests.swift
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

/// Plan 2 across its repositories, on one file and through the public roles alone: an event and
/// its sample, the structural scene it is confirmed in, the application's knowledge through the
/// register, an arc of the general graph with its evidence, a parametric Route, a step occurrence
/// with its memberships, a verification whose verdict is unknown, explicit evidence, an experience
/// with its binding and a use. Everything is read back after reopening as it was given, and
/// retried without a counter or a row moving.
@Suite("Plan 2 across its repositories", .serialized)
struct PlanTwoPathTests {

    private typealias S = SceneFixtures
    private static let t0MS: Int64 = 1_700_000_000_000

    private struct Repositories {
        let captures: SQLiteCaptureRepository
        let scenes: SQLiteSceneRepository
        let applications: SQLiteBrainApplicationRepository
        let brain: SQLiteBrainRepository
        let graph: SQLiteBrainGraphRepository
        let routes: SQLiteRouteRepository
        let steps: SQLiteStepOccurrenceRepository
        let verifications: SQLiteVerificationRepository
        let calls: SQLiteAgentCallRepository
        let experiences: SQLiteExperienceRepository

        init(_ store: SQLiteMemoryStore, ids: BrainIdentities, scenes: SceneIDs) {
            captures = SQLiteCaptureRepository(store: store)
            self.scenes = SQLiteSceneRepository(store: store, makeSceneID: { scenes.next() })
            applications = SQLiteBrainApplicationRepository(store: store, keys: ids.keys, makeTransitionID: ids.transitionID, makeSceneID: ids.sceneID,
                                                            algorithmVersion: BrainApplicationContract.algorithmVersion)
            brain = SQLiteBrainRepository(store: store)
            graph = SQLiteBrainGraphRepository(store: store)
            routes = SQLiteRouteRepository(store: store)
            steps = SQLiteStepOccurrenceRepository(store: store)
            verifications = SQLiteVerificationRepository(store: store)
            calls = SQLiteAgentCallRepository(store: store)
            experiences = SQLiteExperienceRepository(store: store)
        }
    }

    /// Rows of every table of the file, by name.
    private func rows(_ store: SQLiteMemoryStore) async throws -> [String: Int64] {
        try await store.read { snapshot in
            let tables = try snapshot.query("SELECT name FROM sqlite_master WHERE type = 'table' AND (name LIKE 'brain\\_%' ESCAPE '\\' OR name LIKE 'memory\\_%' ESCAPE '\\')", []) {
                try $0.text(0) ?? ""
            }
            var counts: [String: Int64] = [:]
            for table in tables { counts[table] = try snapshot.query("SELECT count(*) FROM \(table)", []) { $0.integer(0) ?? -1 }.first ?? -1 }
            return counts
        }
    }

    @Test("an event confirmed in a structural scene, the application's knowledge, a general arc, a parametric Route, an occurrence with its memberships, an unknown verification, evidence and an experience with a use: read back after reopening as given, unknown still unknown, no sample invented; retried, no row and no counter moves; the projection reads its own rows beside the graph")
    func path() async throws {
        let ids = BrainIdentities(), sceneIDs = SceneIDs()
        let memory = try await S.open(ids: sceneIDs)
        let r = Repositories(memory.store, ids: ids, scenes: sceneIDs)
        let bundle = S.app.bundleID
        let key = CaptureSampleKey(eventID: "e1", phase: .current)

        // The fact and the scene it is confirmed in.
        let window = S.perceive(S.window("Inbox", [S.button("Compose", y: 700), S.button("Reply", y: 650)]))
        let association = try await S.observe(memory, "e1", window)
        let scene = try #require(association.createdSceneID)
        // The application's knowledge, through the register, from the same sample.
        let command = try BrainApplicationCommand.observe(detections: BrainApplicationFixtures.controls(["Compose", "Reply"]), window: nil, bundleID: bundle,
                                                          sample: key, requestedAt: BrainFixtures.t0)
        let applied = try await r.applications.apply(command)
        #expect(applied.receipt == .committed)
        let reply = try #require(try await r.brain.brain(of: bundle)?.objects.first { $0.label == "Reply" }).anchorKey
        // A general arc from the structural scene, and evidence the event was confirmed for.
        let element = try #require(try await r.graph.elements(ofScene: scene).first { $0.scope == .control && $0.label == "Reply" })
        let arc = try BrainArc(transitionID: "arc-reply", bundleID: bundle, fromSceneID: scene, trigger: .element(sceneElementID: element.sceneElementID, gesture: .click),
                               effect: try TransitionEffectRecord(effect: "elementsAppeared:Inoltra"), status: .candidate, evidenceCount: 0,
                               firstSeenMS: Self.t0MS, lastSeenMS: Self.t0MS)
        #expect(try await r.graph.record(arc) == .committed)
        let arcEvidence = try BrainEvidenceRecord(bundleID: bundle, eventID: "e1", target: .transition("arc-reply"), relation: .supports, assessedBy: "fixture",
                                                  assessmentVersion: "1", assessedAtMS: Self.t0MS)
        #expect(try await r.graph.record(arcEvidence) == .committed)
        // A parametric Route on that scene and anchor.
        let text = RouteParameter(parameterID: "p-text", name: "testo", direction: .input, valueType: .text, isRequired: true)
        let route = RouteDefinition(routeID: "r-reply", name: "Rispondere", createdAtMS: Self.t0MS, parameters: [text], steps: [
            ProcedureStep(stepID: "r-reply.s0", position: 0, goalText: "La risposta contiene il testo", bundleID: bundle, checks: [
                StepCheck(checkID: "r-reply.c0", position: 0, kind: .scene, sceneID: scene),
                StepCheck(checkID: "r-reply.c1", position: 1, kind: .text, expected: .parameter("p-text"), comparison: .contains),
            ], operations: [
                StepOperation(operationID: "r-reply.o0", position: 0, tool: .typeText, arguments: [
                    OperationArgument(name: "target", position: 0, value: .anchor(reply)),
                    OperationArgument(name: "text", position: 0, value: .parameter("p-text")),
                    OperationArgument(name: "replace", position: 0, value: .literal(.boolean(false))),
                ]),
            ]),
        ])
        #expect(try await r.routes.record(route, state: RouteState(status: .active)) == .committed)
        // The call, the occurrence and its memberships, a verification that could not tell.
        let call = try AttributionFixtures.agentCall("a1", app: S.app)
        _ = try await r.calls.record(call)
        let occurrence = try StepOccurrenceRecord(stepOccurrenceID: "so1", startedAtMS: Self.t0MS, status: .observed)
        #expect(try await r.steps.record(occurrence) == .committed)
        #expect(try await r.steps.assign("so1", toTask: nil, step: "r-reply.s0", by: "fixture") == .committed)
        let observed = try StepMembership(stepOccurrenceID: "so1", eventID: "e1", position: 0, role: .observation)
        let acted = try StepMembership(stepOccurrenceID: "so1", eventID: "a1", position: 1, attemptNumber: 1, role: .action)
        #expect(try await r.steps.record(observed) == .committed)
        #expect(try await r.steps.record(acted) == .committed)
        let verification = try VerificationRecord(event: AttributionFixtures.verificationEvent("v1", app: S.app), scope: .step, method: .sceneText, verdict: .unknown)
        #expect(try await r.verifications.record(verification) == .committed)
        let verified = try StepMembership(stepOccurrenceID: "so1", eventID: "v1", position: 2, attemptNumber: 1, role: .verification)
        #expect(try await r.steps.attribute(verification: "v1", to: verified) == .committed)
        // The fixture's own judgement, stated as such, and an experience with its slot and a use.
        let stepEvidence = try DefinitionEvidence(.step(stepID: "r-reply.s0", stepOccurrenceID: "so1"), relation: .supports, assessedBy: "fixture", assessedAtMS: Self.t0MS + 10)
        #expect(try await r.steps.record(stepEvidence) == .committed)
        let experience = try ExperienceRecord(experienceID: "x1", phrase: "rispondi con il testo", routeID: "r-reply", createdAtMS: Self.t0MS + 20, bindings: [
            try ExperienceBinding(parameterID: "p-text", valueType: .text, source: .requestSlot("testo")),
        ])
        #expect(try await r.experiences.record(experience) == .committed)
        let use = try ExperienceUse(experienceID: "x1", eventID: "a1", verdict: .unknown)
        #expect(try await r.experiences.record(use) == .committed)

        let projection = try #require(try await r.brain.brain(of: bundle))
        let evidence = try await r.graph.evidence(ofEvent: "e1")
        let before = try await rows(memory.store)
        #expect(before.count == SchemaShape.current.tables)

        // Every fact and attribution again: nothing is written twice, no counter moves.
        #expect(try await r.captures.record(S.event("e1")) == .alreadyApplied)
        #expect(try await r.captures.record(S.sample("e1", of: window)) == .alreadyApplied)
        let again = try await r.scenes.associate(key, at: Self.t0MS + 5)
        #expect(again.receipt == .alreadyApplied && again.decision == .confirmed(sceneID: scene) && again.createdSceneID == nil, "the stored association, no new scene")
        #expect(try await r.applications.apply(command).receipt == .alreadyApplied)
        #expect(try await r.graph.record(arc) == .alreadyApplied)
        #expect(try await r.graph.record(arcEvidence) == .alreadyApplied)
        #expect(try await r.routes.record(route, state: RouteState(status: .active)) == .alreadyApplied)
        #expect(try await r.calls.record(call) == .alreadyApplied)
        #expect(try await r.steps.record(occurrence) == .alreadyApplied)
        #expect(try await r.steps.assign("so1", toTask: nil, step: "r-reply.s0", by: "fixture") == .alreadyApplied)
        #expect(try await r.steps.record(observed) == .alreadyApplied)
        #expect(try await r.steps.record(acted) == .alreadyApplied)
        #expect(try await r.verifications.record(verification) == .alreadyApplied)
        #expect(try await r.steps.attribute(verification: "v1", to: verified) == .alreadyApplied)
        #expect(try await r.steps.record(stepEvidence) == .alreadyApplied)
        #expect(try await r.experiences.record(experience) == .alreadyApplied)
        #expect(try await r.experiences.record(use) == .alreadyApplied)
        #expect(try await rows(memory.store) == before, "no row of any table moved")
        #expect(try await r.brain.brain(of: bundle) == projection, "no counter of the projection moved")
        await memory.store.close()

        let reopened = try await S.open(at: memory.url, ids: sceneIDs)
        let o = Repositories(reopened.store, ids: ids, scenes: sceneIDs)
        #expect(try await rows(reopened.store) == before)
        #expect(try await o.scenes.associations(of: key).map { "\($0.sceneID) \($0.status)" } == ["\(scene) confirmed"])
        #expect(try await o.scenes.scenes(of: bundle).first { $0.id == scene }?.observationCount == 1)
        #expect(try await o.captures.sample(key)?.quality == S.sample("e1", of: window).quality)
        #expect(try await o.captures.sample(CaptureSampleKey(eventID: "e1", phase: .before)) == nil, "no sample before the event is invented")
        #expect(try await o.brain.brain(of: bundle) == projection, "the projection reads its own rows beside the graph")
        #expect(try await o.graph.arc("arc-reply")?.isExactly(arc) == true)
        let reread = try await o.graph.evidence(ofEvent: "e1")
        #expect(reread.count == evidence.count && zip(reread, evidence).allSatisfy { $0.isExactly($1) })
        #expect(reread.contains { $0.isExactly(arcEvidence) })
        let stored = try #require(try await o.routes.route("r-reply"))
        #expect(stored.definition.isExactly(route) && stored.state.status == .active)
        let storedOccurrence = try #require(try await o.steps.occurrence("so1"))
        #expect(storedOccurrence.record.isExactly(occurrence) && storedOccurrence.stepID == "r-reply.s0" && storedOccurrence.taskOccurrenceID == nil
                && storedOccurrence.assignedBy == "fixture")
        #expect(try await o.steps.memberships(of: "so1").map(\.role) == [.observation, .action, .verification])
        #expect(try await o.steps.memberships(of: "so1").first?.attemptNumber == nil, "an attempt not known stays unknown, not zero")
        let storedVerification = try #require(try await o.verifications.verification("v1"))
        #expect(storedVerification.record.verdict == .unknown && storedVerification.stepOccurrenceID == "so1", "unknown stays unknown")
        #expect(try await o.steps.evidence(ofStep: "r-reply.s0").map { $0.isExactly(stepEvidence) } == [true])
        #expect(try await o.experiences.experience("x1")?.isExactly(experience) == true)
        #expect(try await o.experiences.useCounts(of: "x1") == ExperienceUseCounts(passed: 0, failed: 0, unknown: 1), "no use becomes a success")
        let overview = try await o.graph.overview()
        let app = try #require(overview.apps.first { $0.bundleID == bundle })
        #expect(app.structuralScenes == 1 && app.generalArcs == 1 && app.projectionAnchors == 2 && app.events == 3 && app.samples == 1)
        #expect(overview.routes[.active] == 1 && overview.experiences == 1 && overview.stepOccurrences == 1 && overview.taskOccurrences == 0)
        await reopened.store.close()
    }
}
