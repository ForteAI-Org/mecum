//
//  WindowInventoryProbeGateTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import Foundation
import Testing

/// The gate of the window inventory probe, offline.
///
/// The environment is injected into the very function the Live rows ask, so this
/// suite exercises the decision itself rather than a copy of it. Nothing calls
/// `setenv`: a parallel unit run shares one process, and a suite that changed the
/// process environment would be deciding for every other suite beside it.
@MainActor
struct WindowInventoryProbeGateTests {

    static func environment(live: String? = nil, probe: String? = nil) -> [String: String] {
        var environment: [String: String] = [:]
        if let live  { environment[WindowInventoryProbeGate.liveTierVariable] = live }
        if let probe { environment[WindowInventoryProbeGate.probeVariable]    = probe }
        return environment
    }

    @Test("both switches at 1 is the only way in")
    func bothSwitchesAreRequired() {
        #expect(WindowInventoryProbeGate.disabledReason(
            environment: Self.environment(live: "1", probe: "1")
        ) == nil)

        #expect(WindowInventoryProbeGate.disabledReason(environment: [:]) != nil)
        #expect(WindowInventoryProbeGate.disabledReason(
            environment: Self.environment(live: "1")
        ) != nil)
        #expect(WindowInventoryProbeGate.disabledReason(
            environment: Self.environment(probe: "1")
        ) != nil)
    }

    @Test("a value that is not exactly 1 leaves the gate closed")
    func invalidValuesKeepTheGateClosed() {
        for value in ["", "0", "true", "yes", "1 ", "01"] {
            #expect(WindowInventoryProbeGate.disabledReason(
                environment: Self.environment(live: "1", probe: value)
            ) != nil, Comment(rawValue: "\(value) enabled the probe"))

            #expect(WindowInventoryProbeGate.disabledReason(
                environment: Self.environment(live: value, probe: "1")
            ) != nil, Comment(rawValue: "\(value) enabled the tier"))
        }
    }

    @Test("the tier switch is reported before the probe switch")
    func theFirstUnmetSwitchIsTheReason() throws {
        let noTier = try #require(
            WindowInventoryProbeGate.disabledReason(environment: Self.environment(probe: "1"))
        )
        #expect(noTier.contains(WindowInventoryProbeGate.liveTierVariable))

        let noProbe = try #require(
            WindowInventoryProbeGate.disabledReason(environment: Self.environment(live: "1"))
        )
        #expect(noProbe.contains(WindowInventoryProbeGate.probeVariable))
    }

    @Test("the probe has a switch of its own, not one borrowed from another row")
    func theProbeSwitchIsDedicated() {
        let borrowed = [
            "AGENTSEAT_LIVE_TESTS", "AGENTSEAT_MANUAL_TESTS", "AGENTSEAT_SETTLE_MS",
            "AGENTSEAT_MODIFIER_POLICY", "AGENTSEAT_FOLLOW_APP",
        ]
        #expect(!borrowed.contains(WindowInventoryProbeGate.probeVariable))
        #expect(WindowInventoryProbeGate.probeVariable == "AGENTSEAT_WINDOW_INVENTORY_PROBE")
    }

    @Test("the live decision agrees with the injected one for this process's environment")
    func theLiveDecisionUsesTheSameLogic() {
        // Both switches are off in a unit run, so the live entry point refuses
        // and never reaches AppKit. The injected decision has to say the same
        // thing about the same environment, or the two would drift.
        let environment = ProcessInfo.processInfo.environment
        let injected    = WindowInventoryProbeGate.disabledReason(environment: environment)
        let live        = WindowInventoryProbeGate.liveDisabledReason()

        #expect((injected == nil) == (live == nil))
        if !tierEnabled() {
            #expect(live != nil, "the probe must be disabled without the Live tier switch")
        }
    }
}
