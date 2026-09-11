//
//  Preparation.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

/// Preparation is what the driver did to the target's own state before posting
/// a Command, and undid afterwards. It never leaves the target process: no
/// event reaches the User Seat, and the person's frontmost application does not
/// change. A platform decides whether a Command needs it.
public enum Preparation: String, Sendable, Equatable {

    /// Nothing was sent before the Command. AppKit targets and every keyboard
    /// or scroll Command take this path.
    case none

    /// The two records that make the window active and key inside its own
    /// process, sent before the Command and undone once it is done. Chromium,
    /// Electron and CEF renderers need it for mouse Commands.
    case internalAppKitState
}
