//
//  ProviderTurnRunning.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import ChatCore
import CLIProviders
import Foundation

/// ProviderTurnRunning is the provider side of one command line turn, one turn at a time: the signed-in
/// command line's child process in the product (`CLIProvider`), and a scripted stand-in in the controlled
/// tests, which speaks to the same loopback host the bridge does. `cancel` interrupts the running turn,
/// whose `run` then throws; `waitUntilStopped` returns once the turn has ended. Main-actor bound like the
/// provider. `AgentTurnHost` is handed one at composition and retains it for its life.
@MainActor
public protocol ProviderTurnRunning: AnyObject {
    func run(
        _ turn    : ProviderTurn,
        executable: URL,
        onStart   : @MainActor (ChildProcessIdentity) -> Void,
        onEvent   : @escaping @MainActor (ProviderEvent) throws -> Void
    ) async throws
    func cancel()
    func waitUntilStopped() async
}

extension CLIProvider: ProviderTurnRunning {}
