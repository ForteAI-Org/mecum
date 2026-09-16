//
//  PlaceholderTests.swift
//  AgentSeatKit
//

import Foundation
import PrivateSymbols
import SeatCore
import Testing

/// Gated tier: runs only when the environment asks for it.
nonisolated func tierEnabled() -> Bool {
    guard ProcessInfo.processInfo.environment["AGENTSEAT_HOST_TESTS"] == "1" else { return false }
    _ = researchOptIn
    return true
}

/// Lets the Facilities act on a macOS build the Ledger has not been promoted to,
/// set once for the whole host tier.
///
/// Without it this tier cannot qualify a new build, and the reason is a circle:
/// promoting a build needs a compatibility report, the report needs the tiers to
/// run, and the tiers need Facilities that act. On an unpromoted build every
/// Facility reads `unvalidated` and refuses, so `WindowServerProbe.geometry`
/// answers nil for the suite's own window and the seat cycle fails before it
/// starts. That is the gate working, not the build being broken.
///
/// It waives the Ledger's blessing and nothing else. The self checks still run
/// at every Facility start and this cannot rescue a failed one: if the record
/// offsets moved, every Facility refuses whatever this says. It is a global
/// `let` with a side effect in its initialiser, so Swift runs it exactly once
/// and does it before any test body that asks whether the tier is enabled.
private let researchOptIn: Bool = {
    FacilityGate.researchOptInForUnvalidatedBuilds = true
    return true
}()

@Suite(.serialized)
struct HostTierGate {
    @Test(.enabled(if: tierEnabled())) func theTierLinksTheKit() {
        #expect(SeatIssue.ambiguousEffect.isCritical)
    }
}
