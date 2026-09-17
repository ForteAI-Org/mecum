//
//  WindowSurface.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 15/09/2026.
//

import CoreGraphics

/// WindowSurface is one on-screen row of the window server, attested: which
/// window it is, the level it is drawn at, and whether it is a surface a person
/// can actually see.
///
/// It exists because "which windows does this application have" is a different
/// question from "where is this Window ID". `WindowReference` answers the
/// second and carries no level, and a reader that has to tell a document window
/// from a contextual menu, a tooltip or a fully transparent helper needs the
/// level and the visibility alongside the frame.
///
/// The level is kept as the raw window server number and never as a
/// classification. A Qt application's secondary windows were measured at levels
/// 3 and 4 on this build, so a reader that admitted only level zero would drop
/// exactly the windows a watch is for, and one that admitted only level zero
/// and the pop up menu level would drop them too.
nonisolated public struct WindowSurface: Sendable, Equatable {

    /// The attested window, carrying the frame read in the same pass as the
    /// level. A newly created window has not settled its geometry yet, so a
    /// caller that acts on this frame needs two agreeing readings of it.
    public let reference: WindowReference

    /// `kCGWindowLayer`, as the window server answered it.
    public let level: Int

    /// True when the server shows the surface on screen, its alpha is above
    /// zero and its frame has an area. A window at alpha zero is on screen and
    /// invisible, which is a helper surface and not something to move.
    public let isVisible: Bool

    public init(reference: WindowReference, level: Int, isVisible: Bool) {
        self.reference = reference
        self.level     = level
        self.isVisible = isVisible
    }
}
