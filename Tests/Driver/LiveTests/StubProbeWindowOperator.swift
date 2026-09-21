//
//  StubProbeWindowOperator.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import Foundation

/// StubProbeWindowOperator stands in for the AppKit fixture with the same
/// contract and no AppKit at all: it registers ownership before it reports a
/// window, refuses a command for a window that was never created, can be told to
/// fail at a chosen step, and reports a cleanup that is verified, failed or
/// unknown and incomplete.
///
/// It preserves the ordering and the failure semantics the run depends on, which
/// is the only reason an offline test of the run means anything. It is a double
/// of the fixture, never of the window server: nothing in it answers a window
/// list or claims a surface exists.
@MainActor
final class StubProbeWindowOperator: ProbeWindowOperating {

    let processID: Int

    /// The step that throws when it is reached, and what it throws.
    private let failingStep: ProbePhaseStep?
    private let failure    : ProbeFixtureFailure

    /// The cleanup this double reports, so a test can drive an incomplete one.
    private let cleanupResult: ProbeCleanupRecord?

    private var registered  : [FixtureWindowToken] = []
    private var presented   : Set<FixtureWindowToken> = []
    private var windowIDs   : [FixtureWindowToken: Int] = [:]
    private var creationCount = 0

    private(set) var performedSteps: [ProbePhaseStep] = []
    private(set) var cleanUpCount                     = 0
    private(set) var cleanUpDeadline: UInt64?

    init(
        processID    : Int = 4242,
        failingStep  : ProbePhaseStep?     = nil,
        failure      : ProbeFixtureFailure = .unsupported(.close),
        cleanupResult: ProbeCleanupRecord? = nil
    ) {
        self.processID     = processID
        self.failingStep   = failingStep
        self.failure       = failure
        self.cleanupResult = cleanupResult
    }

    var ownedWindowIDs: Set<Int> { Set(windowIDs.values) }

    /// The tokens ownership was registered for, including the ones a later phase
    /// failed on. A test reads it to check that a partial startup still leaves
    /// something to release.
    var registeredTokens: [FixtureWindowToken] { registered }

    func perform(_ step: ProbePhaseStep) throws -> ProbeWindowLocalState {

        performedSteps.append(step)
        if step == failingStep { throw failure }

        if step.isCreation {
            guard !registered.contains(where: { $0.role == step.role })
            else { throw ProbeFixtureFailure.alreadyCreated(step.role) }
            creationCount += 1
            let token = FixtureWindowToken(
                identifier   : UUID(),
                role         : step.role,
                creationOrder: creationCount
            )
            registered.append(token)
            // A never presented window is registered with a Window ID as well:
            // the all reading is exactly where such a surface may show up.
            windowIDs[token] = 900 + creationCount
            return state(of: token)
        }

        guard let token = registered.first(where: { $0.role == step.role })
        else { throw ProbeFixtureFailure.notCreated(step.role) }

        if step == .makeVisible || step == .showAgain { presented.insert(token) }
        return state(of: token)
    }

    func cleanUp(deadlineNanoseconds: UInt64) -> ProbeCleanupRecord {
        cleanUpCount   += 1
        cleanUpDeadline = deadlineNanoseconds
        if let cleanupResult { return cleanupResult }
        let released = registered.count
        registered.removeAll()
        windowIDs.removeAll()
        return ProbeCleanupRecord(
            status            : .verified,
            releasedTokenCount: released,
            residualTokens    : [],
            notes             : ["the double released every token it registered"],
            priorErrors       : []
        )
    }

    private func state(of token: FixtureWindowToken) -> ProbeWindowLocalState {
        ProbeWindowLocalState(
            token                  : token,
            observed               : windowIDs[token].map {
                ObservedWindowIdentity(windowID: $0, processID: processID)
            },
            isVisibleLocally       : presented.contains(token),
            isMiniaturizedLocally  : false,
            wasPresentedAtLeastOnce: presented.contains(token)
        )
    }
}
