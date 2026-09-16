//
//  PlaceholderTests.swift
//  AgentSeatKit
//

import Foundation
import SeatCore
import Testing

/// Gated tier: runs only when the environment asks for it.
nonisolated func tierEnabled() -> Bool { ProcessInfo.processInfo.environment["AGENTSEAT_HOST_TESTS"] == "1" }

@Suite(.serialized)
struct HostTierGate {
    @Test(.enabled(if: tierEnabled())) func theTierLinksTheKit() {
        #expect(SeatIssue.ambiguousEffect.isCritical)
    }
}
