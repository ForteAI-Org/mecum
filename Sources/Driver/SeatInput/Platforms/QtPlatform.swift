//
//  QtPlatform.swift
//  AgentSeatKit
//

import SeatCore

/// Preparation policy for a Qt window driven through the common per-process route.
///
/// DaVinci Resolve's Project Manager accepted background clicks, text, keys and
/// text-selection drags with both prepared and unprepared delivery on 26A428.
/// The prepared path is retained for mouse input and bulk insertion because a
/// custom Qt widget may have different focus handling from that one window.
/// Right clicks remain unprepared so restoring activation cannot dismiss a
/// menu before the caller observes it. Menu, scroll and modal-window effects
/// still need their own live qualification; this policy does not supply it.
nonisolated public struct QtPlatform: InputPlatform {

    public init() {}

    public func preparation(for command: InputCommand) -> Preparation {
        switch command {
            case .click(_, .right, _): .none
            case .click, .drag, .insertText: .internalAppKitState
            case .key, .text, .scroll: .none
        }
    }

    public func preparationSettle(for command: InputCommand) -> Duration {
        guard case .insertText = command else { return .milliseconds(30) }
        return .milliseconds(150)
    }
}
