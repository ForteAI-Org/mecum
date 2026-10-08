//
//  MemoryIdentityConflict.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 30/09/2026.
//

/// MemoryIdentityConflict names a fact offered under an identity that already holds different
/// content. The fingerprints are canonical digests of the stored and the offered content, so the
/// report can say that they differ without repeating either.
public struct MemoryIdentityConflict: Sendable, Equatable {

    public let identity          : String
    public let storedFingerprint : String
    public let offeredFingerprint: String

    public init(identity: String, storedFingerprint: String, offeredFingerprint: String) {
        self.identity           = identity
        self.storedFingerprint  = storedFingerprint
        self.offeredFingerprint = offeredFingerprint
    }
}
