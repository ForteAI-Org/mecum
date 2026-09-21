//
//  ProbePhaseRecord.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import Foundation

/// ProbePhaseOutcome is what became of one requested phase.
///
/// `performed` means the AppKit call returned and the fixture read its own
/// object afterwards. It is not a claim that the window server did anything.
/// `notRun` is recorded rather than omitted, so a plan that stopped early can be
/// told from a plan that was never written that way.
enum ProbePhaseOutcome: Codable, Equatable {

    case performed(ProbeWindowLocalState)
    case failed(String)
    case notRun(String)

    /// The phase started and its result is not known, which is what a deadline
    /// reached in the middle of a call leaves behind.
    case incomplete(String)
}

/// ProbePhaseRecord is one line of the plan: what was asked for, when, and what
/// came back. The requested command and the observed local state are kept as two
/// separate facts on purpose.
struct ProbePhaseRecord: Codable, Equatable {

    let index           : Int
    let step            : ProbePhaseStep
    let requestedCommand: String

    /// Absent for a phase that never started.
    let startedAtNanoseconds: UInt64?
    let endedAtNanoseconds  : UInt64?

    let outcome: ProbePhaseOutcome

    /// The reading pair taken after this phase, when one was taken.
    let sampleIndex: Int?

    static func notRun(index: Int, step: ProbePhaseStep, reason: String) -> ProbePhaseRecord {
        ProbePhaseRecord(
            index               : index,
            step                : step,
            requestedCommand    : step.requestedCommand,
            startedAtNanoseconds: nil,
            endedAtNanoseconds  : nil,
            outcome             : .notRun(reason),
            sampleIndex         : nil
        )
    }
}
