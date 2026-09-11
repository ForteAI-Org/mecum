//
//  ProcessIdentity.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

/// ProcessIdentity binds a PID to the process serial number created for one
/// process lifetime. A PID can be reused after termination; the serial number
/// cannot be reused while that process lives, so both values are required.
///
/// The serial number comes from the WindowServer connection that owns the
/// window, then the documented `GetProcessPID` mapping has to resolve it back
/// to `processID`. A value assembled without that chain is not evidence and
/// must not be placed in a `WindowReference` used for input.
nonisolated public struct ProcessIdentity: Sendable, Equatable, Hashable {

    public let processID       : Int32
    public let serialNumberHigh: UInt32
    public let serialNumberLow : UInt32

    public init(
        processID       : Int32,
        serialNumberHigh: UInt32,
        serialNumberLow : UInt32
    ) {
        self.processID        = processID
        self.serialNumberHigh = serialNumberHigh
        self.serialNumberLow  = serialNumberLow
    }
}
