//
//  PermissionsHostTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import ApplicationServices
import CoreGraphics
import PrivateSymbols
import SeatCore
import Testing

/// `preflight` is what a status pill and a watchdog read, so what has to be
/// proven is that it is the platform's own answer and nothing else: a wrapper
/// that caches, guesses or inverts would show the person a permission they do
/// not have. `request` is deliberately never called here, because a test that
/// prompts is a test nobody can run twice.
@Suite("Permissions on the running system", .serialized)
struct PermissionsHostTests {

    @Test("preflight is the platform's own answer, never a cached one", .enabled(if: tierEnabled()))
    func preflightMatchesThePlatform() {
        #expect(Permissions.preflight(.postEvent)       == CGPreflightPostEventAccess())
        #expect(Permissions.preflight(.screenRecording) == CGPreflightScreenCaptureAccess())
        #expect(Permissions.preflight(.accessibility)   == AXIsProcessTrusted())
    }

    @Test("preflight is stable across calls and prompts nothing", .enabled(if: tierEnabled()))
    func preflightIsIdempotent() {
        for kind in [PermissionKind.postEvent, .screenRecording, .accessibility] {
            #expect(Permissions.preflight(kind) == Permissions.preflight(kind))
        }
    }

    @Test("a Facility asks only for the grants it needs", .enabled(if: tierEnabled()))
    func firstMissingReadsOnlyItsOwnGrants() {
        for facility in Facility.all {
            let missing = Permissions.firstMissing(for: facility)
            if let missing {
                #expect(facility.permissions.contains(missing))
                #expect(!Permissions.preflight(missing))
            } else {
                #expect(facility.permissions.allSatisfy { Permissions.preflight($0) })
            }
        }
        #expect(Permissions.firstMissing(of: []) == nil)
    }
}
