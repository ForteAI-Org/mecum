//
//  CaptureLifecycle.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

/// CaptureLifecycle is the externally visible state of one capture owner.
///
/// The generation identifies the one `start` attempt that produced a callback.
/// It is separate from `SeatFrame.displayGeneration`, which identifies a
/// Virtual Display instance. A late callback may therefore be rejected without
/// mistaking a reused ScreenCaptureKit object for the current pipeline.
nonisolated public enum CaptureLifecycle: Sendable, Equatable {

    /// No start has been requested.
    case idle

    /// ScreenCaptureKit has not completed the start request yet.
    case starting(generation: UInt64)

    /// The start request completed and frames may be delivered.
    case running(generation: UInt64)

    /// Stop was requested, but ScreenCaptureKit has not confirmed that the
    /// resource is inactive yet.
    case stopping(generation: UInt64)

    /// The owner is terminal and ScreenCaptureKit has no live resource for it.
    /// Generation zero means it was stopped before its first start.
    case stopped(generation: UInt64)

    /// A lifecycle operation failed. The owner is terminal for `start`; callers
    /// may still call `stop` again while it retains an unconfirmed resource.
    case failed(generation: UInt64, failure: CaptureFailure)

    /// The start generation carried by every state after `idle`.
    public var generation: UInt64? {
        switch self {
        case .idle:
            nil
        case .starting(let generation), .running(let generation),
             .stopping(let generation), .stopped(let generation),
             .failed(let generation, _):
            generation
        }
    }

    /// True only after start completed and before any stop was reported or
    /// requested. Starting and stopping never count as active to a consumer.
    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
