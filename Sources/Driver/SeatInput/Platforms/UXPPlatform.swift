//
//  UXPPlatform.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/09/2026.
//

import SeatCore

/// Preparation policy for independently attested Adobe UXP surfaces.
///
/// The ordinary family prepares nothing. Recipient classification can instead
/// require only the selected window's make-key pair and a 300 ms settle when
/// the modal is an AX leaf, its complete subtree has stale global focus, or a
/// selected document remains behind a positively empty UXP focus proxy.
/// The proof is repeated before the first event; the pair never includes an
/// application activation record. See ADR 0016 and the live matrix in UXP.md.
///
/// Full AppKit preparation remains an explicit consumer recipe for document
/// left clicks and keys. A prepared canvas click establishes the first responder
/// before menu shortcuts; preparing a key alone can restore the zoom field. Preparing
/// Photoshop's blocked document while Duplicate Layer was open crashed the host
/// inside `-[NSApplication _handleActivatedEvent:]` in the 30/09/2026 trial, so
/// the seat does not infer full preparation from the application's family.
nonisolated public struct UXPPlatform: InputPlatform {

    /// Explicit full AppKit preparation for consumer calibration. The seat's
    /// attested UXP recipient recipe uses key-window priming instead.
    public let preparesKeys: Bool

    /// The wait after key-window priming. The default is the
    /// measured recipe; consumers may calibrate explicitly on disposable data.
    public let keyPreparationSettle: Duration

    private let primedKeyWindow: WindowReference?
    private let preparesLeftClicks: Bool
    private let preparesDocumentShortcuts: Bool

    public init(
        preparesKeys        : Bool = false,
        keyPreparationSettle: Duration = .milliseconds(300)
    ) {
        self.primedKeyWindow           = nil
        self.preparesLeftClicks        = false
        self.preparesDocumentShortcuts = false
        self.preparesKeys              = preparesKeys
        self.keyPreparationSettle      = max(.zero, keyPreparationSettle)
    }

    /// Explicit full AppKit preparation for consumer calibration. The seat
    /// uses recipient priming instead, which includes no activation record.
    public var preparingKeys: UXPPlatform {
        UXPPlatform(
            preparesKeys             : true,
            preparesLeftClicks       : preparesLeftClicks,
            preparesDocumentShortcuts: preparesDocumentShortcuts,
            settle                   : keyPreparationSettle
        )
    }

    /// Explicit full AppKit preparation for a measured single left click on the selected
    /// document, with no blocking modal. It lets the canvas become first responder
    /// while the target considers itself active. Right click, drag and scroll
    /// retain their ordinary policy. This does not move the physical foreground.
    public var preparingLeftClicks: UXPPlatform {
        UXPPlatform(
            preparesKeys             : preparesKeys,
            preparesLeftClicks       : true,
            preparesDocumentShortcuts: preparesDocumentShortcuts,
            settle                   : keyPreparationSettle
        )
    }

    /// Selects the measured Select All, Deselect, Invert, Undo and Redo shortcuts.
    /// It uses their layout-resolved character origin, never a physical key guess.
    /// Return, text, navigation and modal-opening shortcuts keep their ordinary policy.
    public var preparingDocumentShortcuts: UXPPlatform {
        UXPPlatform(
            preparesKeys             : preparesKeys,
            preparesLeftClicks       : preparesLeftClicks,
            preparesDocumentShortcuts: true,
            settle                   : keyPreparationSettle
        )
    }

    /// Removes document calibration on a modal with established own-window focus.
    /// Unfocused modals select recipient priming through their separate proof.
    package var withoutDocumentPreparation: UXPPlatform {
        UXPPlatform(keyPreparationSettle: keyPreparationSettle)
    }

    private init(
        preparesKeys             : Bool,
        preparesLeftClicks       : Bool,
        preparesDocumentShortcuts: Bool = false,
        settle                   : Duration
    ) {
        self.primedKeyWindow           = nil
        self.preparesKeys              = preparesKeys
        self.preparesLeftClicks        = preparesLeftClicks
        self.preparesDocumentShortcuts = preparesDocumentShortcuts
        self.keyPreparationSettle      = max(.zero, settle)
    }

    /// Makes only the attested UXP recipient key, without activating its application.
    package func primingKeys(in window: WindowReference) -> UXPPlatform {
        UXPPlatform(primedKeyWindow: window, settle: keyPreparationSettle)
    }

    private init(primedKeyWindow: WindowReference, settle: Duration) {
        self.primedKeyWindow = primedKeyWindow
        self.preparesKeys = false
        self.preparesLeftClicks = false
        self.preparesDocumentShortcuts = false
        self.keyPreparationSettle = settle
    }

    public func keyWindowPriming(for command: InputCommand) -> (host: WindowReference, settle: Duration)? {
        guard !command.hasMouseLocation, let primedKeyWindow else { return nil }
        return (primedKeyWindow, keyPreparationSettle)
    }

    public func preparation(for command: InputCommand) -> Preparation {
        switch command {
            case .key(_, _, let modifiers, .press, let origin)
                where preparesDocumentShortcuts && Self.isMeasuredDocumentShortcut(origin, modifiers):
                .internalAppKitState
            case .key, .text, .insertText: preparesKeys ? .internalAppKitState : .none
            case .click(_, .left, 1)     : preparesLeftClicks ? .internalAppKitState : .none
            case .click, .drag, .scroll  : .none
        }
    }

    public func preparationSettle(for command: InputCommand) -> Duration {
        preparation(for: command) == .internalAppKitState ? keyPreparationSettle : .milliseconds(30)
    }

    private static func isMeasuredDocumentShortcut(
        _ origin: CharacterShortcutOrigin?,
        _ modifiers: Modifiers
    ) -> Bool {
        guard let origin, origin.commandPlane, origin.effectiveModifiers == modifiers else { return false }
        if modifiers == .command {
            switch origin.character {
                case "a", "d", "i", "z": return true
                default: return false
            }
        }
        return modifiers == [.command, .shift] && origin.character == "z"
    }
}
