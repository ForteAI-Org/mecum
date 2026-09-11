//
//  BuildIdentityTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

@testable import PrivateSymbols
import Testing

/// The identity is the Ledger's key, so what matters here is that it is the
/// build and not the major version: gating on the major is what broke yabai
/// three times inside macOS 26.
@Suite("Build identity")
struct BuildIdentityTests {

    @Test("the identity is a value, and the timebase converts ticks")
    func timebase() {
        let identity = BuildIdentity(
            osVersion          : "26A5425a",
            productVersion     : "27.0",
            hardwareModel      : "Mac16,1",
            timebaseNumerator  : 125,
            timebaseDenominator: 3
        )
        #expect(identity.osVersion == "26A5425a")
        #expect(identity.nanosecondsPerTick == 125.0 / 3.0)
        #expect(identity == BuildIdentity(
            osVersion          : "26A5425a",
            productVersion     : "27.0",
            hardwareModel      : "Mac16,1",
            timebaseNumerator  : 125,
            timebaseDenominator: 3
        ))
    }

    @Test("two builds of the same product version are two different keys")
    func buildIsTheKey() {
        let first  = BuildIdentity(osVersion: "26A5425a", productVersion: "27.0", hardwareModel: "Mac16,1")
        let second = BuildIdentity(osVersion: "26A5431b", productVersion: "27.0", hardwareModel: "Mac16,1")
        #expect(first != second)
    }

    @Test("a timebase of zero never divides by zero")
    func timebaseDefaults() {
        let identity = BuildIdentity(osVersion: "x", productVersion: "y", hardwareModel: "z")
        #expect(identity.nanosecondsPerTick == 1.0)
    }
}
