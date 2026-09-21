//
//  WindowInventoryProbeReportTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import Foundation
import Testing

/// The report of the window inventory probe, offline: it round trips through
/// JSON, it keeps absent data absent, and it can describe a run that stopped
/// early with an incomplete cleanup without inventing a success.
@MainActor
struct WindowInventoryProbeReportTests {

    static func report(
        plan   : [ProbePhaseStep]         = ProbePhaseStep.standardPlan,
        fixture: StubProbeWindowOperator? = nil,
        reader : StubInventoryRowsReader? = nil
    ) -> WindowInventoryProbeReport {
        WindowInventoryProbeRun(
            fixture   : fixture ?? StubProbeWindowOperator(),
            reader    : reader ?? StubInventoryRowsReader.repeating(.rows([]), times: 64),
            clock     : SteppingProbeClock(step: 1),
            budget    : .diagnosticDefault,
            provenance: ProbeRunProvenance.identified(
                runID                 : "offline-report",
                operatingSystemVersion: "macOS 26.0",
                architecture          : nil
            ),
            plan      : plan
        ).execute()
    }

    @Test("a report survives a real round trip through JSON")
    func theReportRoundTrips() throws {
        let original = Self.report()
        let data     = try original.jsonData()
        let restored = try WindowInventoryProbeReport.decoded(from: data)

        #expect(restored == original)
        #expect(restored.version == WindowInventoryProbeReport.formatVersion)
        #expect(restored.pairs.count == original.pairs.count)
        #expect(restored.phases.map(\.step) == original.phases.map(\.step))
    }

    @Test("data the run did not have stays absent instead of being filled in")
    func absentDataStaysAbsent() throws {
        let restored = try WindowInventoryProbeReport.decoded(from: Self.report().jsonData())

        #expect(restored.provenance.architecture == nil)
        #expect(restored.provenance.buildIdentifier == nil)
        #expect(restored.provenance.operatingSystemVersion == "macOS 26.0")
        #expect(restored.provenance.runID == "offline-report")
    }

    @Test("the verdict is diagnostic and the limitations travel with the report")
    func theVerdictIsDiagnostic() throws {
        let restored = try WindowInventoryProbeReport.decoded(from: Self.report().jsonData())

        #expect(restored.verdict == "diagnostic-unqualified")
        #expect(restored.limitations == WindowInventoryProbeReport.statedLimitations)
        #expect(restored.limitations.contains { $0.contains("never shown") })
        #expect(restored.limitations.contains { $0.contains("not atomic") })
        #expect(restored.limitations.contains { $0.contains("redacted counter") })
        #expect(restored.limitations.contains { $0.contains("blocked synchronous native call") })
        #expect(restored.limitations.contains { $0.contains("not a production adapter") })
    }

    @Test("a stopped run keeps its partial report, its not run phases and its cleanup")
    func aStoppedRunKeepsItsPartialReport() throws {
        let residue = FixtureWindowToken(identifier: UUID(), role: .phased, creationOrder: 2)
        let claimed = ProbeCleanupRecord(
            status            : .unknownIncomplete,
            releasedTokenCount: 1,
            residualTokens    : [residue],
            notes             : ["the cleanup deadline passed"],
            priorErrors       : []
        )
        let report = Self.report(
            fixture: StubProbeWindowOperator(failingStep: .restore, cleanupResult: claimed)
        )
        let restored = try WindowInventoryProbeReport.decoded(from: report.jsonData())

        #expect(restored.stopReason == .operationFailed)
        #expect(restored.phases.count == ProbePhaseStep.standardPlan.count)
        #expect(restored.pairs.count == 4)
        #expect(restored.cleanup.status == .unknownIncomplete)
        #expect(restored.cleanup.residualTokens == [residue])
        #expect(restored.cleanup.priorErrors.count == 1,
                "a cleanup problem must not erase the failure that came first")
    }

    @Test("the whole of a reading, including its provenance and interval, is serialized")
    func aReadingKeepsItsProvenance() throws {
        let fixture  = StubProbeWindowOperator()
        let reader   = StubInventoryRowsReader.repeating(.rows([]), times: 4)
        let report   = Self.report(plan: [.createNeverPresented], fixture: fixture, reader: reader)
        let restored = try WindowInventoryProbeReport.decoded(from: report.jsonData())
        let pair     = try #require(restored.pairs.first)

        #expect(pair.all.scope == .all)
        #expect(pair.onScreen.scope == .onScreenOnly)
        #expect(pair.all.apiName == "StubInventoryRowsReader")
        #expect(pair.all.optionBits == 1)
        #expect(pair.onScreen.optionBits == 2)
        #expect(pair.all.endedAtNanoseconds >= pair.all.startedAtNanoseconds)
        #expect(pair.onScreen.startedAtNanoseconds >= pair.all.endedAtNanoseconds)
        #expect(pair.phaseIndex == 0)
    }
}
