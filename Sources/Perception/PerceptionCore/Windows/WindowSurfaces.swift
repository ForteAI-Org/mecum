//
//  WindowSurfaces.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics

/// SurfaceKind is what a window is, for the two questions asked of an app's window list: is it an
/// open pop-up, and is it the surface the agent drives.
public enum SurfaceKind: String, Sendable, Equatable {
    /// A pop-up parked on a menu layer (21 through 200).
    case popupLayer
    /// A dropdown drawn as an ordinary window by a toolkit that paints its own widgets.
    case floatingList
    /// A window worth driving: a document, a modal, a floating palette.
    case window
    /// A status item, tooltip, drag shadow or sliver: never the surface.
    case chrome
}

/// SurfaceVerdict is one window, its kind, and the clause that decided it. The clause exists so a
/// miss carries the next move instead of silence.
public struct SurfaceVerdict: Sendable, Equatable {

    public let row: WindowRow
    public let kind: SurfaceKind
    public let why: String

    public init(row: WindowRow, kind: SurfaceKind, why: String) {
        self.row  = row
        self.kind = kind
        self.why  = why
    }
}

/// WindowSurfaces is the classifier's answer about one app's windows: every verdict front to back,
/// the open pop-up frames front to back, and the one window to perceive and act on.
public struct WindowSurfaces: Sendable, Equatable {

    public let verdicts: [SurfaceVerdict]
    public let popups: [CGRect]
    public let interaction: WindowRow?

    public init(verdicts: [SurfaceVerdict], popups: [CGRect], interaction: WindowRow?) {
        self.verdicts    = verdicts
        self.popups      = popups
        self.interaction = interaction
    }

    public var hasOpenPopup: Bool { !popups.isEmpty }
}
