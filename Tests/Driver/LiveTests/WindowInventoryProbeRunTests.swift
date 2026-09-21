//
//  WindowInventoryProbeRunTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import Foundation
import Testing

/// The run of the window inventory probe, offline, through the code the Live
/// suite uses and controlled doubles of the fixture, the reader and the clock.
///
/// Nothing here creates a window, sets up `NSApplication` or reads a window list:
/// the fixture is a double with the same ordering, failure and cleanup contract,
/// and the reader answers scripted lists. What is checked is the loop itself,
/// which is the part a Live run cannot be asked to break on purpose.
@MainActor
struct WindowInventoryProbeRunTests {

    static let provenance = ProbeRunProvenance.identified(runID: "offline-run")

    static func fixtureRow(windowID: Int, processID: Int, onScreen: Bool) -> [String: Any] {
        [
            WindowInventoryRowParser.windowNumberKey: windowID,
            WindowInventoryRowParser.ownerPIDKey    : processID,
            WindowInventoryRowParser.boundsKey      : ["X": 0.0, "Y": 0.0,
                                                       "Width": 320.0,
                                                       "Height": 200.0] as [String: Double],
            WindowInventoryRowParser.layerKey       : 0,
            WindowInventoryRowParser.alphaKey       : 1.0,
            WindowInventoryRowParser.onScreenKey    : onScreen,
        ]
    }

    static func run(
        fixture: StubProbeWindowOperator,
        reader : StubInventoryRowsReader,
        clock  : SteppingProbeClock,
        budget : ProbeBudget      = .diagnosticDefault,
        plan   : [ProbePhaseStep] = ProbePhaseStep.standardPlan
    ) -> WindowInventoryProbeReport {
        WindowInventoryProbeRun(
            fixture   : fixture,
            reader    : reader,
            clock     : clock,
            budget    : budget,
            provenance: provenance,
            plan      : plan
        ).execute()
    }

    static func notRunSteps(_ report: WindowInventoryProbeReport) -> [ProbePhaseStep] {
        report.phases.compactMap { phase -> ProbePhaseStep? in
            if case .notRun = phase.outcome { return phase.step }
            return nil
        }
    }

    // MARK: the order of the operations

