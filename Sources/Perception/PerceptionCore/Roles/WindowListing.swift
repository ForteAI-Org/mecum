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
}
