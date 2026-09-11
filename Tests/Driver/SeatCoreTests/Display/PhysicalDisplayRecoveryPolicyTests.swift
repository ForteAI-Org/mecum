//
//  PhysicalDisplayRecoveryPolicyTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
@testable import SeatCore
import Testing

/// The topology checks: what a seat may still trust once the person's display
/// arrangement has moved.
@Suite("Physical display recovery policy")
struct PhysicalDisplayRecoveryPolicyTests {

    static let baseline: [CGDirectDisplayID: CGRect] = [
        1: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        2: CGRect(x: 1920, y: 0, width: 1280, height: 720)
    ]

    static let shifted: [CGDirectDisplayID: CGRect] = [
        1: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        2: CGRect(x: 0, y: 0, width: 1280, height: 720)
    ]

    @Test("physical origins are restorable after the main display moved")
    func originsRestorable() {
        #expect(PhysicalDisplayRecoveryPolicy.canRestore(
            baseline: Self.baseline, current: Self.shifted, mainDisplayID: 1))
    }

    @Test("a hot unplug never forces an old topology back")
    func hotUnplugRefused() {
        guard let first = Self.baseline[1] else {
            Issue.record("missing baseline display")
            return
        }
        #expect(!PhysicalDisplayRecoveryPolicy.canRestore(
            baseline: Self.baseline, current: [1: first], mainDisplayID: 1))
    }

    @Test("a new display prevents the restore")
    func newDisplayRefused() {
        var extra = Self.shifted
        extra[3] = CGRect(x: 4000, y: 0, width: 800, height: 600)
        #expect(!PhysicalDisplayRecoveryPolicy.canRestore(
            baseline: Self.baseline, current: extra, mainDisplayID: 1))
    }

    @Test("a resolution change prevents the automatic restore")
    func resolutionChangeRefused() {
        var resized = Self.shifted
        resized[2] = CGRect(x: 0, y: 0, width: 1600, height: 900)
        #expect(!PhysicalDisplayRecoveryPolicy.canRestore(
            baseline: Self.baseline, current: resized, mainDisplayID: 1))
    }
}