    @Test("every phase is requested in the plan's order and each is followed by one pair")
    func thePlanRunsInOrderAndSamplesOnce() {
        let fixture = StubProbeWindowOperator()
        let reader  = StubInventoryRowsReader.repeating(.rows([]), times: 64)
        let report  = Self.run(fixture: fixture, reader: reader,
                               clock: SteppingProbeClock(step: 1))

        #expect(fixture.performedSteps == ProbePhaseStep.standardPlan)
        #expect(report.phases.map(\.step) == ProbePhaseStep.standardPlan)
        #expect(report.pairs.count == ProbePhaseStep.standardPlan.count)
        #expect(report.stopReason == .planCompleted)
        #expect(Self.notRunSteps(report).isEmpty)

        // One all reading then one on-screen reading, per pair, in that order.
        let expected = Array(
            repeating: [InventoryReadingScope.all, .onScreenOnly],
            count    : report.pairs.count
        ).flatMap { $0 }
        #expect(reader.requestedScopes == expected)
        #expect(report.pairs.map(\.sampleIndex) == Array(0..<report.pairs.count))
        #expect(report.pairs.allSatisfy { $0.runID == Self.provenance.runID })
        #expect(report.pairs.allSatisfy {
            $0.all.startedAtNanoseconds <= $0.onScreen.startedAtNanoseconds
        })
        #expect(report.pairs.allSatisfy { $0.all.optionBits != $0.onScreen.optionBits })
    }

    // MARK: the limits of the harness

    @Test("the phase deadline stops the plan and the phases left are written down as not run")
    func thePhaseDeadlineStopsThePlan() throws {
        let fixture = StubProbeWindowOperator()
        let reader  = StubInventoryRowsReader.repeating(.rows([]), times: 64)
        let budget  = ProbeBudget(phaseNanoseconds: 15, cleanupNanoseconds: 4, maximumPairs: 64)
        let report  = Self.run(fixture: fixture, reader: reader,
                               clock: SteppingProbeClock(step: 5), budget: budget)

        #expect(report.stopReason == .phaseDeadlineReached)
        #expect(fixture.performedSteps == [.createNeverPresented])
        #expect(report.phases.count == ProbePhaseStep.standardPlan.count)
        #expect(Self.notRunSteps(report).count == ProbePhaseStep.standardPlan.count - 1)
        #expect(fixture.cleanUpCount == 1, "cleanup runs even when the deadline stopped the plan")

        // The command of the first phase returned after the budget was already
        // spent, so no reading was started at all and the phase says so.
        #expect(report.pairs.isEmpty, "no native reading may be started after the deadline")
        #expect(reader.requestedScopes.isEmpty)
        let first = try #require(report.phases.first)
        guard case .incomplete(let detail) = first.outcome else {
            Issue.record("a phase whose deadline passed during it must be recorded as incomplete")
            return
        }
        #expect(detail.contains("deadline"))
        #expect(first.sampleIndex == nil)
    }

    /// The counterexample of `enforce-deadline-at-phase-operation-admission`,
    /// reproduced exactly.
    ///
    /// With this clock and this budget the guard that precedes the phase reads 5
    /// and lets it through, and the command is then measured as beginning at 10,
    /// which *is* the deadline. Checking the budget only before that measurement
    /// leaves the fixture free to create or move a window on a spent budget, and
    /// recording the phase as incomplete afterwards does not undo the operation.
    /// The fixture is a spy: what is checked is that no command was requested,
    /// not merely that the record reads well.
    @Test("a phase measured as beginning at the deadline is never requested of the fixture")
    func noWindowOperationStartsAtTheDeadline() throws {
        let fixture = StubProbeWindowOperator()
        let reader  = StubInventoryRowsReader.repeating(.rows([]), times: 64)
        let budget  = ProbeBudget(phaseNanoseconds: 10, cleanupNanoseconds: 4, maximumPairs: 64)
        let report  = Self.run(fixture: fixture, reader: reader,
                               clock : SteppingProbeClock(start: 0, step: 5),
                               budget: budget,
                               plan  : [.createNeverPresented])

        #expect(fixture.performedSteps.isEmpty,
                "perform must not be invoked for a phase that begins at the deadline")
        #expect(reader.requestedScopes.isEmpty)
        #expect(report.pairs.isEmpty)
        #expect(report.stopReason == .phaseDeadlineReached)

        let first = try #require(report.phases.first)
        guard case .notRun(let reason) = first.outcome else {
            Issue.record("a phase that was never requested must be recorded as not run")
            return
        }
        #expect(reason.contains("deadline"))
        #expect(first.startedAtNanoseconds == nil)
        #expect(first.sampleIndex == nil)
        #expect(fixture.cleanUpCount == 1, "the bounded cleanup still runs")
    }

    /// The counterexample of `enforce-deadlines-between-native-operations`,
    /// reproduced exactly.
    ///
    /// With this clock and this budget the guard that follows the command reads
    /// 3 and lets the sample through, and the all reading is then measured as
    /// starting at 4, which *is* the deadline. Checking the budget anywhere
    /// earlier — once in `execute`, or once per pair before the first member —
    /// leaves that call to leave, and a single assertion about the cleanup
    /// deadline says nothing about it at all. The reader is a spy: what is
    /// checked is that no call departed, not merely that the record looks tidy.
    @Test("a reading measured as starting at the deadline is never handed to the reader")
    func noNativeReadingStartsAtTheDeadline() throws {
        let fixture = StubProbeWindowOperator()
        let reader  = StubInventoryRowsReader.repeating(.rows([]), times: 64)
        let budget  = ProbeBudget(phaseNanoseconds: 4, cleanupNanoseconds: 2, maximumPairs: 64)
        let report  = Self.run(fixture: fixture, reader: reader,
                               clock : SteppingProbeClock(start: 0, step: 1),
                               budget: budget,
                               plan  : [.createNeverPresented])

        #expect(reader.requestedScopes.isEmpty,
                "rows(all) must not be invoked for a reading that starts at the deadline")

        let pair = try #require(report.pairs.first)
        #expect(pair.all.startedAtNanoseconds == 4,
                "the instant compared with the deadline is the one recorded as started")
        guard case .unavailable(let allReason) = pair.all.outcome else {
            Issue.record("a reading that was not started must be unavailable, not an empty list")
            return
        }
        #expect(allReason.contains("deadline"))
        guard case .unavailable = pair.onScreen.outcome else {
            Issue.record("the on-screen reading must not be started either")
            return
        }
        #expect(report.stopReason == .phaseDeadlineReached)
        #expect(fixture.cleanUpCount == 1, "the bounded cleanup still runs")
    }

    @Test("the deadline reached during the all reading leaves the on-screen reading unstarted")
    func theDeadlineStopsTheSecondReadingOfAPair() throws {
        let fixture = StubProbeWindowOperator()
        let reader  = StubInventoryRowsReader.repeating(.rows([]), times: 64)
        let budget  = ProbeBudget(phaseNanoseconds: 6, cleanupNanoseconds: 4, maximumPairs: 64)
        let report  = Self.run(fixture: fixture, reader: reader,
                               clock: SteppingProbeClock(step: 1), budget: budget)

        #expect(report.stopReason == .phaseDeadlineReached)
        #expect(report.pairs.count == 1)
        #expect(reader.requestedScopes == [.all], "the second reading must not be started")

        let pair = try #require(report.pairs.first)
        guard case .received = pair.all.outcome else {
            Issue.record("the first reading of the pair must be kept")
            return
        }
        guard case .unavailable(let reason) = pair.onScreen.outcome else {
            Issue.record("a reading that was never started must not look like an empty list")
            return
        }
        #expect(reason.contains("deadline"))
    }

    @Test("a plan whose last phase crossed the deadline does not report a completed plan")
    func theDeadlineIsCheckedAfterTheLastPhase() {
        let fixture = StubProbeWindowOperator()
        let reader  = StubInventoryRowsReader.repeating(.rows([]), times: 64)
        let budget  = ProbeBudget(phaseNanoseconds: 8, cleanupNanoseconds: 4, maximumPairs: 64)
        let report  = Self.run(fixture: fixture, reader: reader,
                               clock: SteppingProbeClock(step: 1), budget: budget,
                               plan : [.createNeverPresented])

        #expect(report.pairs.count == 1)
        #expect(Self.notRunSteps(report).isEmpty)
        #expect(report.stopReason == .phaseDeadlineReached,
                "a run that spent its budget must not be reported as a completed plan")
    }

    @Test("the pair cap stops the plan without a renewal")
    func thePairCapStopsThePlan() {
        let fixture = StubProbeWindowOperator()
        let reader  = StubInventoryRowsReader.repeating(.rows([]), times: 64)
        let budget  = ProbeBudget(phaseNanoseconds: .max, cleanupNanoseconds: 4, maximumPairs: 2)
        let report  = Self.run(fixture: fixture, reader: reader,
                               clock: SteppingProbeClock(step: 0), budget: budget)

        #expect(report.stopReason == .sampleCapReached)
        #expect(report.pairs.count == 2)
        #expect(fixture.performedSteps.count == 2)
        #expect(Self.notRunSteps(report).count == ProbePhaseStep.standardPlan.count - 2)
    }

    @Test("the default budget is the diagnostic one and is not a service level")
    func theDefaultBudgetIsTheDiagnosticOne() {
        #expect(ProbeBudget.diagnosticDefault.phaseNanoseconds == 20_000_000_000)
        #expect(ProbeBudget.diagnosticDefault.cleanupNanoseconds == 2_000_000_000)
        #expect(ProbeBudget.diagnosticDefault.maximumPairs == 64)
    }

    // MARK: failures, partial startup and cleanup

    @Test("a failed phase stops the plan, keeps its error and still cleans up")
    func aFailedPhaseStopsThePlan() throws {
        let fixture = StubProbeWindowOperator(failingStep: .minimize)
        let reader  = StubInventoryRowsReader.repeating(.rows([]), times: 64)
        let report  = Self.run(fixture: fixture, reader: reader,
                               clock: SteppingProbeClock(step: 1))

        #expect(report.stopReason == .operationFailed)
        #expect(report.pairs.count == 3, "no pair is taken for a phase that failed")

        let failed = try #require(report.phases.first { $0.step == .minimize })
        guard case .failed(let detail) = failed.outcome else {
            Issue.record("the failing phase must be recorded as failed")
            return
        }
        #expect(detail.contains("minimize"))
        #expect(failed.sampleIndex == nil)
        #expect(Self.notRunSteps(report).count == ProbePhaseStep.standardPlan.count - 4)
        #expect(fixture.cleanUpCount == 1)
        #expect(report.cleanup.priorErrors.count == 1, "cleanup must not mask the phase error")
    }

    @Test("a partial startup still releases what ownership was registered for")
    func aPartialStartupIsStillCleanedUp() {
        let fixture = StubProbeWindowOperator(failingStep: .createPhased)
        let reader  = StubInventoryRowsReader.repeating(.rows([]), times: 8)
        let report  = Self.run(fixture: fixture, reader: reader,
                               clock: SteppingProbeClock(step: 1))

        #expect(report.stopReason == .operationFailed)
        #expect(report.pairs.count == 1)
        #expect(fixture.cleanUpCount == 1)
        #expect(report.cleanup.releasedTokenCount == 1)
        #expect(report.cleanup.priorErrors.count == 1)
    }

    @Test("an incomplete cleanup is reported as incomplete and never as a success")
    func anIncompleteCleanupIsNotASuccess() {
        let residue = FixtureWindowToken(identifier: UUID(), role: .phased, creationOrder: 2)
        let claimed = ProbeCleanupRecord(
            status            : .verified,
            releasedTokenCount: 1,
            residualTokens    : [residue],
            notes             : ["the close was requested"],
            priorErrors       : ["an earlier failure of the fixture"]
        )
        let fixture = StubProbeWindowOperator(failingStep: .orderOut, cleanupResult: claimed)
        let reader  = StubInventoryRowsReader.repeating(.rows([]), times: 64)
        let report  = Self.run(fixture: fixture, reader: reader,
                               clock: SteppingProbeClock(step: 1))

        #expect(report.cleanup.status == .unknownIncomplete)
        #expect(report.cleanup.residualTokens == [residue])
        #expect(report.cleanup.priorErrors.count == 2,
                "both the fixture's error and the run's are kept")
        #expect(report.stopReason == .operationFailed)
    }

    // MARK: what a reading does and does not establish

    @Test("a window in the all reading and not in the on-screen one is a difference, not a closure")
    func discordantReadingsStayTwoReadings() throws {
        let fixture = StubProbeWindowOperator()
        let reader  = StubInventoryRowsReader([
            .rows([Self.fixtureRow(windowID: 901, processID: 4242, onScreen: false)]),
            .rows([]),
        ])
        let report  = Self.run(fixture: fixture, reader: reader,
                               clock: SteppingProbeClock(step: 1),
                               plan : [.createNeverPresented])

        let pair = try #require(report.pairs.first)
        guard case .received(let all) = pair.all.outcome,
              case .received(let onScreen) = pair.onScreen.outcome
        else {
            Issue.record("both readings must be recorded")
            return
        }
        #expect(all.fixtureRows.count == 1)
        #expect(all.fixtureRows.first?.isOnScreen == false)
        #expect(onScreen.rowCount == 0)
        #expect(pair.fixtureWindowIDsOnlyInAll == [901])
        #expect(!pair.atomicityNote.isEmpty)
    }

    @Test("a nil reading and a failed reading are kept apart and stop nothing")
    func failedReadingsArePreserved() throws {
        let fixture = StubProbeWindowOperator()
        let reader  = StubInventoryRowsReader([
            .absentList,
            .failed("the answer could not be bridged"),
            .rows([]),
            .unavailable("not performed"),
        ])
        let report  = Self.run(fixture: fixture, reader: reader,
                               clock: SteppingProbeClock(step: 1),
                               plan : [.createNeverPresented, .createPhased])

        #expect(report.pairs.count == 2)
        #expect(report.stopReason == .planCompleted, "a reading is evidence, not a control signal")

        let first  = try #require(report.pairs.first)
        let second = try #require(report.pairs.last)
        guard case .absentList = first.all.outcome else {
            Issue.record("a nil list must stay a nil list")
            return
        }
        guard case .failed = first.onScreen.outcome else {
            Issue.record("a failed conversion must stay a failure")
            return
        }
        guard case .received(let digest) = second.all.outcome else {
            Issue.record("an empty list must stay a received list")
            return
        }
        #expect(digest.rowCount == 0)
        guard case .unavailable = second.onScreen.outcome else {
            Issue.record("a reading that never happened must stay unavailable")
            return
        }
        #expect(first.all.hasList == false)
    }
}
