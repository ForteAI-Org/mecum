//
//  QtPlatform.swift
//  AgentSeatKit
//

import SeatCore

/// Preparation policy for a Qt window driven through the common per-process route.
///
/// DaVinci Resolve's Project Manager accepted background clicks, text, keys and
/// text-selection drags with both prepared and unprepared delivery on 26A428.
/// A prepared click on a followed Qt dialog caused an activation before its
/// Cancel event, so the seat's focus gate refused that event. Clicks therefore
/// use the measured unprepared path. Bulk insertion also remains unprepared:
/// Qt Quick's TextInput lost active focus when its preparation was restored
/// on 26A434. Its text and the next modified arrow key worked without that step.
/// DaVinci Search and the controlled Qt 6 fixture qualify selection drags.
/// A controlled Qt 6 widget fixture has also qualified scrolling, routed and
/// native popup choices, and a context-menu action. DaVinci's menu has also
/// opened and captured after the Search locator correction; its Select All
/// action selected the temporary search text through a scoped menu click.
nonisolated public struct QtPlatform: InputPlatform {

    public init() {}

    public func preparation(for command: InputCommand) -> Preparation {
        switch command {
            case .click, .key, .text, .scroll, .insertText: .none
            case .drag: .internalAppKitState
        }
    }

    public func windowArrivalHorizon(after command: InputCommand) -> Duration {
        guard case .click = command else { return .zero }
        return .seconds(1)
    }
}
