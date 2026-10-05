//
//  VerticalInvocation.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 03/10/2026.
//

import AutomationRuntime
import Darwin
import Foundation

/// VerticalInvocation is one direct command (`scene`, one of the seven actions, `batch`) as the one owner
/// of its stop. The command runs as one task bound to the invocation's `MemoryFinalizationScope`, the
/// owner of its memory finalizations. A stop (SIGINT or SIGTERM through `TerminalSignals`, the first one
/// only) stops that same scope, so the memory's one budget runs from that instant, and cancels the task:
/// no new action starts (a call is refused in `begin`, a batch's next step never runs), an action in
/// flight ends where the engine honours the cancellation, and what is known is recorded as it is. The
/// command's cleanup still runs inside the task: the Seat's release in a task of its own that the
/// cancellation does not reach (`SeatRuntime.hold`), the memory's close after it. The process exits only
/// when the task has ended, cleanup included: 0 when the command did what was asked, 1 for an error, and
/// 128 plus the signal after a stop, 130 for SIGINT and 143 for SIGTERM, whatever the command had reached.
/// A later signal starts nothing: no second stop and no second cleanup. Nothing here bounds the shutdown
/// as a whole; nothing survives SIGKILL or a crash.
@MainActor
final class VerticalInvocation {

    /// How the command's task ended.
    enum Ending {
        /// The command did what was asked, no stop received.
        case finished
        /// The command failed, no stop received.
        case failed(any Error)
        /// A stop was received; the command's own error when it ended with one.
        case stopped(signal: Int32, error: (any Error)?)
    }

    /// The owner of the invocation's memory finalizations, bound around the command's task.
    let scope = MemoryFinalizationScope()

    /// The first stop received, nil while there was none.
    private(set) var signal: Int32?

    private var work: Task<Void, any Error>?
    private let say: (String) -> Void

    init(say: @escaping (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) {
        self.say = say
    }

    /// Runs the command as the invocation's one task and answers once it has ended, cleanup included.
    /// A stop received before this starts the task cancelled.
    func run(_ command: @escaping @MainActor () async throws -> Void) async -> Ending {
        let scope = self.scope
        let work = Task { @MainActor in
            try await MemoryFinalizationScope.$current.withValue(scope) { try await command() }
        }
        self.work = work
        if signal != nil { work.cancel() }
        let result = await work.result
        self.work = nil
        switch (result, signal) {
            case (.success, nil)             : return .finished
            case (.failure(let error), nil)  : return .failed(error)
            case (.success, let signal?)     : return .stopped(signal: signal, error: nil)
            case (.failure(let error), let signal?): return .stopped(signal: signal, error: error)
        }
    }

    /// The stop: the first one stops the scope and cancels the command; any later one does nothing.
    func stop(_ number: Int32) {
        guard signal == nil else { return }
        signal = number
        scope.stop()
        say("mecum: \(Self.name(number)) received: no new action; the Seat and the memory are let go before exit")
        work?.cancel()
    }

    /// The process's exit status for an ending.
    static func status(_ ending: Ending) -> Int32 {
        switch ending {
            case .finished                  : 0
            case .failed                    : 1
            case .stopped(let signal, _)    : 128 + signal
        }
    }

    /// The last line on standard error for an ending, nil when there is nothing to say.
    static func summary(_ ending: Ending) -> String? {
        switch ending {
            case .finished: return nil
            case .failed(let error): return "mecum: \(error)"
            case .stopped(let signal, let error):
                guard let error, !(error is CancellationError) else { return "mecum: stopped by \(name(signal))" }
                return "mecum: stopped by \(name(signal)): \(error)"
        }
    }

    static func name(_ signal: Int32) -> String {
        switch signal {
            case SIGINT : "SIGINT"
            case SIGTERM: "SIGTERM"
            default     : "signal \(signal)"
        }
    }

    /// The entry point's composition: the signals, the command, the summary, the exit.
    static func main(_ command: @escaping @MainActor () async throws -> Void) async -> Never {
        let invocation = VerticalInvocation()
        let signals = TerminalSignals { invocation.stop($0) }
        let ending = await invocation.run(command)
        signals.stop()
        if let line = summary(ending) { invocation.say(line) }
        exit(status(ending))
    }
}
