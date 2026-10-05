//
//  ObservationStopTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 03/10/2026.
//

import CoreGraphics
import Foundation
import SeatCore
import SeatDriving
@testable import SeatSession
import Testing

/// A stop that reaches an observation in flight, on the controlled seat, through the borrowed `SeatTarget`
/// the Engine's roles use: the capture is cancelled with its task and the seat answers it as such, typed,
/// so the target throws `CancellationError` and a caller records a stop. A capture that really failed stays
/// the seat's `ObservationUnavailable`, cancelled task or not, and the public `observe()` answers what it
/// always answered.
@MainActor
@Suite("An observation stopped with its task")
struct ObservationStopTests {

    /// Runs `body` in a task cancelled before it starts, and answers the error it threw, if any.
    private static func inCancelledTask(_ body: @escaping @MainActor () async throws -> Void) async -> (any Error)? {
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await body()
        }
        if case .failure(let error) = await task.result { return error }
        return nil
    }

    @Test("a capture cancelled with its task reaches the target's caller as CancellationError")
    func aCancelledCaptureIsAStop() async throws {
        let context = try await BorrowedSeatTargetTests.borrowed()
        let source = try #require(context.seat.observationSource as? ControlledObservationSource)
        source.permanentFailure = CancellationError()
        let error = await Self.inCancelledTask { _ = try await context.target.observe() }
        #expect(error is CancellationError, "\(String(describing: error))")
    }

    @Test("a capture that really failed stays ObservationUnavailable, even with the task cancelled")
    func aRealFailureStaysAFailure() async throws {
        let context = try await BorrowedSeatTargetTests.borrowed()
        let source = try #require(context.seat.observationSource as? ControlledObservationSource)
        source.permanentFailure = NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3801)
        let cancelled = await Self.inCancelledTask { _ = try await context.target.observe() }
        #expect(cancelled is ObservationUnavailable, "\(String(describing: cancelled))")
        let running = await { () async -> (any Error)? in
            do { _ = try await context.target.observe(); return nil } catch { return error }
        }()
        #expect(running is ObservationUnavailable, "\(String(describing: running))")
    }

    @Test("a cancelled attempt followed by a real failure answers the real failure")
    func theLastFailureDecides() async throws {
        let context = try await BorrowedSeatTargetTests.borrowed()
        let source = try #require(context.seat.observationSource as? ControlledObservationSource)
        var attempt = 0
        source.duringCapture = {
            attempt += 1
            source.permanentFailure = attempt == 1
                ? CancellationError()
                : NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3801)
        }
        let error = await Self.inCancelledTask { _ = try await context.target.observe() }
        #expect(error is ObservationUnavailable, "\(String(describing: error))")
    }

    @Test("the public observe answers the cancelled capture as it always did: captureFailed with its text")
    func thePublicContractIsUnchanged() async throws {
        let context = try await BorrowedSeatTargetTests.borrowed()
        let source = try #require(context.seat.observationSource as? ControlledObservationSource)
        source.permanentFailure = CancellationError()
        let answer = await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await context.seat.observe()
        }.value
        guard case .failure(.captureFailed(let reason)) = answer else { Issue.record("\(answer)"); return }
        #expect(reason == String(describing: CancellationError()))
    }
}
