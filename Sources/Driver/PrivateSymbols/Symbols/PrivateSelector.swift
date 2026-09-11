//
//  PrivateSelector.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

/// PrivateSelector is one instance method of a `PrivateClass`, checked with
/// `class_respondsToSelector`. It is tracked apart from the class because a
/// selector is the primitive that actually drifts: cua's own history shows a
/// selector introduced mid-cycle on a class that had existed for years.
nonisolated public struct PrivateSelector: Sendable, Hashable {

    /// The class that must respond to it.
    public let owner: PrivateClass

    /// The selector's exact spelling, colons included.
    public let name: String

    /// The Ledger key: `<class>.<selector>`, the same string the compatibility
    /// report prints.
    public var ledgerKey: String { "\(owner.rawValue).\(name)" }

    public init(owner: PrivateClass, name: String) {
        self.owner = owner
        self.name  = name
    }

    /// Builds the virtual display from a descriptor.
    public static let initWithDescriptor = PrivateSelector(
        owner: .virtualDisplay,
        name : "initWithDescriptor:"
    )

    /// Attaches modes and topology to a live virtual display.
    public static let applySettings = PrivateSelector(
        owner: .virtualDisplay,
        name : "applySettings:"
    )

    /// Builds one mode; the refresh rate the Seat Host asks for goes here.
    public static let initWithMode = PrivateSelector(
        owner: .virtualDisplayMode,
        name : "initWithWidth:height:refreshRate:"
    )

    /// Every selector the kit relies on.
    public static let all: [PrivateSelector] = [
        .initWithDescriptor, .applySettings, .initWithMode,
    ]
}
