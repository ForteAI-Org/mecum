//
//  Monitor.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import Foundation
import os

/// Monitor is the live preview of the Virtual Display shown to the person: one
/// stream with a display filter, the layers it is presented in, and the policy
/// that gives something up when the pipeline cannot keep the pace.
///
/// It is the Seat Host's, and the Seat Host is the one owner of it, which is
/// the whole point of ADR 0003: with the consumer building its own `SCStream`
/// nothing would stop two owners capturing the same surface.
///
/// The consumer's part is small and stays the consumer's: it asks for a layer,
/// puts it in a view of its own, and, once a second, hands over the CPU reading
/// its heartbeat already takes.
@MainActor
public final class Monitor {

    private static let log = Logger(subsystem: "dev.forte.AgentSeatKit", category: "capture")

    /// The display being previewed.
    public let displayID: CGDirectDisplayID

    /// The frames, for a consumer that wants the data rather than the picture.
    /// The attached layers are served first and do not go through here.
    public var frames: AsyncStream<SeatFrame> { stream.frames }

    /// The capture lifecycle. Direct consumers can observe a spontaneous
    /// ScreenCaptureKit stop without waiting for the Seat Host's heartbeat.
    public var state: CaptureLifecycle { stream.state }

    /// One independent subscription to capture lifecycle changes.
    public var stateChanges: AsyncStream<CaptureLifecycle> { stream.stateChanges }

    /// True only while ScreenCaptureKit has completed start and no stop has
    /// been requested or reported.
    public var isRunning: Bool { stream.isRunning }

    /// True when a failed stop left the exact ScreenCaptureKit resource retained
    /// for another stop attempt.
    public var hasUnconfirmedResource: Bool { stream.hasUnconfirmedResource }

    /// The rung of the ladder the Monitor is on.
    public var quality: MonitorQuality { policy.quality }

    /// What the consumer asked for, or nil while the Monitor is not running.
    /// This is derived from the capture state, so a delegate stop clears it in
    /// the same main-actor turn even when the consumer uses this module alone.
    ///
    /// Its output size is rebased when the capture settles at a shape the
    /// stream was not configured for: what it reports is then the shape the
    /// Monitor is running, which is the only one a later rung change can be a
    /// fraction of.
    public var configuration: MonitorConfiguration? {
        stream.isRunning ? requestedConfiguration : nil
    }

    private let stream: SeatCaptureStream
    private var policy: MonitorQualityPolicy

    /// The layers this Monitor presents to. Held strongly because a consumer
    /// legitimately hands one over and keeps only the view it put it in;
    /// `release(_:)` is the explicit end of that ownership.
    private var attachedLayers: [MonitorLayer] = []
    private var requestedConfiguration: MonitorConfiguration?
    private var isEvaluatingQuality = false
    private var lastProduced  = 0
    private var lastCoalesced = 0

    /// The previous heartbeat's reading of what the capture filled. Two of them
    /// agreeing is the settle budget of `MonitorConfiguration.following`.
    private var previousContentPixelSize: CGSize?

    public init(displayID: CGDirectDisplayID, displayGeneration: UInt64 = 1) {
        self.displayID = displayID
        self.stream    = SeatCaptureStream(
            target           : .display(displayID),
            displayGeneration: displayGeneration
        )
        self.policy    = MonitorQualityPolicy()
    }

    // MARK: Layers

    /// Hands out a layer the Monitor presents every frame to.
    ///
    /// More than one is legitimate: a `CALayer` has a single superlayer, so a
    /// consumer showing the same Monitor in two places asks twice. Each layer
    /// receives the same surface, which costs a reference and no pixels.
    public func makeLayer(contentsScale: CGFloat) -> MonitorLayer {
        let layer = MonitorLayer(contentsScale: contentsScale)
        attach(layer)
        return layer
    }

    /// Attaches a layer the consumer built itself, which is how a subclass gets
    /// on the presentation path: the benchmark that gates spec section 8
    /// measures callback to screen by wrapping `present`.
    public func attach(_ layer: MonitorLayer) {
        stream.attach(layer)
        attachedLayers.append(layer)
    }

    public func release(_ layer: MonitorLayer) {
        stream.detach(layer)
        attachedLayers.removeAll { $0 === layer }
    }

