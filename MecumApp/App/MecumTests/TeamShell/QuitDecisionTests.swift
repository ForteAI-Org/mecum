//
//  QuitDecisionTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 07/10/2026.
//

import Testing
@testable import Mecum

/// Quit ends the process at once only when nothing is left to save, give back or write: memory work
/// alone sends it through the bounded path, where the memory closes within its own budget.
@MainActor
struct QuitDecisionTests {

    @Test func memoryWorkAloneTakesTheBoundedPath() {
        #expect(SeatReleasingDelegate.canEndAtOnce(drafts: 0, agents: 0, mcpDirectory: false, mcpBusy: false, memoryBusy: false))
        #expect(!SeatReleasingDelegate.canEndAtOnce(drafts: 0, agents: 0, mcpDirectory: false, mcpBusy: false, memoryBusy: true))
        #expect(!SeatReleasingDelegate.canEndAtOnce(drafts: 1, agents: 0, mcpDirectory: false, mcpBusy: false, memoryBusy: false))
        #expect(!SeatReleasingDelegate.canEndAtOnce(drafts: 0, agents: 0, mcpDirectory: true, mcpBusy: false, memoryBusy: false))
    }
}
