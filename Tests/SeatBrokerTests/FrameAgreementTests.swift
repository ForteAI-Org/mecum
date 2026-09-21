//
//  FrameAgreementTests.swift
//  AgentLab
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 18/09/2026.
//

import CoreGraphics
import Foundation
import Testing
@testable import SeatBroker

/// A reading that answers each frame in turn and then repeats the last one,
/// which is what a window that has finished resizing does.
private func readings(_ frames: [CGRect]) -> () -> CGRect? {
    var remaining = frames
    return {
        let next = remaining.first ?? frames.last
        if remaining.count > 1 { remaining.removeFirst() }
        return next
    }
}

private func frame(_ width: CGFloat, _ height: CGFloat) -> CGRect {
    CGRect(x: 0, y: 0, width: width, height: height)
}

@Test @MainActor func twoAgreeingReadingsAreTheFrameTheSeatIsHandedAsync() async throws {
    // The window is still growing for the first two readings and has settled by
    // the third: the answer is the size it settled at, never one on the way.
    let agreement = try await SeatDriver.agreeingFrame(
        within: .seconds(1),
        pause : .milliseconds(1),
        read  : readings([frame(400, 300), frame(900, 500), frame(1_291, 949)])
    )
    #expect(agreement == .agreed(frame(1_291, 949)))
}

@Test @MainActor func aWindowThatNeverSettlesIsNotAdoptedAtAGuessedSize() async throws {
    var width: CGFloat = 400
    let agreement = try await SeatDriver.agreeingFrame(within: .milliseconds(60),
                                                       pause: .milliseconds(1)) {
        width += 50
        return frame(width, 300)
    }
    guard case .stillMoving(let first, let last) = agreement else {
        Issue.record("a window that keeps resizing has no agreed frame: \(agreement)")
        return
    }
    // Both sizes, because the sentence names both: one number alone reads as a
    // window that measured wrong rather than one that was moving.
    #expect(first.width == 450)
    #expect(last.width > first.width)
}

@Test @MainActor func aWindowThatExposesNoFrameOfItsOwnIsNotADisagreement() async throws {
    let agreement = try await SeatDriver.agreeingFrame(within: .seconds(1),
                                                       pause: .milliseconds(1)) { nil }
    // Nil is the window publishing nothing, which is what the window server's
    // own reading has always been the fallback for.
    #expect(agreement == .unreadable)
}

@Test @MainActor func aReadingThatFailsIsTheAdoptionsOwnFailure() async {
    struct ReadFailed: Error {}
    await #expect(throws: ReadFailed.self) {
        try await SeatDriver.agreeingFrame(within: .seconds(1), pause: .milliseconds(1)) {
            throw ReadFailed()
        }
    }
}
