//
//  ApplicationIdentity.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

/// ApplicationIdentity is the bundle id and the name a scene is stamped with. The provider asks for
/// it by process id through a closure supplied at composition, so this module never imports AppKit.
public struct ApplicationIdentity: Sendable, Equatable {

    public var bundleID: String
    public var name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name     = name
    }
}
