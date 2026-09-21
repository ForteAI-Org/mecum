//
//  AppProvenanceTests.swift
//  AgentLab
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 17/09/2026.
//

import Testing
@testable import SeatBroker

@Test @MainActor
func theLedgerAnswersWithWhatWasRecordedPerProcess() {
    let ledger = LaunchLedger()
    ledger.record(.openedByAgent, for: 101)
    ledger.record(.alreadyRunning, for: 202)

    #expect(ledger.provenance(of: 101) == .openedByAgent)
    #expect(ledger.provenance(of: 202) == .alreadyRunning)

    // A process the lab never opened is the person's, and so is the PID of one
    // it has finished with: the system hands that number out again.
    #expect(ledger.provenance(of: 303) == .alreadyRunning)
    ledger.forget(101)
    #expect(ledger.provenance(of: 101) == .alreadyRunning)
}

@Test
func onlyAnApplicationTheAgentOpenedIsQuitWhenItIsDone() {
    #expect(AppProvenance.openedByAgent.endsByQuitting)
    #expect(!AppProvenance.alreadyRunning.endsByQuitting)
}

@Test
func anApplicationTheAgentOpenedIsQuitEvenWhenItsAdoptionFailed() {
    // The decision the MarkEdit run got wrong: nothing reached the seat, and
    // the application the agent launched is still the agent's to quit.
    #expect(AppProvenance.openedByAgent.finish(windowRestored: true) == .quit)

    // The person's application is only ever handed back: quitting one was
    // never on the table, adoption or no adoption.
    #expect(AppProvenance.alreadyRunning.finish(windowRestored: true) == .release)
    #expect(AppProvenance.alreadyRunning.finish(windowRestored: false) == .release)
}

@Test
func nothingIsTerminatedWhileTheSeatStillOwesTheWindowBack() {
    // Terminating the owner of a window the seat still owes back leaves an
    // obligation it can never discharge, and that blocks every later adoption.
    #expect(AppProvenance.openedByAgent.finish(windowRestored: false) == .cannotQuitYet)
}

@Test @MainActor
func aRefusedHandbackStopsTheQuitAndIsReportedWhateverTheApplicationWas() {
    // The third step of finishing, which only a handed-back application
    // reaches: the assignment is still bound to this instance, so quitting its
    // process would leave the seat holding one nothing can end.
    let refusal = "The seat still holds window 36778 of this application."
    let blocked = AgentSession.finishing(.quit, handback: refusal, app: "MarkEdit")
    #expect(!blocked.quits)
    #expect(blocked.sentence?.contains(refusal) == true)
    #expect(blocked.sentence?.contains("nothing else can be adopted") == true)
    #expect(blocked.sentence?.contains("MarkEdit was left running") == true)

    // The person's own application is never quit, and the refusal still has to
    // reach them: it is why the next application cannot be adopted.
    let theirs = AgentSession.finishing(.release, handback: refusal, app: "DaVinci Resolve")
    #expect(!theirs.quits)
    #expect(theirs.sentence?.contains(refusal) == true)
    #expect(theirs.sentence?.contains("left running") == false)

    // Both halves are reported when both refused, and neither is the other.
    let both = AgentSession.finishing(.cannotQuitYet, handback: refusal, app: "MarkEdit")
    #expect(!both.quits)
    #expect(both.sentence?.contains(refusal) == true)
    #expect(both.sentence?.contains("could not confirm its window went back") == true)
}

@Test @MainActor
func finishingSaysNothingAndQuitsTheAgentsApplicationWhenTheHandbackWentThrough() {
    let quit = AgentSession.finishing(.quit, handback: nil, app: "MarkEdit")
    #expect(quit.quits)
    #expect(quit.sentence == nil)

    let released = AgentSession.finishing(.release, handback: nil, app: "DaVinci Resolve")
    #expect(!released.quits)
    #expect(released.sentence == nil)

    let owed = AgentSession.finishing(.cannotQuitYet, handback: nil, app: "MarkEdit")
    #expect(!owed.quits)
    #expect(owed.sentence?.contains("MarkEdit is still running") == true)
}
