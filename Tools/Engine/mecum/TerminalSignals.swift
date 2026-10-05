//
//  TerminalSignals.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 03/10/2026.
//

import Darwin
import Foundation

/// TerminalSignals translates SIGINT/SIGTERM into one asynchronous stop owned by the terminal composition:
/// the chat's (`ChatCommand`) or a direct command's (`VerticalInvocation`). The signals are ignored at the
/// POSIX level and read from dispatch sources on the main queue, so nothing runs in a signal handler; the
/// first one is handed to `onStop` with its number, on the main actor, and every later one is dropped.
/// `stop()` gives both signals their default action back.
final class TerminalSignals {
    private var sources: [any DispatchSourceSignal] = []
    private var fired = false
    private let stopAction: (Int32) -> Void

    init(onStop: @escaping (Int32) -> Void) {
        stopAction = onStop
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    guard let self, !self.fired else { return }
                    self.fired = true
                    self.stopAction(number)
                }
            }
            source.resume()
            sources.append(source)
        }
    }

    func stop() {
        for source in sources { source.cancel() }
        sources.removeAll()
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
    }
}
