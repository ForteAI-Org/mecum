//
//  ShareableContent.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import Foundation
import ScreenCaptureKit

/// ContinuationGate resumes a continuation exactly once, whoever gets there
/// first.
///
/// It exists because two of the ScreenCaptureKit completion handlers the kit
/// depends on have been seen not to arrive at all, so every one of them races a
/// deadline. Without the gate, the second of the two callbacks resumes a
/// continuation that is already spent, which is a crash and not an error. With
/// it, the loser is a no-op and the abandoned callback, if it ever fires, finds
/// nothing to do.
///
/// `@unchecked Sendable` over an `NSLock`: the continuation is the only mutable
/// state, and it is never read outside the lock.
nonisolated final class ContinuationGate<Value>: @unchecked Sendable {

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Handoff<Value>, any Error>?

    init(_ continuation: CheckedContinuation<Handoff<Value>, any Error>) {
        self.continuation = continuation
    }

    func resolve(_ result: Result<Value, any Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result.map(Handoff.init(value:)))
    }
}

/// Handoff carries one value from a ScreenCaptureKit completion handler to the
/// caller that is waiting for it.
///
/// `SCShareableContent` and `CMSampleBuffer` are not `Sendable` and the
/// completion handlers are, so the compiler has no way to see what is true
/// here: the framework builds the value and the coordinator publishes the same
/// immutable result to compatible read-only waiters. No waiter mutates it, and
/// late results are discarded. This type says that invariant once instead of
/// adding an `@unchecked` at every call site.
nonisolated struct Handoff<Value>: @unchecked Sendable {
    let value: Value
}

nonisolated extension Duration {

    /// Seconds as a `Double`, for the Dispatch and CoreMedia APIs that take
    /// one. `components` is whole seconds plus attoseconds.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// shareableContent lists what ScreenCaptureKit is willing to capture, with a
/// deadline.
///
/// It is the first call a missing Screen Recording grant blocks, and it is also
/// the one that answers "the Virtual Display is not there yet" while the
/// display is still being published, so both of its failure modes are named:
/// the timeout is `timedOut(.shareableContent)` and a refusal keeps
/// ScreenCaptureKit's own domain and code.
///
/// Desktop windows are included, because the Adopted Window of a seat is not
/// necessarily on screen from the User Seat's point of view.
nonisolated public func shareableContent(
    timeout: Duration = .seconds(5)
) async throws -> SCShareableContent {

    try await shareableContent(deadline: CaptureDeadline(timeout: timeout))
}

/// The internal form receives the public operation's original deadline. A
/// caller that already spent time planning gets only the remaining budget.
nonisolated func shareableContent(
    deadline: CaptureDeadline
) async throws -> SCShareableContent {

    let handoff: Handoff<SCShareableContent> = try await CaptureFrameworkCoordinator.shared.value(
        key      : .shareableContent,
        step     : .shareableContent,
        deadline : deadline
    ) { completion in
        SCShareableContent.getExcludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        ) { content, error in
            if let content {
                completion(.success(Handoff(value: content)))
            } else {
                completion(.failure(
                    error.map(CaptureFailure.wrapping) ?? CaptureFailure.frameUnavailable
                ))
            }
        }
    }
    return handoff.value
}