    /// What the Monitor is showing and how much is known about when it was true.
    ///
    /// The Monitor is always the live view of the **Virtual Display**, never a
    /// stream of the agent's target, and this value says nothing about the
    /// agent's observation: a stale preview is not a stale Frame and a live
    /// preview certifies no freshness, no containment and no focus.
    public var presentation: MonitorPresentation {
        guard let layer = attachedLayers.last else { return .nothingPresented }
        return layer.presentation
    }

    /// Marks every attached layer's image stale, keeping it on screen.
    ///
    /// It is called when the capture stops, spontaneously or on request. Blanking
    /// the layer would hide that the preview stopped; leaving it unmarked would
    /// present an old picture as current. Neither is acceptable, so the image
    /// stays and says what it is.
    public func markPresentationStale() {
        for layer in attachedLayers { layer.markStale() }
    }

    // MARK: Lifecycle

    /// Starts the preview. Explicit, as everywhere in this module: a stream
    /// costs a window server pipeline and three surfaces, and it has to appear
    /// in a benchmark rather than because somebody read a property.
    ///
    /// The 120 level is refused unless the display really runs at 120 Hz. The
    /// zero-copy pipeline is not the bottleneck at 120, but a producer redrawing
    /// at 60 makes ScreenCaptureKit deliver 60, and a level that measures 60 and
    /// reports 120 is worse than one that says no.
    nonisolated public func start(
        configuration: MonitorConfiguration,
        timeout      : Duration = .seconds(5)
    ) async throws {

        let deadline = CaptureDeadline(timeout: timeout)
        try await start(configuration: configuration, deadline: deadline)
    }

    private func start(
        configuration: MonitorConfiguration,
        deadline     : CaptureDeadline
    ) async throws {

        if let refusal = stream.startRefusal { throw refusal }
        try deadline.check(.streamStart)

        if configuration.targetFrameRate == .oneHundredTwenty {
            let refreshRate = CGDisplayCopyDisplayMode(displayID)?.refreshRate ?? 0
            guard refreshRate >= 120 else {
                throw CaptureFailure.frameRateUnsupported(
                    requested         : configuration.targetFrameRate.rawValue,
                    displayRefreshRate: refreshRate
                )
            }
        }

        policy = MonitorQualityPolicy(quality: configuration.quality)
        try await stream.start(
            configuration: configuration.captureConfiguration(for: policy.quality),
            deadline     : deadline
        )
        requestedConfiguration   = configuration
        lastProduced             = 0
        lastCoalesced            = 0
        previousContentPixelSize = nil
    }

    nonisolated public func stop(timeout: Duration = .seconds(5)) async {
        let deadline = CaptureDeadline(timeout: timeout)
        await stop(deadline: deadline)
    }

    private func stop(deadline: CaptureDeadline) async {
        requestedConfiguration = nil
        markPresentationStale()
        await stream.stop(deadline: deadline)
    }

    // MARK: Quality

    /// Frames the pipeline produced since the Monitor started, coalesced ones
    /// included. The consumer's frame rate text reads this.
    public var producedFrameCount: Int { stream.producedFrameCount }

    /// Frames the newest-wins slot threw away since the Monitor started.
    public var coalescedFrameCount: Int { stream.coalescedFrameCount }

