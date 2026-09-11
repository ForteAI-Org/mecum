//
//  InputProgressTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import SeatCore
import Testing

@Suite("Input progress")
struct InputProgressTests {

    @Test(
        "the compatible receipt flag remains a failed cleanup, including older witnesses",
        arguments: [Preparation.none, .internalAppKitState]
    )
    func compatibleUnrestoredPreparation(preparation: Preparation) {
        let receipt = InputReceipt(
            eventCount              : 2,
            route                   : Self.route,
            preparation             : preparation,
            hasUnrestoredPreparation: true
        )

        #expect(receipt.cleanup == .failed(code: nil))
        #expect(receipt.hasUnrestoredPreparation)
    }

    @Test("a restore refusal keeps its original code and requires recovery")
    func restoreRefusalNeedsRecovery() {
        let cleanup = InputCleanupResult.failed(code: -17)
        let receipt = InputReceipt(
            eventCount : 2,
            route      : Self.route,
            preparation: .internalAppKitState,
            cleanup    : cleanup
        )
        let progress = InputProgress(
            completedSteps              : [.activation, .keyWindowFirst, .keyWindowSecond],
            failedStep                  : nil,
            failedStepMayHaveTakenEffect: false,
            cleanup                     : cleanup
        )

        #expect(receipt.cleanup == .failed(code: -17))
        #expect(receipt.hasUnrestoredPreparation)
        #expect(progress.neededRecovery == .restorePreparation)
    }

    private static let route = InputRoute(
        poster           : .publicProcess,
        routedEventCount : 2,
        windowNumber     : 7,
        ownerConnectionID: 9
    )
}
