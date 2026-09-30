//
//  UXPPlatform.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/09/2026.
//

import SeatCore

/// Preparation policy for an application whose interface Adobe's UXP host draws.
///
/// Measured on 30/09/2026 with Photoshop 27.10's New Document, a modal that
/// accessibility reads as one leaf: an unprepared click reached it and pressed
/// the button under the point, while Return posted to the same window did
/// nothing. It did nothing either after the key-window pair alone, and it
/// created the document after the whole preparation (the activation record,
/// the key-window pair and 300 ms), with the person's application still in
/// front.
///
/// **Only for that dialog.** The same day, a prepared Escape posted to the
/// document window while a Duplicate Layer dialog the seat did not see was
/// open crashed Photoshop inside `-[NSApplication _handleActivatedEvent:]`,
/// and its unsaved documents went with it. So the application's own family
/// prepares nothing, like `AppKitPlatform`, and `preparingKeys` is what a key
/// to a modal read as one accessibility leaf (`InputEndpointEvidence
/// .leafSurface`) is driven with. Clicks are never prepared: they reached the
/// dialog unprepared, and a prepared click would activate the dialog it opens.
nonisolated public struct UXPPlatform: InputPlatform {

    /// Whether keys and text are prepared: only for a leaf modal of the application.
    public let preparesKeys: Bool

    public init(preparesKeys: Bool = false) {
        self.preparesKeys = preparesKeys
    }

    /// The recipe for a key to one of the application's leaf modals.
    public var preparingKeys: UXPPlatform { UXPPlatform(preparesKeys: true) }

    public func preparation(for command: InputCommand) -> Preparation {
        switch command {
            case .key, .text, .insertText: preparesKeys ? .internalAppKitState : .none
            case .click, .drag, .scroll  : .none
        }
    }

    // ponytail: 300 ms is the one settle measured, and shorter was not tried.
    public func preparationSettle(for command: InputCommand) -> Duration {
        preparesKeys ? .milliseconds(300) : .milliseconds(30)
    }
}
