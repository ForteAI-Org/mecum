//
//  NativeTextInputFailure.swift
//  AgentSeatKit
//

import SeatCore

/// The structured reason carried by InputFailure.nativeTextInputRefused.
nonisolated public enum NativeTextInputRefusal: Sendable, Equatable {
    case unsupported
    case contextActive
    case contextClosed
    case contextMismatch
    case commandUnsupported
    case invalidDeadline
}

/// A scope error preserves cleanup separately from its cause. Commands whose
/// Receipts were already returned are still posted and must never be replayed.
nonisolated public struct NativeTextInputFailure: Error, Sendable {
    public let cause  : any Error
    public let cleanup: InputCleanupResult

    public init(
        cause  : any Error,
        cleanup: InputCleanupResult
    ) {
        self.cause   = cause
        self.cleanup = cleanup
    }
}

