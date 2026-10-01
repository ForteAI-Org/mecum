//
//  WindowListing.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import Foundation

/// WindowListing supplies the on-screen windows one process owns, front to back, as the window
/// server orders them. It is a read of the current moment; a second call may answer differently.
public protocol WindowListing: Sendable {

    func windows(ownedBy processID: pid_t) throws -> [WindowRow]

    /// Complete process window inventory, including hidden and minimized windows. Nil means this
    /// adapter cannot attest completeness; absence in `windows` alone never proves destruction.
    func allWindows(ownedBy processID: pid_t) throws -> [WindowRow]?
}

extension WindowListing {
    public func allWindows(ownedBy processID: pid_t) throws -> [WindowRow]? { nil }
}
