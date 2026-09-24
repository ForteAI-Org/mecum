//
//  DesktopStatus.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import Foundation

/// DesktopGrant is one macOS permission a worker's seat needs, and whether
/// this process holds it now.
public struct DesktopGrant: Sendable, Hashable, Identifiable {

    public let name     : String
    public let isGranted: Bool

    public var id: String { name }
}

/// BuildValidation is this Mac's macOS build and whether the kit's ledger
/// lists it: the private primitives the seat relies on were verified on a
/// build it lists, and on any other the seat acts only where unvalidated
/// builds are allowed, marking every receipt so.
public struct BuildValidation: Sendable, Hashable {

    /// `kern.osversion`, such as 26A5425a.
    public let build: String

    /// `kern.osproductversion`, such as 27.0.
    public let productVersion: String

    public let isValidated: Bool
}
