//
//  PopupRow.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/09/2026.
//

import CoreGraphics

/// PopupRow is one item of an open pop-up, whichever eye found it: the pixels that cut the painted
/// list into rows, or an accessibility tree that names every row at once.
///
/// The two sources differ in exactly one way, and the type carries it. A pixel row is always on
/// screen, because it was read off the screen; an accessibility row may be scrolled out of the
/// painted page and still be a real, selectable item, measured on TextEdit's font list, where the
/// scene held 20 visible families and "Helvetica" sat two pages below. A row that is not on screen
/// has no honest place to click, which is why `frame` is optional and `isOnScreen` is its own
/// answer rather than a guess from a frame being present.
public struct PopupRow: Sendable, Equatable {

    /// The item's name, what an agent names when it acts.
    public var title: String
    /// Whether the item can be chosen at all.
    public var isEnabled: Bool
    /// Whether the item is painted right now. False for a row scrolled out of a long menu: real,
    /// selectable by name, and never a coordinate to click.
    public var isOnScreen: Bool
    /// The row's own rect in the pop-up's coordinate space, or nil where nothing usable was read.
    public var frame: CGRect?
    /// The item's place in the list, top to bottom and zero based: the identity that survives
    /// scrolling, and what a keyboard plan counts with.
    public var order: Int

    public init(title: String, isEnabled: Bool = true, isOnScreen: Bool = true,
                frame: CGRect? = nil, order: Int) {
        self.title      = title
        self.isEnabled  = isEnabled
        self.isOnScreen = isOnScreen
        self.frame      = frame
        self.order      = order
    }

    /// The same row as the pixel segmenter cut it: painted by construction, and always framed.
    public init(_ row: PopupRowSegmenter.Row, order: Int) {
        self.init(title: row.text, isEnabled: true, isOnScreen: true, frame: row.rect, order: order)
    }

    /// The segmenter's rows as pop-up rows, so a caller that prefers accessibility can fall back to
    /// the pixels without changing vocabulary.
    public static func rows(_ rows: [PopupRowSegmenter.Row]) -> [PopupRow] {
        rows.enumerated().map { PopupRow($1, order: $0) }
    }
}
