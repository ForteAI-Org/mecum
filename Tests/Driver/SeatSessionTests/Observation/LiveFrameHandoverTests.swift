//
//  LiveFrameHandoverTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/10/2026.
//

import CoreGraphics
import Dispatch
import SeatCapture
import SeatCore
@testable import SeatSession
import Testing

/// A running stream that answers what the test scripted and records what it was asked.
@MainActor
private final class ScriptedLiveFrames: LiveWindowFrameSourcing {

    var answer: Result<SeatFrame, LiveFrameFallback> = .failure(.notLive)
    private(set) var asked: [(identity: WindowIdentity, notBefore: UInt64, bound: Duration)] = []

    func liveFrame(
        of identity             : WindowIdentity,
        displayedAfter notBefore: UInt64,
        within bound            : Duration
    ) async -> Result<SeatFrame, LiveFrameFallback> {
        asked.append((identity, notBefore, bound))
        return answer
    }
}

@Suite("A frame of the running stream handed to an observation")
@MainActor
struct LiveFrameHandoverTests {

    private let window     = FakeGeometry.identity()
    private let windowRect = CGRect(x: 1_600, y: 100, width: 64, height: 40)
    private let ticks: UInt64 = 5_000_000
    private let source     = SeatCaptureObservationSource(displayGeneration: 1)

    /// The frame's own display instant on the uptime clock.
    private var displayedAt: UInt64 {
        MachAbsoluteContentClock().displayTimeNanoseconds(fromMachTicks: ticks) ?? 0
    }

    private var farDeadline: UInt64 { DispatchTime.now().uptimeNanoseconds + 5_000_000_000 }

    private func frame(of identity: WindowIdentity? = nil, rect: CGRect? = nil) throws -> SeatFrame {
        try #require(makeControlledFrame(
            of         : identity ?? window,
            screenRect : rect ?? windowRect,
            displayTime: ticks
        ))
    }

    private func readings(
        identity: WindowIdentity? = nil,
        frame   : CGRect? = nil,
        scale   : CGFloat = 1
    ) -> LiveFrameHandover.Readings {
        LiveFrameHandover.Readings(
            identity    : identity ?? window,
            windowFrame : frame ?? windowRect,
            displayScale: scale
        )
    }

    private func handOver(
        _ answer : Result<SeatFrame, LiveFrameFallback>,
        after instant: UInt64,
        readings : LiveFrameHandover.Readings,
        deadline : UInt64? = nil,
        live     : ScriptedLiveFrames = ScriptedLiveFrames()
    ) async -> Result<SeatFrame, LiveFrameFallback> {
        live.answer = answer
        return await source.liveFrame(
            of                 : window,
            displayedAfter     : instant,
            deadlineNanoseconds: deadline ?? farDeadline,
            from               : live,
            readings           : { _ in readings }
        )
    }

    @Test("a frame displayed after the instant is taken from the source, as a copy of its own")
    func frameAfterTheInstantIsTaken() async throws {
        let live    = ScriptedLiveFrames()
        let offered = try frame()
        let result  = await handOver(.success(offered), after: displayedAt - 1, readings: readings(), live: live)

        let taken = try result.get()
        #expect(taken.displayTime == ticks)
        #expect(taken.source == .window(window))
        #expect(taken.surface !== offered.surface)
        #expect(live.asked.count == 1)
        #expect(live.asked.first?.identity == window)
        #expect(live.asked.first?.notBefore == displayedAt - 1)
        #expect(live.asked.first?.bound == LiveFrameHandover.bound)
    }

    @Test("a frame displayed at or before the instant is refused")
    func frameBeforeTheInstantIsRefused() async throws {
        let atInstant = await handOver(.success(try frame()), after: displayedAt, readings: readings())
        #expect(atInstant.failureReason == .displayedBeforeInstant)

        let untimed = try #require(makeControlledFrame(of: window, screenRect: windowRect, displayTime: nil))
        let missing = await handOver(.success(untimed), after: 0, readings: readings())
        #expect(missing.failureReason == .displayedBeforeInstant)
    }

    @Test("no frame within the bound falls back, and the wait never outlasts the request")
    func noFrameWithinTheBoundFallsBack() async {
        let live   = ScriptedLiveFrames()
        let now    = DispatchTime.now().uptimeNanoseconds
        let result = await handOver(
            .failure(.noFrameInBound),
            after   : now,
            readings: readings(),
            deadline: now + 40_000_000,
            live    : live
        )
        #expect(result.failureReason == .noFrameInBound)
        #expect(live.asked.first?.bound == .milliseconds(40))
    }

    @Test("a source that is pinned, recovering or not live is a fallback with its reason")
    func decliningSourceFallsBack() async {
        for reason in [LiveFrameFallback.pinnedToDisplay, .recovering, .notLive, .otherWindow] {
            let result = await handOver(.failure(reason), after: 0, readings: readings())
            #expect(result.failureReason == reason)
        }
    }

    @Test("identity is attested at the hand-over even when the frame carries the requested one")
    func changedIdentityFallsBack() async throws {
        let successor = FakeGeometry.identity(lifetime: 2)
        let result = await handOver(.success(try frame()), after: 0, readings: readings(identity: successor))
        #expect(result.failureReason == .identityChanged)

        let vanished = LiveFrameHandover.Readings(identity: nil, windowFrame: windowRect, displayScale: 1)
        #expect(await handOver(.success(try frame()), after: 0, readings: vanished).failureReason == .identityChanged)
    }

    @Test("a frame of another window is refused")
    func otherWindowFallsBack() async throws {
        let other  = FakeGeometry.identity(windowNumber: 778)
        let result = await handOver(.success(try frame(of: other)), after: 0, readings: readings())
        #expect(result.failureReason == .otherWindow)
    }

    @Test("a window that moved or was resized since the frame's rectangle falls back")
    func changedGeometryFallsBack() async throws {
        let moved   = windowRect.offsetBy(dx: 10, dy: 0)
        let resized = CGRect(origin: windowRect.origin, size: CGSize(width: 80, height: 40))
        #expect(await handOver(.success(try frame()), after: 0, readings: readings(frame: moved)).failureReason
                == .geometryChanged)
        #expect(await handOver(.success(try frame()), after: 0, readings: readings(frame: resized)).failureReason
                == .geometryChanged)
    }

    @Test("a frame whose size is not the window's at the display's scale falls back")
    func sizeMismatchFallsBack() async throws {
        // 64 by 40 pixels for a 64 by 40 point window on a 2x display: a stream at an earlier shape.
        let doubled = await handOver(.success(try frame()), after: 0, readings: readings(scale: 2))
        #expect(doubled.failureReason == .sizeMismatch)

        let unknown = LiveFrameHandover.Readings(identity: window, windowFrame: windowRect, displayScale: nil)
        #expect(await handOver(.success(try frame()), after: 0, readings: unknown).failureReason == .sizeMismatch)
    }
}

private extension Result where Failure == LiveFrameFallback {
    var failureReason: LiveFrameFallback? {
        if case .failure(let reason) = self { return reason }
        return nil
    }
}
