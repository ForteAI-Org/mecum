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
/// use the measured unprepared path. Drag and bulk insertion retain the
/// conservative preparation until those surfaces have their own measurements.
/// A controlled Qt 6 widget fixture has also qualified scrolling, routed and
/// native popup choices, and a context-menu action. DaVinci's menu has also
/// opened, captured and closed after the Search locator correction; a menu
/// item action in DaVinci remains unmeasured.
nonisolated public struct QtPlatform: InputPlatform {

    public init() {}

    public func preparation(for command: InputCommand) -> Preparation {
        switch command {
            case .click, .key, .text, .scroll: .none
            case .drag, .insertText: .internalAppKitState
        }
    }

    public func preparationSettle(for command: InputCommand) -> Duration {
        guard case .insertText = command else { return .milliseconds(30) }
        return .milliseconds(150)
    }
}
