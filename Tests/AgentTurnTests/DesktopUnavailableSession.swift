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
/// turn core's tests, which must not reach the desktop: the app's test double
/// of the same name, copied here so the moved proofs read as they did.
///
/// `open` refuses in a sentence the agent can repeat, and every other call
/// answers as when no session is open.
@MainActor
final class DesktopUnavailableSession: AutomationSessionOperating {

    /// Always nil: no session is ever open, so every session ID is stale.
    let id: UUID? = nil

    static let refusal = "Computer access is unavailable in this version. Continue without it and mention "
        + "the limitation when relevant."

    private static let noSession = AutomationFailure(
        "No app is open. This version cannot open apps for workers."
    )

    func open(application: String, window: String?, context: ActionContext) async throws -> SceneSnapshot {
        throw AutomationFailure(Self.refusal)
    }

    func observe(context: ActionContext) async throws -> SceneSnapshot {
        throw Self.noSession
    }

    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?,
             context: ActionContext) async throws -> ActOutcome {
        throw Self.noSession
    }

    func select(control: String, item: String, context: ActionContext) async throws -> ActOutcome {
        throw Self.noSession
    }

    func deliver(_ input: InputRequest.Input, section: String?, context: ActionContext) async throws -> ActOutcome {
        throw Self.noSession
    }

    /// Nothing is open, so there is nothing to release.
    func close() async {}
}