    /// Takes one reading and applies the degradation policy, returning the
    /// level change it caused: the `monitorQualityChanged(from:to:reason:)` of
    /// spec section 5, handed back to the caller that asked.
    ///
    /// The coalescence rate is computed over the window since the previous
    /// call, not since the start: a rate diluted by ten quiet minutes never
    /// crosses a one percent limit, and the point of the signal is to notice
    /// the second in which the pipeline fell behind.
    ///
    /// `attributableCpuPercent` is the share of one core the caller attributes to
    /// the Monitor, **not** the process total: the scene a Monitor films costs
    /// more than the Monitor does, and a policy handed the total degrades a
    /// Monitor that is keeping up. A caller with no way to attribute a share
    /// passes nothing.
    ///
    /// A refused reconfiguration leaves the committed quality unchanged. A
    /// late framework result can instead terminate the stream when its applied
    /// configuration is unknown; consumers observe that through the lifecycle.
    @discardableResult
    public func evaluate(attributableCpuPercent: Double? = nil) async -> MonitorQualityChange? {

        guard !isEvaluatingQuality, let configuration else { return nil }
        isEvaluatingQuality = true
        defer { isEvaluatingQuality = false }

        let contentPixelSize     = stream.lastContentPixelSize
        let previousReading      = previousContentPixelSize
        previousContentPixelSize = contentPixelSize

        let produced  = stream.producedFrameCount
        let coalesced = stream.coalescedFrameCount
        let windowProduced  = produced  - lastProduced
        let windowCoalesced = coalesced - lastCoalesced
        lastProduced  = produced
        lastCoalesced = coalesced

        let rate = windowProduced > 0 ? Double(windowCoalesced) / Double(windowProduced) : 0
        var candidate = policy
        guard let change = candidate.evaluate(
            coalescenceRate       : rate,
            attributableCpuPercent: attributableCpuPercent
        ) else {
            policy = candidate
            await followTargetShape(
                contentPixelSize: contentPixelSize,
                previousReading : previousReading,
                asked           : configuration
            )
            return nil
        }

        do {
            try await stream.updateConfiguration(
                configuration.captureConfiguration(for: change.to)
            )
        } catch {
            Self.log.error("""
                monitor quality change refused: \(String(describing: error), privacy: .public)
                """)
            return nil
        }

        policy = candidate
        Self.log.info("""
            monitor quality \(change.from.frameRate.rawValue, privacy: .public) fps \
            x\(change.from.resolutionScale, privacy: .public) -> \
            \(change.to.frameRate.rawValue, privacy: .public) fps \
            x\(change.to.resolutionScale, privacy: .public), \
            \(String(describing: change.reason), privacy: .public)
            """)
        return change
    }

    /// Follows the target's shape when the capture has settled at one the
    /// stream was not configured for.
    ///
    /// The geometry it decides on is the geometry the frames already carry:
    /// ScreenCaptureKit attaches the content rectangle to every sample, the
    /// stream keeps the last one as `lastContentPixelSize`, and this reads it on
    /// the heartbeat the consumer already pays for. Nothing new travels from the
    /// seat to the Monitor, because nothing has to: the seat's observation of a
    /// window is about the agent's target, and this is about the shape of the
    /// surface this stream is being handed.
    ///
    /// It runs on a beat the ladder left alone, and that is the arbitration
    /// between the two: `SeatCaptureStream.updateConfiguration` refuses an
    /// update while one is in flight, so a beat carries one reconfiguration or
    /// none. The rung is the more urgent of the two, a pipeline that is behind
    /// rather than one wasting pixels, and a follow that lost its beat is still
    /// true on the next one.
    ///
    /// What a reconfiguration costs is why it is worth spending here.
    /// `SCStream.updateConfiguration` replaces the surface pool without tearing
    /// the pipeline down, so the price is the frames in flight through it, which
    /// is a hitch of a frame or two in the preview and nothing in the agent's
    /// observation, which does not read this stream. The band it removes is
    /// permanent. `CaptureShapeStabilisation` is the line under which the trade
    /// stops being worth making, and the one place that line is written: the
    /// Lab's own preview stream follows a shape by the same rule.
    private func followTargetShape(
        contentPixelSize: CGSize?,
        previousReading : CGSize?,
        asked           : MonitorConfiguration
    ) async {

        guard let contentPixelSize,
              let followed = asked.following(
                  contentPixelSize: contentPixelSize,
                  previousReading : previousReading,
                  at              : policy.quality
              )
        else { return }

        do {
            try await stream.updateConfiguration(
                followed.captureConfiguration(for: policy.quality)
            )
        } catch {
            Self.log.error("""
                monitor shape follow refused: \(String(describing: error), privacy: .public)
                """)
            return
        }

        // A stop or a restart during the update owns the configuration now, and
        // the shape this followed belongs to the run that has already ended.
        guard requestedConfiguration == asked else { return }
        requestedConfiguration = followed
        Self.log.info("""
            monitor follows target shape to \
            \(Int(contentPixelSize.width), privacy: .public)x\
            \(Int(contentPixelSize.height), privacy: .public) at \
            x\(self.policy.quality.resolutionScale, privacy: .public)
            """)
    }

}
