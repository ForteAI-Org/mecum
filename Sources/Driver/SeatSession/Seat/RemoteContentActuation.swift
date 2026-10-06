//
//  RemoteContentActuation.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/10/2026.
//

import ApplicationServices
import Foundation

/// Why a Command addressed to an out of process panel's content was not
/// actuated through accessibility. None of them is a licence to post the
/// events instead: a routed pointer event into that content activates the
/// host application (ADR 0031).
///
/// Every case but `actionRefused` and `selectedNotOpened` is decided before any
/// action or write. Each case carries the one sentence a worker acts on, as
/// `description`, because the consumers print a thrown error as it comes.
nonisolated public enum RemoteContentActuationRefusal: Error, Sendable, Equatable {

    /// A drag or a scroll. No accessibility counterpart was measured, and
    /// whether a routed one activates the host was never measured either.
    case gestureUnmeasured

    /// A dropdown found only in pixels while a remote file panel is held: its
    /// opener would be a routed click into the panel's content.
    case pixelDropdown

    /// Accessibility answered no element at the point, twice.
    case noElementAtPoint

    /// The element under the point is not proved to be this panel's content: a
    /// node on its path names another window or belongs to another process, or
    /// the path never reaches the surface.
    case outsideRemoteContent

    /// A read on the path failed, or the path exceeded its bound.
    case unreadable

    /// Nothing on the path maps this click to an action. The role is the
    /// innermost element's, or the element's the click reached.
    case unsupportedRole(String)

    /// The click reached a popup or a menu button. Pressed, it opens a menu
    /// window the panel service owns and nothing in the seat follows, which
    /// stays open; `select` opens, chooses and closes it in one action.
    case opensMenu(String)

    /// The application answered the action or write with this AXError. The
    /// action may still have taken effect, so it is never repeated, except
    /// after -25206, which says the element does not support the action.
    case actionRefused(action: String, code: Int32)

    /// An item of a grid that no write to its list's selected children was read
    /// back as selecting. The role is the element under the point.
    case selectionNotVerified(String)

    /// The point is in a column view, whose selection was never measured.
    case columnView

    /// A double click selected its row, and then nothing opened it: no element offered AXOpen
    /// (nil), or AXOpen answered this AXError. The selection took effect.
    case selectedNotOpened(code: Int32?)

    /// True for a refusal that follows an effect or may: the effect is unknown,
    /// and the caller reports it as an action, not as a refusal. Finder answered
    /// AXOpen with -25205 on 06/10/2026 and its window then showed the folder,
    /// so only the unsupported answer, -25206, is read as nothing done.
    public var mayHaveTakenEffect: Bool {
        switch self {
            case .actionRefused(_, let code): code != AXError.actionUnsupported.rawValue
            case .selectedNotOpened         : true
            default                         : false
        }
    }
}

nonisolated extension RemoteContentActuationRefusal: CustomStringConvertible, LocalizedError {

    public var description: String {
        switch self {
            case .gestureUnmeasured:
                "Scrolling or dragging inside a file panel is not supported, and nothing was sent. "
                    + "Reach the folder through the sidebar, select on Where, or Go to Folder."
            case .pixelDropdown:
                "That dropdown inside a file panel has no accessibility control, and a click on it "
                    + "would bring its application to the front, so nothing was sent. Use the sidebar "
                    + "or Go to Folder."
            case .noElementAtPoint:
                "Nothing answers accessibility at that point, so nothing was sent. Observe again "
                    + "and name a button, a row or a field."
            case .outsideRemoteContent:
                "That point is not proved to be inside the window's own content, so nothing was "
                    + "sent. Observe again and name a control of the window."
            case .unreadable:
                "The window's accessibility could not be read there, so nothing was sent. Observe "
                    + "again before retrying."
            case .unsupportedRole(let role):
                "Nothing clickable is at that point (\(role)), so nothing was sent. "
                    + "Name a button, a row or a field."
            case .opensMenu(let role):
                "That \(role) opens a menu a click here cannot follow, so it was not pressed. "
                    + "Use select with this control and the item, or context_menu."
            case .selectionNotVerified(let role) where role == kAXRowRole:
                "The row at that point could not be selected: neither its list's selected rows nor its "
                    + "own selection read back. Observe again before retrying; to reach a folder, use "
                    + "Go to Folder."
            case .selectionNotVerified(let role):
                "The item at that point (\(role)) could not be selected: no selection of its list "
                    + "read back. Switch the view to list view (select on its view button, \"List\"), "
                    + "then click the file's row."
            case .columnView:
                "That point is in a column view, where a click cannot select yet, so nothing was sent. "
                    + "Switch the view to list view (select on its view button, \"List\"), then click the row."
            case .selectedNotOpened(let code?) where code != AXError.actionUnsupported.rawValue:
                "The row was selected, and the application answered AXOpen with error \(code), so it may "
                    + "or may not have opened. Observe before retrying; do not repeat it blindly."
            case .selectedNotOpened(let code):
                "The row was selected, but "
                    + (code == nil ? "nothing in it offers to open it" : "opening it is not supported there "
                        + "(AXOpen answered error \(AXError.actionUnsupported.rawValue))")
                    + ", so it was not opened. A sidebar row opens its folder when selected: observe before "
                    + "acting again."
            case .actionRefused(let action, let code) where code == AXError.actionUnsupported.rawValue:
                "\(action) is not supported there (error \(code)), so it did nothing. Observe again and "
                    + "name another control, a row or a field."
            case .actionRefused(let action, let code):
                "The application answered \(action) with error \(code), and the action may have taken "
                    + "effect. Observe before retrying; do not repeat it blindly."
        }
    }

    public var errorDescription: String? { description }
}

/// RemoteContentActuation is what one accessibility actuation of a remote
/// panel's content did: the action or attribute it used and the role it acted
/// on, for the trace, and the text field it left a caret or a selection in.
nonisolated struct RemoteContentActuation {

    /// A text field an actuation left a caret or a selection in. The seat keeps
    /// it so the next text reaches the field through accessibility as well.
    struct TextField {

        /// True while the element still answers accessibility.
        let isAnswering: () -> Bool

        /// Replaces the field's selection with the text, as typing does, and
        /// answers the field's value read back afterwards, nil when unreadable.
        let replaceSelection: (String) -> Result<String?, RemoteContentActuationRefusal>
    }

    let action   : String
    let role     : String
    let textField: TextField?
}
