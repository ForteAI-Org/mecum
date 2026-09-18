//
//  MenuCommand.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import Foundation
import PerceptionCore

/// MenuCommand is one command discovered by read-only enumeration of an application's menu bar.
/// Recording a command never executes it. `path` is the human menu path; `topLevelTitle` lets a
/// caller re-find the top menu when its index shifts.
public struct MenuCommand: Sendable, Equatable, Codable {

    public var path: [String]
    public var topLevelTitle: String
    public var identifier: String?
    public var hasSubmenu: Bool
    public var enabled: Bool
    /// The checkmark or state glyph, when any.
    public var markChar: String?
    /// The keyboard shortcut key, when any.
    public var cmdChar: String?
    public var firstSeen: Date
    public var lastSeen: Date

    public init(
        path         : [String],
        topLevelTitle: String,
        identifier   : String? = nil,
        hasSubmenu   : Bool = false,
        enabled      : Bool = true,
        markChar     : String? = nil,
        cmdChar      : String? = nil,
        firstSeen    : Date,
        lastSeen     : Date
    ) {
        self.path          = path
        self.topLevelTitle = topLevelTitle
        self.identifier    = identifier
        self.hasSubmenu    = hasSubmenu
        self.enabled       = enabled
        self.markChar      = markChar
        self.cmdChar       = cmdChar
        self.firstSeen     = firstSeen
        self.lastSeen      = lastSeen
    }

    public var leaf: String { path.last ?? "" }

    /// The merge key is the full menu path, never the accessibility identifier: some applications
    /// reuse one identifier across hundreds of items.
    public var key: String { path.joined(separator: "/") }

    /// Digit-sensitive match: the better of the leaf and the full path, so a query naming the parent
    /// ("New Track" against "Track > New") outranks a same-leaf command elsewhere.
    public func matchScore(query: String) -> Double {
        max(
            LabelText.matchScore(query: query, against: leaf),
            LabelText.matchScore(query: query, against: path.joined(separator: " "))
        )
    }
}
