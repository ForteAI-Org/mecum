//
//  WindowIdentity.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

/// WindowIdentity binds one Window ID to its owning WindowServer connection
/// and to one process lifetime. Window IDs and PIDs are both reusable, and an
/// owner connection alone does not say which process the caller intended.
/// Input therefore compares this whole value with a fresh WindowServer reading
/// immediately before every atomic Command.
///
/// WindowIdentity does not claim a window birth identifier: macOS exposes none
/// on this path. Reuse of the same Window ID inside the same process lifetime
/// and owner connection is indistinguishable, so a consumer that observes a
/// close must discard the reference and resolve the replacement afresh.
nonisolated public struct WindowIdentity: Sendable, Equatable, Hashable {

    public let process          : ProcessIdentity
    public let windowNumber     : Int
    public let ownerConnectionID: Int32

    public var processID: Int32 { process.processID }

    public init(
        process          : ProcessIdentity,
        windowNumber     : Int,
        ownerConnectionID: Int32
    ) {
        self.process           = process
        self.windowNumber      = windowNumber
        self.ownerConnectionID = ownerConnectionID
    }
}
