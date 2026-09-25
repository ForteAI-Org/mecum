//
//  DesktopUnavailableSession.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AutomationRuntime
import EngineCore
import Foundation
import PerceptionCore

/// DesktopUnavailableSession is an application session with no seat, for the
/// tests of a host that must not reach the desktop.
///
/// `open` refuses in a sentence the agent can repeat, and every other call
/// answers as when no session is open. The app supplies SeatBroker's own
/// conformer instead (§22.3); building the command line's `AutomationSession`
/// anywhere in the app would start a seat outside the broker.
@MainActor
final class DesktopUnavailableSession: AutomationSessionOperating {

    /// Always nil: no session is ever open, so every session ID is stale.
    let id: UUID? = nil

    static let refusal = "Computer access is unavailable in this version. Continue without it and mention "
        + "the limitation when relevant."

    private static let noSession = AutomationFailure(
        "No app is open. This version cannot open apps for workers."
    )

    func open(application: String, window: String?) async throws -> SceneSnapshot {
        throw AutomationFailure(Self.refusal)
    }

    func observe() async throws -> SceneSnapshot {
        throw Self.noSession
    }

    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws
        -> ActOutcome {
        throw Self.noSession
    }

    func select(control: String, item: String) async throws -> ActOutcome {
        throw Self.noSession
    }

    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        throw Self.noSession
    }

    /// Nothing is open, so there is nothing to release.
    func close() async {}
}
