//
//  AppProvenance.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 17/09/2026.
//

import AppKit
import Foundation

/// Where a running application came from, which is what "finished with it"
/// means: an application the agent opened is quit once the agent is done with
/// it, and an application the person already had open is handed back and left
/// alone.
enum AppProvenance: Sendable, Equatable {

    /// The lab started this process itself.
    case openedByAgent

    /// It was already running when the lab found it. The person's.
    case alreadyRunning

    /// Whether finishing with the application ends in quitting its process.
    /// The decision lives with the fact so the two halves of the rule cannot
    /// drift apart in two call sites.
    var endsByQuitting: Bool { self == .openedByAgent }

    /// What finishing with the application ends in, given whether the seat has
    /// finished with the window it took.
    ///
    /// Provenance alone does not decide it. An application the agent opened is
    /// the agent's to quit whether or not the adoption succeeded, but the
    /// process may only be terminated once the driver has given the window
    /// back: a window the seat is still trying to restore is an obligation in
    /// its restitution ledger that killing the owner makes impossible to
    /// discharge, which `AgentSeat.hasPendingWindowRestorations` reports and
    /// which blocks every later adoption.
    func finish(windowRestored: Bool) -> FinishOutcome {
        guard endsByQuitting else { return .release }
        return windowRestored ? .quit : .cannotQuitYet
    }
}

/// How finishing with one held application ends.
enum FinishOutcome: Sendable, Equatable {

    /// The person's application: its window goes home and the process is left
    /// running, which is the only thing that was ever done to it.
    case release

    /// The agent opened it and the seat has finished with its window, so the
    /// process is terminated.
    case quit

    /// The agent opened it and the seat cannot confirm the window went back.
    /// The process is left running and the person is told which one and why:
    /// terminating it is the one answer that makes the seat unrecoverable.
    case cannotQuitYet
}

/// Who opened each application the lab is using.
///
/// It is written at the one seam where the answer is known first hand,
/// `SeatBroker.launch`, which is also the only place in the kit that
/// starts a process. Nothing here reads a PID back and decides it looks
/// familiar: what a process was doing before the lab met it is not evidence of
/// who started it, so the only record written is the lab's own act, and a
/// process with no record was not started by the lab and is not the lab's to
/// quit.
@MainActor
final class LaunchLedger {
    private var records: [pid_t: AppProvenance] = [:]

    /// Asks the application `pid` to quit, for one a seat held and has finished with. The
    /// controlled tests supply one that records the pid, so no process is touched.
    let terminate: @MainActor (pid_t) -> Void

    init(
        terminate: @escaping @MainActor (pid_t) -> Void = { NSRunningApplication(processIdentifier: $0)?.terminate() }
    ) {
        self.terminate = terminate
    }

    func record(_ provenance: AppProvenance, for pid: pid_t) {
        records[pid] = provenance
    }

    func provenance(of pid: pid_t) -> AppProvenance {
        records[pid] ?? .alreadyRunning
    }

    /// Quits `pid` when the lab opened it, for an application that was launched and never seated,
    /// so no seat owes a window of it, and forgets it. Answers whether it was asked to quit: false
    /// for an application the lab did not open, and for one that refused the request.
    func quitUnseated(
        _ pid    : pid_t,
        terminate: (pid_t) -> Bool = { NSRunningApplication(processIdentifier: $0)?.terminate() ?? true }
    ) -> Bool {
        guard provenance(of: pid).endsByQuitting, terminate(pid) else { return false }
        forget(pid)
        return true
    }

    /// Forgets a process the lab has finished with. A PID is reused by the
    /// system, and a stale record would quit whatever gets that number next.
    func forget(_ pid: pid_t) {
        records[pid] = nil
    }
}
