//
//  PhaseInterval.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/10/2026.
//

#if MECUM_PHASES
import os

/// PhaseInterval is one `os_signpost` interval of a phase measurement build.
///
/// The whole file is compiled only under the `MECUM_PHASES` condition, which no default
/// configuration sets (SwiftPM or Xcode): a normal build has this module empty, and every call site
/// is inside its own `#if MECUM_PHASES`. A measurement build is made optimized on purpose, since
/// Swift in Debug would skew the numbers. `Tools/Driver/Phases/phase-table.py` turns the
/// signposts into a table.
///
/// An interval has its own signpost ID, so two intervals with one name that overlap in different
/// tasks never pair up wrongly. An interval whose operation threw is simply never ended, and the
/// table ignores it. Signposts cost almost nothing while no tool listens.
public struct PhaseInterval: Sendable {

    private static let signposter = OSSignposter(subsystem: "dev.forte.Mecum.phases", category: "phases")

    private let name : StaticString
    private let state: OSSignpostIntervalState

    private init(name: StaticString, state: OSSignpostIntervalState) {
        self.name  = name
        self.state = state
    }

    /// Starts an interval. `detail` is free text shown with the begin event, such as a tool's name.
    public static func begin(_ name: StaticString, _ detail: String = "") -> PhaseInterval {
        let id = signposter.makeSignpostID()
        return PhaseInterval(
            name : name,
            state: signposter.beginInterval(name, id: id, "\(detail, privacy: .public)")
        )
    }

    /// Emits one point event with a free-text message, for a fact that has no duration: a frame's
    /// status, a preview state change. `Tools/Driver/Phases/phase-table.py` ignores events.
    public static func event(_ name: StaticString, _ detail: String) {
        signposter.emitEvent(name, id: signposter.makeSignpostID(), "\(detail, privacy: .public)")
    }

    /// Ends the interval started by `begin`. Call it once.
    public func end() {
        Self.signposter.endInterval(name, state)
    }

    /// Ends the interval with a detail known only at its end, such as why a wait ended; the table
    /// names the phase with it in place of the begin's. Call it, or `end()`, once.
    public func end(_ detail: String) {
        Self.signposter.endInterval(name, state, "\(detail, privacy: .public)")
    }

    /// Runs `body` inside one interval, for work that is an expression and not a statement.
    public static func measure<T>(
        _ name: StaticString,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let phase = begin(name)
        defer { phase.end() }
        return try await body()
    }
}
#endif
