//
//  WindowRow.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics
import Foundation

/// WindowRow is one window of an app as the window server lists it, reduced to what classifying it
/// needs: its layer, its frame in global top-left points, its title, and its number.
///
/// An array of rows is in the window server's front-to-back order. Pure data, so the classifier
/// over it is decided by tests rather than by a screen.
public struct WindowRow: Sendable, Equatable, Hashable {

    public let layer: Int
    public let frame: CGRect
    public let title: String?
    /// The window server's number, for naming a window in a diagnostic.
    public let number: Int

    public init(layer: Int, frame: CGRect, title: String? = nil, number: Int = 0) {
        self.layer  = layer
        self.frame  = frame
        self.title  = title
        self.number = number
    }

    var isUntitled: Bool { (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The title a scene of window `number` carries: what the window server calls it now, in `rows`, so
    /// a renamed window and one adopted after it opened are named as they are shown; `fallback` when the
    /// rows do not list that window with a title, as without the Screen Recording grant.
    public static func title(ofWindow number: Int, in rows: [WindowRow], fallback: String) -> String {
        guard let row = rows.first(where: { $0.number == number }), !row.isUntitled, let title = row.title else {
            return fallback
        }
        return title
    }
}
