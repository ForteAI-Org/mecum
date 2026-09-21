//
//  ProbeCleanupSweep.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import Foundation

/// ProbeCleanupObservation is everything the fixture can honestly say about the
/// release of one of its own windows.
///
/// There is no case meaning "gone". The fixture asks AppKit to order a window
/// out and to close it and then reads its own object again; neither the return
/// of those methods nor the local answer is an observation of the window server.
/// The strongest case below is therefore a close that was requested and left the
/// object no longer reporting itself visible, which is still not a disappearance
/// anyone measured.
enum ProbeCleanupObservation: Equatable {

    /// The deadline had already passed, so nothing was requested for this
    /// window at all.
    case notAttemptedBeforeDeadline

    /// The window was ordered out and the deadline passed before its close was
    /// requested, so its release stopped half way.
    case interruptedByDeadline

    /// Order out and close were both requested and returned.
    /// `visibleLocally` is what the object said about itself afterwards, and
    /// `deadlinePassedAfterwards` says the budget ran out while that happened.
    case closeRequested(visibleLocally: Bool, deadlinePassedAfterwards: Bool)
}

/// ProbeCleanupSweep turns those observations into a cleanup record.
///
/// It holds no window and calls nothing, which is what lets the decision between
/// `verified`, `failed` and `unknownIncomplete` be exercised offline through the
/// same code the AppKit fixture uses. The rule it applies is that a window whose
/// release was merely requested is an *unverified residue*: it is listed, and the
/// record says unknown and incomplete. `verified` is reachable only when there
/// was nothing registered left to release, because that is the only case this
/// fixture can establish without asking the window server anything.
struct ProbeCleanupSweep {

    private var releaseRequested             = 0
    private var residual: [FixtureWindowToken] = []
    private var notes   : [String]             = []
    private var sawFailure                     = false
    private var sawUnknown                     = false

    /// An empty sweep: nothing observed, nothing released, nothing claimed.
    init() {}

    mutating func record(_ observation: ProbeCleanupObservation, for token: FixtureWindowToken) {

        let window = "window \(token.creationOrder)"
        residual.append(token)

        switch observation {
        case .notAttemptedBeforeDeadline:
            sawUnknown = true
            notes.append("the cleanup deadline passed before \(window) was released, so nothing "
                + "was requested for it and it is left registered")

        case .interruptedByDeadline:
            sawUnknown = true
            notes.append("the cleanup deadline passed after \(window) was ordered out and before "
                + "its close was requested, so its release is incomplete")

        case .closeRequested(let visibleLocally, let deadlinePassedAfterwards):
            releaseRequested += 1
            if visibleLocally {
                sawFailure = true
                notes.append("\(window) still reports itself visible after close() was requested")
            } else {
                sawUnknown = true
                notes.append("close was requested for \(window) and the object no longer reports "
                    + "itself visible; whether the window server dropped the surface is not "
                    + "observed here and stays unknown")
            }
            if deadlinePassedAfterwards {
                notes.append("the cleanup deadline passed while \(window) was being released")
            }
        }
    }

    /// The record for everything observed so far.
    ///
    /// A window that was observed still visible makes the whole cleanup
    /// `failed`: that is a positive observation of a residue, and it outranks
    /// the absence of knowledge the other cases carry.
    func result() -> ProbeCleanupRecord {

        var lines = notes
        let status: ProbeCleanupStatus

        if sawFailure       { status = .failed }
        else if sawUnknown  { status = .unknownIncomplete }
        else {
            status = .verified
            lines.append("no window of this fixture was still registered, so there was nothing "
                + "to release")
        }

        lines.append("only windows this fixture created were touched; neither a close request nor "
            + "the exit of this process attests that the window server dropped a surface, so the "
            + "released count is a count of requests that returned and not of surfaces verified "
            + "gone")

        return ProbeCleanupRecord(
            status            : status,
            releasedTokenCount: releaseRequested,
            residualTokens    : residual,
            notes             : lines,
            priorErrors       : []
        )
    }
}
