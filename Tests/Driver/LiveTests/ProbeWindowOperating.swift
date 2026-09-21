//
//  ProbeWindowOperating.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import Foundation

/// ProbeWindowLocalState is what the fixture could observe about its own window
/// object after a requested command, read from that object and from nowhere
/// else.
///
/// `isVisibleLocally` is `NSWindow.isVisible`, which is AppKit's answer about
/// AppKit's object. It is not a statement about the window server, and the probe
/// never treats a method that returned without throwing as proof that a surface
/// appeared, moved or went away.
struct ProbeWindowLocalState: Codable, Equatable {

    let token   : FixtureWindowToken

    /// The Window ID and PID the fixture can see for its own object, when the
    /// object has one. Absent until the window has a number, and still only an
    /// observation when present.
    let observed: ObservedWindowIdentity?

    let isVisibleLocally     : Bool
    let isMiniaturizedLocally: Bool

    /// Whether the fixture ever asked for this window to be presented. A window
    /// that was never presented is the control case of the experiment.
    let wasPresentedAtLeastOnce: Bool
}

/// ProbeWindowOperating is the window side of the probe: create the fixture's
/// own windows, apply one requested command, and release what was created.
///
/// It is a role so the run can be driven offline by a controlled double that
/// keeps the same ordering, failure and cleanup semantics as the AppKit fixture,
/// without a single AppKit call in a unit run. Every conformer owns only objects
/// it created itself: nothing here may touch, move, hide or close a window,
/// application or process belonging to anybody else.
@MainActor
protocol ProbeWindowOperating {

    /// The PID the fixture's windows belong to, used to tell a row of the
    /// fixture from a row of a window that merely reuses a Window ID.
    var processID: Int { get }

    /// The Window IDs the fixture has registered so far. The parser attributes
    /// rows with this set, so a window the fixture never created is never read
    /// as one of its own.
    var ownedWindowIDs: Set<Int> { get }

    /// Performs one requested command and answers what the window object says
    /// about itself afterwards. Throwing means the command was refused or could
    /// not be applied, and leaves whatever partial effect it had for the caller
    /// to record rather than to retry.
    func perform(_ step: ProbePhaseStep) throws -> ProbeWindowLocalState

    /// Releases only what this fixture created and registered, including after a
    /// partial startup or a throw, and answers what it could verify. It must not
    /// close anything else, stop or terminate the application, or sweep
    /// processes or directories. It stops at the deadline and reports what is
    /// left rather than waiting.
    func cleanUp(deadlineNanoseconds: UInt64) -> ProbeCleanupRecord
}
