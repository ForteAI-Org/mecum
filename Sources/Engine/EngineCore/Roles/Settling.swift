//
//  Settling.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/10/2026.
//

import Foundation

/// Settling is the wait between a delivered gesture and the perception that judges it, ended as
/// soon as the target's window has settled and never later than `cap`.
///
/// The cap is the engine's fixed pause, and it stays the engine's: the role only decides whether
/// the window says it is done sooner. A conformer that has nothing to watch (no running stream,
/// another window) waits the whole cap, and an engine given no settling role sleeps the cap
/// itself, which is the behaviour before this role existed. It never throws and never sends input.
///
/// A conformer that compares what the window shows after a gesture with what it showed before it
/// takes its reference in `prepare`, which the engine calls right before it delivers a gesture.
public protocol Settling: Sendable {

    /// Notes what the window of `processID` shows now, right before a gesture is delivered, for
    /// the next `settle` to compare with. Never throws; a conformer with nothing to note returns.
    func prepare(in processID: pid_t) async

    /// Returns once the window of `processID` has settled after the last gesture, or at `cap`.
    func settle(in processID: pid_t, cap: Duration) async
}

extension Settling {

    /// A conformer that keeps no reference before a gesture has nothing to do here.
    public func prepare(in processID: pid_t) async {}
}
