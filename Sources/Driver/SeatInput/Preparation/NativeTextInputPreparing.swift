//
//  NativeTextInputPreparing.swift
//  AgentSeatKit
//

import SeatCore

/// Optional sender capability for a bounded native composition. Each Command
/// still has its own observation, admission, delivery and confirmation. The
/// enclosing operation owns preparation and its mandatory restoration.
nonisolated public protocol NativeTextInputPreparing: Sendable {
    func withNativeTextInput(
        to window    : WindowReference,
        correlationID: Int64,
        within       : Duration,
        operation    : @escaping @Sendable () async throws -> Void
    ) async throws -> InputCleanupResult

    func cancelNativeTextInput(correlationID: Int64) async -> InputCleanupResult
}

/// Native composition uses physical key presses. Unicode injection, held keys,
/// pointer Commands and menu shortcuts do not belong to this lifetime.
nonisolated package func requireNativeTextInputCommand(_ command: InputCommand) throws {
    guard case let .key(_, text, modifiers, phase, _) = command,
          phase == .press,
          text.isEmpty,
          modifiers.intersection([.command, .control]).isEmpty
    else { throw InputFailure.nativeTextInputRefused(.commandUnsupported) }
}

/// Only a measured family owns a native input context.
nonisolated package func nativeTextInputIsQualified(on platform: any InputPlatform) -> Bool {
    platform is QtPlatform
}
