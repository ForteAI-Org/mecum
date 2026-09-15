//
//  SeatCaptureStreamTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import Foundation
import QuartzCore
@testable import SeatCapture
import Testing

/// The stream's lifecycle, without ScreenCaptureKit: everything here is about
/// what a consumer sees before a capture exists or after it is gone.
///
/// The first two checks are older than this type: they were asserted against
/// the stream it replaced, and they travelled with the behaviour.
@Suite("The capture stream before and after there is a capture")
@MainActor
struct SeatCaptureStreamTests {

    @Test("stop releases a consumer that is already waiting, even before start")
    func stopFinishesTheStream() async {
        let stream = SeatCaptureStream(target: .display(0))
        var states = stream.stateChanges.makeAsyncIterator()
        #expect(await states.next() == .idle)

        await stream.stop()

        var iterator = stream.frames.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        #expect(stream.state == .stopped(generation: 0))
        #expect(await states.next() == .stopped(generation: 0))
        #expect(await states.next() == nil)
    }

    @Test("stop is idempotent, which a fail closed teardown relies on")
    func stopTwice() async {
        let stream = SeatCaptureStream(target: .window(windowNumber: 42))
        await stream.stop()
        await stream.stop()
        #expect(!stream.isRunning)
        #expect(stream.state == .stopped(generation: 0))
    }

    @Test("a lifecycle subscriber created after terminal stop also finishes")
    func lateLifecycleSubscriberFinishes() async {
        let stream = SeatCaptureStream(target: .display(0))
        await stream.stop()

        var states = stream.stateChanges.makeAsyncIterator()
        #expect(await states.next() == .stopped(generation: 0))
        #expect(await states.next() == nil)
    }

    @Test("releasing an idle owner terminates frame and lifecycle consumers")
    func deinitializationFinishesConsumers() async {
        let consumers = {
            let owner = SeatCaptureStream(target: .display(0))
            return (frames: owner.frames, states: owner.stateChanges)
        }()
        var frames = consumers.frames.makeAsyncIterator()
        var states = consumers.states.makeAsyncIterator()

        #expect(await states.next() == .idle)
        #expect(await frames.next() == nil)
        #expect(await states.next() == nil)
    }

    @Test("a stopped stream refuses to start again instead of starting a second capture")
    func startAfterStopRefuses() async {
        let stream = SeatCaptureStream(target: .display(0))
        await stream.stop()

        await #expect(throws: CaptureFailure.notStarted) {
            try await stream.start(
                configuration: SeatCaptureConfiguration(
                    pixelSize      : CGSize(width: 64, height: 64),
                    framesPerSecond: 30
                )
            )
        }
    }

    @Test("a quality change on a stream that never started is named, not ignored")
    func updateBeforeStart() async {
        let stream = SeatCaptureStream(target: .display(0))
        await #expect(throws: CaptureFailure.notStarted) {
            try await stream.updateConfiguration(
                SeatCaptureConfiguration(
                    pixelSize      : CGSize(width: 64, height: 64),
                    framesPerSecond: 30
                )
            )
        }
    }

    @Test("counters read zero while there is no capture, and a rate of zero is not a problem")
    func countersBeforeStart() {
        let stream = SeatCaptureStream(target: .display(0))
        #expect(stream.producedFrameCount  == 0)
        #expect(stream.coalescedFrameCount == 0)
        #expect(stream.staleFrameCount     == 0)
        #expect(stream.coalescenceRate     == 0)
        #expect(stream.configuration == nil)
    }

    @Test("the same layer is attached once, and detaching it takes it out")
    func layerBookkeeping() {
        let stream = SeatCaptureStream(target: .display(0))
        let layer  = MonitorLayer(contentsScale: 2)

        stream.attach(layer)
        stream.attach(layer)
        // A consumer that attaches the same layer twice does not get two
        // presentations of every frame.
        #expect(stream.attachedLayerCount == 1)

        stream.detach(layer)
        #expect(stream.attachedLayerCount == 0)
        // Detaching one that is not there is not an error: a teardown calls it
        // more than once on purpose.
        stream.detach(layer)
        #expect(stream.attachedLayerCount == 0)
    }
}
