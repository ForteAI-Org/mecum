//
//  SelectorPerception.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 09/10/2026.
//

import EngineCore
import PerceptionCore

/// SelectorPerception is what a Seat selector perceived around one choice, for the record of the call
/// that asked it: the window before, the menu it chose in, the window after, and the control it opened.
/// Each is nil when the selector did not reach that point. It changes no decision of the selector.
public struct SelectorPerception: Sendable {
    public var before: PerceivedWindow?
    public var menu  : PerceivedWindow?
    public var after : PerceivedWindow?
    public var target: SceneElement?

    public init(before: PerceivedWindow? = nil, menu: PerceivedWindow? = nil, after: PerceivedWindow? = nil,
                target: SceneElement? = nil) {
        self.before = before
        self.menu   = menu
        self.after  = after
        self.target = target
    }
}
