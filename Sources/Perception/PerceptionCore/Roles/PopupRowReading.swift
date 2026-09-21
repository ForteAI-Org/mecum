//
//  PopupRowReading.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/09/2026.
//

import CoreGraphics
import Foundation

/// PopupRowReading answers the items of the pop-up one process has open, when something other than
/// the painted pixels can see them.
///
/// It fills the one gap `PopupRowSegmenter` cannot: the segmenter cuts the page that is on screen,
/// which is every row a short list has and the first page of a long one. A conformer that reads the
/// application's own accessibility tree sees the whole list, scrolled-out rows included, and says
/// which of them are painted.
///
/// The role only ever adds, like every other accessibility role in this layer. A conformer answers
/// an empty list for an application that exposes nothing, which is a real answer and the caller's
/// cue to keep the pixel rows it already has; it never throws, because a pop-up that cannot be read
/// through accessibility is the ordinary case, not a failure.
///
/// `popupFrame` is the window server's frame for the open pop-up, in global top-left points, and it
/// is what decides WHICH of an application's menus is the one on screen. Without it a conformer has
/// only the tree to go on and must refuse anything ambiguous.
public protocol PopupRowReading: Sendable {

    func popupRows(ofProcess processID: pid_t, popupFrame: CGRect?) async -> [PopupRow]
}
