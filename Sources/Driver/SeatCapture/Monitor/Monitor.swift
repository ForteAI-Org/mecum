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
        requestedConfiguration = configuration
        lastProduced            = 0
        lastCoalesced           = 0
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

}
