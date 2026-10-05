//
//  ActionCommand.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import AppKit
import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import Memory
import PerceptionCore

/// ActFailure is an action that did not land: the process exits non zero once the seat is down.
struct ActFailure: Error, CustomStringConvertible {

    let kind: ActOutcomeKind

    init(_ kind: ActOutcomeKind) { self.kind = kind }

    var description: String { "the action ended \(kind.rawValue)" }
}

/// ActionCommand runs one of the seven actions the app's tools offer as a direct command:
///
///     mecum <operation> <app> <operation's words> [--seat] [--window <title>] [--dry-run] ...
///
/// with the operation's words as `ActionGrammar` reads them. The whole command line is checked and
/// the action decoded by the tools' decoder before an application, a Seat or the memory is touched.
/// The call, its samples and what the brain learned go to the living memory under the invocation's
/// trace, from the `cli` source (`StepRunner`). It prints the outcome kind, the sentence and the scene
/// after acting, so a person sees what a model would be told.
///
/// `act` drives the real screen without `--seat`, as it always has; `select` and the five inputs run
/// on the Seat only, as the app's session runs them. Exit status: 0 for `found_acted` and `dry_run`
/// (and `acted_noop` for `act`, as before, or for `set_toggle`), 1 for any other outcome or error.
enum ActionCommand {

    static func run(_ operation: String, arguments: [String]) async throws {
        guard let tool = ActionGrammar.operation(operation) else {
            throw UsageError.missing("an operation: " + ActionGrammar.operations.map(\.rawValue).joined(separator: ", "))
        }
        let invocation = try Invocation(arguments: arguments, spec: CommandSpecs.action(tool))
        let word = try invocation.positional(0, "<app>")
        let own = ActionGrammar.spec(tool)
        let request = try ActionGrammar.request(tool, Words.Parsed(
            positionals: Array(invocation.positionals.dropFirst()),
            values     : invocation.values.filter { own.valued.contains($0.key) },
            flags      : invocation.flags.intersection(own.flags)
        ))
        let seat = invocation.flags.contains("seat")
        if tool != .act, !seat {
            throw UsageError.missing("--seat (\(tool.rawValue) runs on the Seat, as the app's session runs it)")
        }
        let application = try ApplicationLookup.running(word)
        let memory = await CLIMemory.open(invocation)
        let app = AppContextIdentity(application)
        let flags = invocation.flags
        do {
            let outcome: ActOutcome
            if seat {
                var answered: ActOutcome?
                try await SeatRuntime.withSeat(application, invocation) { target in
                    let performer = try EngineStepPerformer(
                        runtime: Runtime(invocation: invocation, seat: target, memory: memory), target: target,
                        application: application, allowsDestructive: flags.contains("allow-destructive"),
                        dryRun: flags.contains("dry-run")
                    )
                    let outcome = try await StepRunner.single(request, performer: performer, memory: memory, trace: CLITrace(),
                                                              app: app, evidence: invocation.options["evidence"])
                    answered = outcome
                    guard accepts(request, outcome.kind) else { throw ActFailure(outcome.kind) }
                }
                guard let answered else { throw ActFailure(.honestMiss) }
                outcome = answered
            } else {
                let performer = try EngineStepPerformer(
                    runtime: Runtime(invocation: invocation, memory: memory), target: nil, application: application,
                    allowsDestructive: flags.contains("allow-destructive"), dryRun: flags.contains("dry-run")
                )
                outcome = try await StepRunner.single(request, performer: performer, memory: memory, trace: CLITrace(), app: app)
            }
            guard accepts(request, outcome.kind) else { throw ActFailure(outcome.kind) }
        } catch {
            await memory.close()
            throw error
        }
        await memory.close()
    }

    /// The outcomes a direct command exits 0 for: `found_acted` and `dry_run` always; `acted_noop`
    /// for `act` with any verb (its behaviour before this command took the other actions) and,
    /// by the tools' rule, for `set_toggle`.
    static func accepts(_ request: AgentCallRequest, _ kind: ActOutcomeKind) -> Bool {
        if kind == .foundActed || kind == .dryRun || request.accepts(kind) { return true }
        if case .act = request, kind == .actedNoop { return true }
        return false
    }
}
