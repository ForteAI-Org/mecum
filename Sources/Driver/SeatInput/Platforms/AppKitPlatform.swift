//
//  AppKitPlatform.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import SeatCore

/// AppKitPlatform prepares nothing at all. A native AppKit window accepted every
/// Command in the vocabulary from an inactive application: click, keyboard,
/// text, scroll and drag all passed with no Preparation, and passed again with
/// one, so preparing is not wrong there, only pointless.
///
/// Choosing it is an optimisation and never a requirement: it removes two
/// records and the settle from every Command, and it leaves the target's own
/// idea of being active untouched, which is the friendlier thing to do to an
/// application the person also uses.
nonisolated public struct AppKitPlatform: InputPlatform {

    public init() {}

    /// Nothing. Measured, not assumed.
    public func preparation(for command: InputCommand) -> Preparation {
        switch command {
            case .key, .text, .insertText, .click, .drag, .scroll: .none
        }
    }
}
