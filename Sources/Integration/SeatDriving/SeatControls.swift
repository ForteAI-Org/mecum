//
//  SeatControls.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import AccessibilityActions
import CoreGraphics
import EngineCore
import Foundation
import PerceptionCore

/// SeatControls is `ControlPressing` for an adopted window: presses and value reads go through the
/// accessibility tree by label and value, which do not depend on where the window is. The one
/// geometric read, a toggle's state under a point, is refused, because after the window server moved
/// the window the application's child frames still name its old place.
public struct SeatControls: ControlPressing {

    private let accessibility = AccessibilityController()

    public init() {}

    public func pressControl(labelled label: String, in processID: pid_t) async -> Bool {
        await accessibility.pressControl(labelled: label, in: processID)
    }

    public func controlValue(matchingAny labels: Set<String>, in processID: pid_t) async -> String? {
        await accessibility.controlValue(matchingAny: labels, in: processID)
    }

    public func toggleState(at point: CGPoint, in processID: pid_t) async -> ControlState? {
        nil
    }

    /// Focus is the application's own answer and names no place, so it holds wherever the window is.
    public func focusedFieldValue(in processID: pid_t) async -> String? {
        await accessibility.focusedFieldValue(in: processID)
    }
}
