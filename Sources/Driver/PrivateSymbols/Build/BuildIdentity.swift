//
//  BuildIdentity.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import Darwin

/// BuildIdentity is the key every private primitive is gated on. It is the
/// build, not the major version: yabai gates on `majorVersion` alone and broke
/// three times inside macOS 26, so `kern.osversion` (26A5425a) is the identity
/// and `kern.osproductversion` (27.0) is only the human label. `hw.model` is
/// the second half of the key, because a primitive can be verified on one Mac
/// and untested on the next.
///
/// The Mach timebase travels with it: every measurement in the kit converts
/// ticks with these two numbers, and reading them once at start is cheaper than
/// asking the kernel in a hot path.
nonisolated public struct BuildIdentity: Sendable, Equatable {

    /// `kern.osversion`, the build string. The Ledger's primary key.
    public let osVersion: String

    /// `kern.osproductversion`, the marketing version. Never a gate.
    public let productVersion: String

    /// `hw.model`, the hardware identifier. The Ledger's secondary key.
    public let hardwareModel: String

    /// `mach_timebase_info.numer`.
    public let timebaseNumerator: UInt32

    /// `mach_timebase_info.denom`.
    public let timebaseDenominator: UInt32

    /// The running system, read once. A `static let` is initialised lazily and
    /// exactly once, which is the whole requirement: three sysctls and one
    /// `mach_timebase_info` are cheap, but they are not free in a watchdog.
    public static let current = BuildIdentity()

    /// Nanoseconds per `mach_absolute_time` tick on this machine. On Apple
    /// silicon the ratio is not 1, so a raw tick difference is not a duration.
    public var nanosecondsPerTick: Double {
        Double(timebaseNumerator) / Double(timebaseDenominator)
    }

    public init(
        osVersion           : String,
        productVersion      : String,
        hardwareModel       : String,
        timebaseNumerator   : UInt32 = 1,
        timebaseDenominator : UInt32 = 1
    ) {
        self.osVersion           = osVersion
        self.productVersion      = productVersion
        self.hardwareModel       = hardwareModel
        self.timebaseNumerator   = timebaseNumerator
        self.timebaseDenominator = timebaseDenominator
    }

    private init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        self.osVersion           = Self.sysctlString("kern.osversion")
        self.productVersion      = Self.sysctlString("kern.osproductversion")
        self.hardwareModel       = Self.sysctlString("hw.model")
        self.timebaseNumerator   = timebase.numer == 0 ? 1 : timebase.numer
        self.timebaseDenominator = timebase.denom == 0 ? 1 : timebase.denom
    }

    /// An empty string, not a crash, when a name is unknown: an identity that
    /// cannot be read is a build outside the Ledger, which the gate already
    /// handles as `unvalidated`.
    static func sysctlString(_ name: String) -> String {
        
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
        
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}
