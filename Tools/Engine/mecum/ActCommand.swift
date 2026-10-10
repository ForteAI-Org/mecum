import AutomationRuntime
//
//  ActCommand.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import AppKit
import Engine
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

/// ActCommand performs one verified action and prints the outcome kind, the sentence, and the scene
/// after acting, so a person sees exactly what a model would be told.
enum ActCommand {

    static func run(_ invocation: Invocation) async throws {
        let application = try ApplicationLookup.running(try invocation.positional(0, "<app>"))
        let arguments = try ActArguments(invocation)
        let request = ActionRequest(
            processID   : application.processIdentifier,
            bundleID    : application.bundleIdentifier ?? "pid.\(application.processIdentifier)",
            appName     : application.localizedName ?? "pid \(application.processIdentifier)",
            target      : arguments.target,
            verb        : arguments.verb,
            section     : arguments.section,
            desiredState: arguments.desiredState,
            isDryRun    : invocation.flags.contains("dry-run")
        )
        if invocation.flags.contains("seat") {
            try await SeatRuntime.withSeat(application, invocation) { seat in
                try await finishSingle(request, Runtime(invocation: invocation, seat: seat), invocation)
            }
        } else {
            try await finishSingle(request, Runtime(invocation: invocation), invocation)
        }
    }

    /// Borrows a runtime for one action; its caller owns flushing and Seat cleanup. The action is a call
    /// of the living memory, as an agent's is: confirmed before it acts, ended with its check after.
    /// A start the memory does not confirm acts on nothing; an end it cannot save is reported and
    /// throws once the outcome is printed.
    /// Acts once and ends the call it records. `step` is the recorder of a batch's step its batch already
    /// started; without one, the call is the command's own and is begun here.
    static func perform(
        _ request: ActionRequest,
        _ runtime: Runtime,
        _ invocation: Invocation,
        step: CallRecorder? = nil
    ) async throws -> ActOutcomeKind {
        let recorder = step ?? runtime.commandLineRecorder()
        let call = AgentCallRequest.act(target: request.target, verb: request.verb, value: request.desiredState,
                                        section: request.section)
        if !request.isDryRun, step == nil {
            do {
                try await recorder.begin(call, app: AppContextIdentity(bundleID: request.bundleID))
            } catch {
                print("refused: Mecum's memory did not confirm the action before it could act (\(error)); nothing was done")
                return .refused
            }
        }
        let engine = runtime.engine(recorder: recorder,
                                    allowsDestructive: invocation.flags.contains("allow-destructive"))
        let started = ContinuousClock.now
        let outcome = await engine.act(request)
        let elapsed = started.duration(to: .now)
        print("\(outcome.kind.rawValue): \(outcome.message)")
        if let scene = outcome.scene {
            print("")
            print(scene.text())
        }
        FileHandle.standardError.write(Data("acted in \(elapsed)\n".utf8))
        if !request.isDryRun {
            try await CommandLineCall.end(recorder, outcome: outcome, tool: .act)
        }
        return outcome.kind
    }

    private static func finishSingle(_ request: ActionRequest, _ runtime: Runtime, _ invocation: Invocation) async throws {
        let kind = try await perform(request, runtime, invocation)
        await runtime.finish()
        let acceptable: Set<ActOutcomeKind> = [.foundActed, .dryRun, .actedNoop]
        if !acceptable.contains(kind) { throw ActFailure(kind) }
    }
}
