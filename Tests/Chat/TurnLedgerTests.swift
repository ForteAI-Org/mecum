//
//  TurnLedgerTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
import Testing

/// Synthetic turns through the real tool adapter; no application, provider or store is involved.
@Suite("Typed turn events and the verified candidate")
struct TurnLedgerTests {

    private let request = "Seleziona Output Busses nel filtro della scheda Bus e verifica il nuovo valore. "
        + "Fermati se il controllo non è univoco."

    /// Runs `body` as one turn and returns its report.
    @MainActor
    private func turn(
        _ session: EvidenceSession,
        ending   : TurnAdmission.Ending = .completed,
        _ body   : (AutomationTools, JSONValue) async throws -> Void
    ) async throws -> TurnLedger.Report {
        let tools = AutomationTools(session: session)
        let ledger = TurnLedger()
        tools.onEvent = { ledger.record($0) }
        ledger.begin(request: request)
        try await body(tools, .string(try #require(session.id).uuidString))
        return try #require(ledger.finish(ending))
    }

    @MainActor
    private func select(_ tools: AutomationTools, _ id: JSONValue) async throws {
        _ = try await tools.call("select", .object(["session": id, "control": .string("All Busses"),
                                                    "item": .string("Output Busses")]))
    }

    @MainActor
    private func prepare(_ tools: AutomationTools, _ id: JSONValue) async throws {
        _ = try await tools.call("status", .object([:]))
        _ = try await tools.call("observe", .object(["session": id]))
    }

    @Test("a verified select under the user's exact phrase yields one candidate with semantic arguments only")
    @MainActor
    func verifiedCandidate() async throws {
        let report = try await turn(EvidenceSession()) { tools, id in
            try await prepare(tools, id)
            try await select(tools, id)
        }
        #expect(report.request == request)
        #expect(report.attempts.count == 3)
        #expect(report.decision.reason == .admittedSingleSelection)
        guard case .promote(let draft, let proof) = report.decision.action else {
            Issue.record("no candidate"); return
        }
        #expect(draft.phrase == request)
        #expect(draft.step.arguments == ["control": "All Busses", "item": "Output Busses"])
        #expect(draft.context.bundleID == "test.synthetic.mixer")
        #expect(proof.change == .changed)
        let event = try #require(report.event)
        #expect(event.id == "turn-\(report.turnID.uuidString)")
        #expect(event.subject == .step(draft))
    }

    @Test("an error after the verified select yields no candidate")
    @MainActor
    func errorAfterward() async throws {
        let session = EvidenceSession()
        let report = try await turn(session) { tools, id in
            try await select(tools, id)
            session.observeFails = true
            _ = try? await tools.call("observe", .object(["session": id]))
        }
        #expect(report.attempts.last == .failed("observe"))
        #expect(report.decision.reason == .toolFailed)
        if case .promote = report.decision.action { Issue.record("a failed turn was promoted") }
    }

    @Test("an interrupted turn yields no candidate, even after a verified select")
    @MainActor
    func interrupted() async throws {
        let report = try await turn(EvidenceSession(), ending: .interrupted) { tools, id in
            try await select(tools, id)
        }
        #expect(report.decision.reason == .turnInterrupted)
        guard case .keepAttempt(_, .verified) = report.decision.action else {
            Issue.record("the select's proof was not kept as history"); return
        }
    }

    @Test("a failed batch is one batch attempt, and its inner steps stay visible")
    @MainActor
    func failedBatch() async throws {
        let session = EvidenceSession()
        session.actFails = true
        let report = try await turn(session) { tools, id in
            _ = try await tools.call("batch", .object(["session": id, "steps": .array([
                .object(["operation": .string("select"), "control": .string("All Busses"),
                         "item": .string("Output Busses")]),
                .object(["operation": .string("act"), "target": .string("Export")]),
            ])]))
        }
        #expect(report.attempts == [.batch])
        #expect(report.batchSteps.map(\.batchStep) == [1, 2])
        #expect(report.batchSteps.first?.operation == .select(control: "All Busses", item: "Output Busses"))
        guard case .failed = report.batchSteps.last?.result else { Issue.record("the failed step is hidden"); return }
        #expect(report.decision.reason == .batchUsed)
        #expect(report.decision.action == .nothing)
    }

    @Test("two select attempts yield no candidate")
    @MainActor
    func twoAttempts() async throws {
        let report = try await turn(EvidenceSession()) { tools, id in
            try await select(tools, id)
            try await select(tools, id)
        }
        #expect(report.decision.reason == .severalSelections)
        #expect(report.decision.action == .nothing)
    }

    @Test("a turn that hands the work back to the user yields no candidate")
    @MainActor
    func handedToUser() async throws {
        let report = try await turn(EvidenceSession(), ending: .handedToUser) { tools, id in
            try await select(tools, id)
        }
        #expect(report.decision.reason == .handedToUser)
    }

    @Test("a provider that completed after a select without proof yields no candidate")
    @MainActor
    func completedWithoutProof() async throws {
        let session = EvidenceSession()
        session.withEvidence = false
        let report = try await turn(session) { tools, id in try await select(tools, id) }
        #expect(report.attempts == [.select(control: "All Busses", item: "Output Busses", kind: .foundActed,
                                            evidence: nil)])
        #expect(report.decision.reason == .noEvidence)
        #expect(report.decision.action == .nothing)
    }

    @Test("a refused call is a failure, events outside a turn are ignored, and an open turn is never lost")
    @MainActor
    func boundaries() async throws {
        let session = EvidenceSession()
        let tools = AutomationTools(session: session)
        let ledger = TurnLedger()
        tools.onEvent = { ledger.record($0) }
        _ = try await tools.call("status", .object([:]))
        #expect(!ledger.isCollecting)
        ledger.begin(request: request)
        _ = try? await tools.call("select", .object(["session": .string("stale"), "control": .string("All Busses"),
                                                     "item": .string("Output Busses")]))
        let abandoned = try #require(ledger.begin(request: "altro"))
        #expect(abandoned.attempts == [.failed("select")])
        #expect(abandoned.ending == .interrupted)
        #expect(session.selections == 0)
    }
}
