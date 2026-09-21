//
//  WindowInventoryProbeGate.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import Foundation

/// WindowInventoryProbeGate decides whether the Live rows of this probe may run
/// at all, from the environment alone.
///
/// Two switches, both off by default:
///
/// - `AGENTSEAT_LIVE_TESTS=1`, the tier's own switch, read through
///   `tierEnabled()` so this suite cannot be enabled by a path the rest of the
///   tier does not share.
/// - `AGENTSEAT_WINDOW_INVENTORY_PROBE=1`, dedicated to this probe. It exists
///   because the probe creates windows of its own and reads the window list of
///   the whole session, and consenting to the Live tier is not consenting to
///   that.
///
/// It deliberately does **not** go through `liveSkipReason`, which turns on
/// `FacilityGate.researchOptInForUnvalidatedBuilds` for the process as a side
/// effect. This probe needs no Facility, so it must not waive the Ledger's
/// blessing for anything else running beside it. It also does not reuse the
/// sampler's experimental flag: two different consents behind one variable is
/// how a person ends up granting the one they did not read about.
///
/// The decision is pure. Nothing here creates a window, touches AppKit or reads
/// the window server, so discovery of a disabled suite does exactly nothing.
enum WindowInventoryProbeGate {

    static let liveTierVariable = "AGENTSEAT_LIVE_TESTS"
    static let probeVariable    = "AGENTSEAT_WINDOW_INVENTORY_PROBE"

    /// The reason this probe is disabled for the given environment, or nil when
    /// both switches are exactly `1`. Any other value, including an empty one,
    /// counts as missing: a gate that accepted `true` or `yes` would be a gate
    /// whose off position depends on spelling.
    static func disabledReason(environment: [String: String]) -> String? {
        guard environment[liveTierVariable] == "1" else {
            return "\(liveTierVariable)=1 is required for the Live tier."
        }
        guard environment[probeVariable] == "1" else {
            return "\(probeVariable)=1 is required: this window inventory probe creates its own "
                + "windows and reads the session's window list, and it is off by default."
        }
        return nil
    }

    /// The same decision for the real process, with the tier's own reading of
    /// `AGENTSEAT_LIVE_TESTS` joined in. Both have to agree, so an environment
    /// that somehow satisfied one of them alone still leaves the suite off.
    static func liveDisabledReason() -> String? {
        guard tierEnabled() else { return "\(liveTierVariable)=1 is required for the Live tier." }
        return disabledReason(environment: ProcessInfo.processInfo.environment)
    }
}
