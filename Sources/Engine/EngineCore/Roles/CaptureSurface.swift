//
//  CaptureSurface.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

/// CaptureSurface is what one capture was taken of: a window, a dialog, a sheet, the union of a
/// window with the pop-up open beside it, or a surface nobody could classify. It belongs to the
/// single capture, never to the application: the same window is a `window` in one capture and part
/// of a `popupUnion` in the next. A union is not a structural surface: it is two windows in one
/// picture, so no structural conclusion is drawn from it. The raw values are the ones the living
/// memory stores.
public enum CaptureSurface: String, Sendable, Equatable, Hashable, CaseIterable {

    case window
    case dialog
    case sheet
    case popupUnion = "popup_union"
    case unknown

    /// The surface the accessibility tree reports for the captured window, from its role and
    /// subrole. A sheet is its own role, or a window with the sheet subrole; a dialog is a window
    /// with a dialog subrole; a standard or floating window is a window. Anything else, including
    /// a window whose subrole was not read, stays `unknown`: a surface is never guessed from a
    /// title or a frame.
    public static func classified(role: String?, subrole: String?) -> CaptureSurface {
        if role == "AXSheet" || subrole == "AXSheet" { return .sheet }
        guard role == "AXWindow" else { return .unknown }
        switch subrole {
            case "AXDialog", "AXSystemDialog"                                : return .dialog
            case "AXStandardWindow", "AXFloatingWindow", "AXSystemFloatingWindow": return .window
            default                                                          : return .unknown
        }
    }
}
