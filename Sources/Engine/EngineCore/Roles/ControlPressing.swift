//
//  ControlPressing.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import CoreGraphics
import Foundation
import PerceptionCore

/// ControlPressing acts on and reads a window's controls by name rather than by coordinate, where
/// the application exposes them: opening a dropdown with its own press action, reading a combo
/// box's current value, reading a toggle's state under a point, reading the focused field's text.
///
/// Every answer is about the current moment. A conformer that cannot see the tree answers false or
/// nil; it never guesses. `pressControl` opens a CLOSED list only: pressing an open one closes it,
/// and an option row often shares the control's current text.
public protocol ControlPressing: Sendable {

    /// Presses the combo box or pop-up button whose value or title is `label`. True when a control
    /// was found and accepted the press.
    func pressControl(labelled label: String, in processID: pid_t) async -> Bool

    /// The current value of the one control whose value, normalized, is among `labels`; nil when none
    /// or more than one qualifies.
    func controlValue(matchingAny labels: Set<String>, in processID: pid_t) async -> String?

    /// The state of the stateful control under a global point, when the application reports one.
    func toggleState(at point: CGPoint, in processID: pid_t) async -> ControlState?

    /// The value of the text field or text area that holds the keyboard focus in the application; nil
    /// when none does or the application does not say. What typed text is verified by.
    func focusedFieldValue(in processID: pid_t) async -> String?

    /// Presses the one enabled menu item titled `title` painted inside `menuFrame`, an open native
    /// menu. True when a press was made, even one the application refused, because it may have
    /// acted; false when no such item exists, and only then may the keyboard choose instead.
    func pressMenuItem(titled title: String, within menuFrame: CGRect, in processID: pid_t) async -> Bool
}

extension ControlPressing {

    /// A conformer that cannot read menu items presses none; the keyboard chooses.
    public func pressMenuItem(titled title: String, within menuFrame: CGRect, in processID: pid_t) async -> Bool {
        false
    }
}
