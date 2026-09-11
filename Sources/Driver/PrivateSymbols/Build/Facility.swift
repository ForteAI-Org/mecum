//
//  Facility.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import SeatCore

/// PrimitiveRequirement is one thing a Facility depends on, in the form the
/// Ledger records it. The cases are the `kind` column of the Ledger, so a
/// requirement carries both what to check at runtime and the key to look up:
/// keeping the two in one value is what stops a Facility from requiring a
/// primitive that no Ledger row describes.
nonisolated public enum PrimitiveRequirement: Sendable, Hashable {

    /// A C symbol resolved with `dlsym`.
    case symbol(PrivateSymbol)

    /// An Objective-C class reached by name.
    case objcClass(PrivateClass)

    /// An instance method of one of those classes.
    case selector(PrivateSelector)

    /// A `CGEvent` integer field whose id is outside the public enumeration.
    case field(String)

    /// A byte record built by hand and handed to the WindowServer.
    case record(String)

    /// A documented public API that does not behave as documented.
    case behavior(String)

    /// The key this requirement has in `validated-builds.json`.
    public var ledgerKey: String {
        switch self {
        case .symbol(let symbol):       symbol.rawValue
        case .objcClass(let objcClass): objcClass.rawValue
        case .selector(let selector):   selector.ledgerKey
        case .field(let key):           key
        case .record(let key):          key
        case .behavior(let key):        key
        }
    }

    /// The `kind` the Ledger row must declare, so a row filed under the wrong
    /// kind is a parse-time disagreement and not a silent mismatch.
    public var kind: PrimitiveKind {
        switch self {
        case .symbol:    .symbol
        case .objcClass: .objcClass
        case .selector:  .selector
        case .field:     .field
        case .record:    .record
        case .behavior:  .behavior
        }
    }
}

/// Facility is one service the kit offers or refuses on the running build. It
/// is a value and not an enumeration because the readiness rules have to be
/// testable against a Facility that does not exist: a truth table written
/// against `input` proves the input wiring, not the rule.
nonisolated public struct Facility: Sendable, Hashable {

    /// The name the Ledger and the compatibility report print.
    public let name: String

    /// Every primitive that must be `verified` for this Facility to be
    /// `validated`, in the order they are checked.
    public let requirements: [PrimitiveRequirement]

    /// The TCC grants the Facility cannot work without.
    public let permissions: [PermissionKind]

    public init(
        name        : String,
        requirements: [PrimitiveRequirement],
        permissions : [PermissionKind] = []
    ) {
        self.name         = name
        self.requirements = requirements
        self.permissions  = permissions
    }

    /// The Virtual Display and the window relocation that puts a window on it.
    public static let display = Facility(
        name        : "display",
        requirements: [
            .objcClass(.virtualDisplay),
            .objcClass(.virtualDisplayDescriptor),
            .objcClass(.virtualDisplayMode),
            .objcClass(.virtualDisplaySettings),
            .selector(.initWithDescriptor),
            .selector(.applySettings),
            .selector(.initWithMode),
            .symbol(.messageSend),
            .symbol(.axUIElementGetWindow),
            .behavior("CGVirtualDisplay.releaseRemovesDisplay"),
            .behavior("CGDisplayIsOnline.removedDisplayReturns0xFFFFFFFF"),
            .behavior("NSWindow.globalFrameOnOtherScreenLandsOnMain"),
            .behavior("AXRaiseAction.stagesWithoutActivating"),
        ],
        permissions : [.accessibility]
    )

    /// The Background Driver: identity chain, Preparation, routed posting.
    public static let input = Facility(
        name        : "input",
        requirements: [
            .symbol(.mainConnectionID),
            .symbol(.getWindowOwner),
            .symbol(.getConnectionPSN),
            .symbol(.eventRecordPointer),
            .symbol(.postEventRecordTo),
            .symbol(.setWindowLocation),
            .field("CGEvent.integerValueField.51"),
            .field("CGEvent.integerValueField.52"),
            .record("SLPSPostEventRecordTo.activationRecord"),
            .record("SLPSPostEventRecordTo.keyWindowRecord"),
            .behavior("StageManager.stashesInactiveWindowsToThumbnail"),
            .behavior("StageManager.doesNotReachAVirtualDisplay"),
        ],
        permissions : [.postEvent]
    )

    /// Read-only WindowServer identity resolution. It reuses the three input
    /// rows already promoted in the Ledger and needs no TCC grant: no event is
    /// constructed or posted, and no accessibility object is read.
    public static let windowIdentity = Facility(
        name: "windowIdentity",
        requirements: [
            .symbol(.mainConnectionID),
            .symbol(.getWindowOwner),
            .symbol(.getConnectionPSN),
        ]
    )

    /// The HID cursor fence. It is built entirely on public API, so its Ledger
    /// requirement is the build entry itself and its gate is the permission.
    public static let fence = Facility(
        name        : "fence",
        requirements: [],
        permissions : [.accessibility]
    )

    /// The seat capture streams and the still.
    public static let capture = Facility(
        name        : "capture",
        requirements: [
            .behavior("SCStreamConfiguration.defaultsDifferFromDocumentation"),
        ],
        permissions : [.screenRecording]
    )

    /// Optional focus restoration. Kept separate from the four baseline
    /// facilities: its new symbol has not been promoted into the build ledger.
    /// A consumer must explicitly opt into this unvalidated facility.
    public static let focusRecovery = Facility(
        name: "focusRecovery",
        requirements: [
            .symbol(.mainConnectionID), .symbol(.getWindowOwner),
            .symbol(.getConnectionPSN), .symbol(.postEventRecordTo),
            .symbol(.setFrontProcess), .symbol(.getFrontProcess), .symbol(.axUIElementGetWindow),
            .symbol(.eventRecordPointer), .record("SLPSPostEventRecordTo.keyWindowRecord"),
        ],
        permissions: [.accessibility]
    )

    /// The four baseline Facilities. Optional recovery exposes its own gate.
    public static let all: [Facility] = [.display, .input, .fence, .capture]
}
