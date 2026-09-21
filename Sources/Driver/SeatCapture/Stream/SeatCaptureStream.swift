//
//  SeatCaptureStream.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import CoreMedia
import Darwin
import Foundation
import os
import SeatCore
import ScreenCaptureKit
import Synchronization
import WindowPlacement

/// FrameReceiver is the half of the stream that lives on the ScreenCaptureKit
/// queue: it turns a sample buffer into a `SeatFrame`, drops what should not be
/// presented, and hands the newest frame to the main actor.
///
/// Everything here is `nonisolated` and lock protected because the callback is
/// not a concurrency context and must not become one: an actor hop per frame at
/// 60 fps is an allocation and a scheduling round trip the zero-copy budget
/// does not have room for.
///
/// ## Newest wins, and that is the primary quality signal
///
/// One slot holds the frame waiting for the main actor. A frame that arrives
/// while the slot is still full replaces it, and the replaced one is counted as
/// **coalesced**. That count is free to take and is the first thing the quality
/// policy reads: it says the presenting side could not keep up, before any CPU
/// measurement can.
nonisolated final class FrameReceiver:
    NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    /// What this receiver stamps on every frame it builds.
    let displayGeneration: UInt64

    /// Which `start` attempt owns this receiver. It identifies lifecycle
    /// callbacks and is also the owner-local generation of frame geometry
    /// observations.
    let captureGeneration: UInt64

    /// The exact display, attested window or explicitly unverified legacy
    /// Window ID this receiver was configured to capture.
    let source: FrameSourceIdentity

    /// True only for a single-window pipeline configured to exclude shadows
    /// and screen-edge clipping.
    let capturesFullWindow: Bool

    /// Explicit crop metadata for an attested hosted-sheet family. Attachments
    /// on that filter can still report the host's stale content rectangle; the
    /// crop is the measured union requested from the display.
    let framing: (screenRect: CGRect, sourceWindowFrame: CGRect?)?

    /// What it still accepts. `stop()` moves it past the stamped one, so every
    /// frame already in flight for a display that is going away is dropped
    /// instead of presented.
    private let acceptedGeneration: Atomic<UInt64>

    private struct Slot {
        var frame     : SeatFrame?
        var produced  = 0
        var coalesced = 0
        var stale     = 0
        var nextObservedRevision: UInt64 = 0
        var sourceWasInvalidated = false
    }

    private let slot: Mutex<Slot>

    /// What runs on the main actor for each frame that made it through. The
    /// stream sets it, weakly, so the receiver never keeps the stream alive.
    private let present: @MainActor @Sendable (SeatFrame, UInt64) -> Void

    /// Reported when ScreenCaptureKit stops the stream on its own, which is
    /// what happens when the display it was filtering disappears.
    private let stopped: @Sendable (UInt64, ObjectIdentifier, CaptureFailure) -> Void

    /// Revalidates an identity-bound window before its identity is stamped on
    /// a sample. Display and raw-window captures need no identity query. This
    /// performs bounded WindowServer ownership calls under a gate cached at
    /// stream start; its 60 fps cost has not yet been measured.
    private let sourceFailure: @Sendable () -> CaptureFailure?

    /// Tells the owning actor once that this receiver's configured Window
    /// identity disappeared. This is distinct from `didStopWithError`: Apple
    /// has not certified that the SCStream stopped, so the owner must stop the
    /// exact retained resource and wait for its acknowledgement.
    private let sourceInvalidated: @Sendable (
        UInt64,
        ObjectIdentifier,
        CaptureFailure
    ) -> Void

    /// How a block reaches the main actor. It is `DispatchQueue.main.async` in
    /// every build and a manual queue in the tests, which is the only way to
    /// assert on the newest-wins slot without a real display: the assertion is
    /// about what happens **while** the main actor has not run yet.
    private let hop: @Sendable (@escaping @Sendable () -> Void) -> Void

    init(
        displayGeneration: UInt64,
        captureGeneration: UInt64 = 1,
        source           : FrameSourceIdentity = .display(0),
        capturesFullWindow: Bool = false,
        framing          : (screenRect: CGRect, sourceWindowFrame: CGRect?)? = nil,
        present          : @escaping @MainActor @Sendable (SeatFrame, UInt64) -> Void,
        stopped          : @escaping @Sendable (UInt64, ObjectIdentifier, CaptureFailure) -> Void,
        sourceFailure    : @escaping @Sendable () -> CaptureFailure? = { nil },
        sourceInvalidated: @escaping @Sendable (
            UInt64,
            ObjectIdentifier,
            CaptureFailure
        ) -> Void = { _, _, _ in },
        hop              : @escaping @Sendable (@escaping @Sendable () -> Void) -> Void
            = { block in DispatchQueue.main.async(execute: block) }
    ) {
        self.displayGeneration  = displayGeneration
        self.captureGeneration  = captureGeneration
        self.source             = source
        self.capturesFullWindow = capturesFullWindow
        self.framing           = framing
        self.acceptedGeneration = Atomic(displayGeneration)
        self.slot               = Mutex(Slot())
        self.present            = present
        self.stopped            = stopped
        self.sourceFailure      = sourceFailure
        self.sourceInvalidated  = sourceInvalidated
        self.hop                = hop
    }

    var counts: (produced: Int, coalesced: Int, stale: Int) {
        slot.withLock { ($0.produced, $0.coalesced, $0.stale) }
    }

    /// Refuses every further frame of the generation this receiver was built
    /// for. Called by `stop()`, and idempotent.
    func refuseFurtherFrames() {
        acceptedGeneration.store(displayGeneration &+ 1, ordering: .sequentiallyConsistent)
    }

    /// The one path a frame takes, whether it came from ScreenCaptureKit or
    /// from a test: generation gate, newest-wins slot, one hop to the main
    /// actor.
    ///
    /// The hop is `DispatchQueue.main.async` and not a `Task`. It has to be:
    /// the caller of a virtual display drives its own AppKit event pump (ADR
    /// 0007), and a main queue block runs under that pump while a `Task` on the
    /// main actor does not.
    func deliver(_ frame: SeatFrame) {

        guard frame.displayGeneration == acceptedGeneration.load(ordering: .sequentiallyConsistent)
        else {
            slot.withLock { $0.stale += 1 }
            return
        }

        let slotWasFull = slot.withLock { state -> Bool in
            let wasFull = state.frame != nil
            state.frame = frame
            state.produced += 1
            if wasFull { state.coalesced += 1 }
            return wasFull
        }
        guard !slotWasFull else { return }

        hop { [self] in
            MainActor.assumeIsolated {
                guard let pending = slot.withLock({ state -> SeatFrame? in
                    defer { state.frame = nil }
                    return state.frame
                }) else { return }
                guard pending.displayGeneration
                        == acceptedGeneration.load(ordering: .sequentiallyConsistent)
                else {
                    slot.withLock { $0.stale += 1 }
                    return
                }
                present(pending, captureGeneration)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        stopped(captureGeneration, ObjectIdentifier(stream), CaptureFailure.wrapping(error))
    }

    func stream(
        _ stream        : SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType   : SCStreamOutputType
    ) {
        let receivedAt = mach_absolute_time()
        guard outputType == .screen,
              sampleBuffer.isValid,
              Self.isComplete(sampleBuffer)
        else { return }
        guard displayGeneration
                == acceptedGeneration.load(ordering: .sequentiallyConsistent)
        else {
            slot.withLock { $0.stale += 1 }
            return
        }
        if let failure = sourceFailure() {
            let shouldReport = slot.withLock { state -> Bool in
                guard !state.sourceWasInvalidated else { return false }
                state.sourceWasInvalidated = true
                state.stale += 1
                return true
            }
            guard shouldReport else { return }
            refuseFurtherFrames()
            sourceInvalidated(captureGeneration, ObjectIdentifier(stream), failure)
            return
        }
        let observedRevision = slot.withLock { state -> UInt64 in
            state.nextObservedRevision &+= 1
            return state.nextObservedRevision
        }
        guard let frame = SeatFrame(
            sampleBuffer     : sampleBuffer,
            source           : source,
            displayGeneration: displayGeneration,
            captureGeneration: captureGeneration,
            observedRevision : observedRevision,
            capturesFullWindow: capturesFullWindow,
            framing           : framing,
            receivedAt       : receivedAt
        ) else { return }
        deliver(frame)
    }

    /// Only `complete` is a frame. `idle`, `blank` and `suspended` are
    /// ScreenCaptureKit saying the screen did not change, and counting them
    /// would make a still desktop look like a stream running at full rate
    /// (research note 05, section 12).
    static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]]
        // ponytail: on macOS 27 (26A428) ScreenCaptureKit delivers the frames
        // of some windows (Slack, an Electron app) with no attachments at all,
        // while still carrying a real image. A buffer with an image and no
        // status is treated as complete; SeatFrame then derives the geometry.
        // Ceiling: an idle/blank frame of such a window is counted as produced.
        if attachments == nil || attachments?.isEmpty == true {
            return sampleBuffer.imageBuffer != nil
        }
        guard let raw = attachments?.first?[.status] as? Int else { return false }
        return SCFrameStatus(rawValue: raw) == .complete
    }
}

/// SeatCaptureStream is one owner of one capture: the Virtual Display for the
/// Monitor the person watches, or one Adopted Window for observation.
///
/// `start` and `stop` are explicit and there is no implicit start on the first
/// consumer of `frames`. A stream costs a window server pipeline and three
/// surfaces, so it has to be something a caller asked for and a benchmark can
/// see, not something that appears because somebody iterated a sequence.
///
/// `frames` buffers the newest one, and the layers attached with `attach` are
/// presented before it is yielded: the person's preview never waits on a
/// consumer of the data.
@MainActor
public final class SeatCaptureStream {

    nonisolated private static let log = Logger(
        subsystem: "dev.forte.AgentSeatKit",
        category : "capture"
    )

    /// What this stream captures.
    public let target: SeatCaptureTarget

    /// The instance of the Virtual Display these frames belong to. A frame
    /// carries it so a consumer that kept one can tell it is looking at pixels
    /// from a screen that no longer exists.
    public let displayGeneration: UInt64

    /// The frames, newest one buffered. Every terminal lifecycle path finishes
    /// it, and a stopped or failed owner does not start again: make another one.
    public let frames: AsyncStream<SeatFrame>

    /// The configuration the stream is running with. Starting, stopping and
    /// failed owners report nil, so a consumer never mistakes an in-flight or
    /// spontaneously stopped pipeline for an active one.
    public private(set) var configuration: SeatCaptureConfiguration?

    /// The exact lifecycle state of this owner. `isRunning` is derived from it
    /// and is true only for `.running`.
    public private(set) var state: CaptureLifecycle = .idle

    /// The pixel size the content of the last presented frame actually filled.
    ///
    /// It equals the configured `pixelSize` only while the source still has the
    /// shape the stream was started with. ScreenCaptureKit does not stretch a
    /// source that changed shape to fill a buffer whose size was fixed at
    /// start: it writes the content where it fits and leaves the rest black, so
    /// a reading smaller than the configuration is that black band, measured.
    ///
    /// It is read on a heartbeat and never on the frame path, which is why the
    /// frame path only stores it. `Monitor.evaluate` is the shipped reader; a
    /// consumer driving a stream of its own compares it with
    /// `configuration?.pixelSize` on a heartbeat of its own.
    public private(set) var lastContentPixelSize: CGSize?

    private let continuation: AsyncStream<SeatFrame>.Continuation
    private var receiver          : FrameReceiver?
    private var stream            : SCStream?
    private var layers            : [MonitorLayer] = []
    private var pendingStartupFrame: SeatFrame?
    private var nextGeneration    : UInt64 = 0
    private var nextStopAttemptID : UInt64 = 0
    private var isStartPending    = false
    private var isStopCallPending = false
    private var pendingStopAttemptID: UInt64?
    private var isStopRequested   = false
    private var isStopAcknowledgedWhileStarting = false
    private var pendingConfigurationUpdate: StreamConfigurationRequestIdentity?

    private var nextObserverID: UInt64 = 0
    private var stateObservers: [UInt64: AsyncStream<CaptureLifecycle>.Continuation] = [:]

    /// The queue ScreenCaptureKit delivers on. Named, because an unnamed queue
    /// cannot be attributed in a per-thread CPU measurement (research note 05).
    private let deliveryQueue = DispatchQueue(
        label: "dev.forte.AgentSeatKit.capture.frames",
        qos  : .userInitiated
    )

    public init(target: SeatCaptureTarget, displayGeneration: UInt64 = 1) {
        self.target            = target
        self.displayGeneration = displayGeneration
        let pair = AsyncStream<SeatFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.frames       = pair.stream
        self.continuation = pair.continuation
    }

    isolated deinit {
        receiver?.refuseFurtherFrames()
        continuation.finish()
        for observer in stateObservers.values { observer.finish() }
    }

    /// stateChanges makes one independent lifecycle subscription. It starts
    /// with the current state and finishes only after the framework resource is
    /// known to be inactive. Each access is a new subscription, so consumers do
    /// not steal state changes from each other.
    public var stateChanges: AsyncStream<CaptureLifecycle> {
        let pair = AsyncStream<CaptureLifecycle>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        pair.continuation.yield(state)

        if isStateConsumerTerminal {
            pair.continuation.finish()
            return pair.stream
        }

        nextObserverID &+= 1
        let observerID = nextObserverID
        stateObservers[observerID] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    _ = self?.stateObservers.removeValue(forKey: observerID)
                }
            }
        }
        return pair.stream
    }

    // MARK: Counters

    /// Frames that passed the generation gate, coalesced ones included.
    public var producedFrameCount: Int { receiver?.counts.produced ?? 0 }

    /// Frames the newest-wins slot threw away because the main actor had not
    /// presented the previous one yet. The primary degradation signal.
    public var coalescedFrameCount: Int { receiver?.counts.coalesced ?? 0 }

    /// Frames dropped because they belonged to a display generation this stream
    /// no longer accepts.
    public var staleFrameCount: Int { receiver?.counts.stale ?? 0 }

    /// Identity-bound sources invalidated while this owner was alive. The
    /// count survives release of a failed receiver, unlike per-generation
    /// frame counters.
    public private(set) var sourceInvalidationCount: Int = 0

    /// Coalesced over produced, in 0...1. Zero when nothing was produced, which
    /// reads as "no evidence of a problem" and is the right answer: a stream
    /// with no frames has not fallen behind.
    public var coalescenceRate: Double {
        let counts = receiver?.counts ?? (produced: 0, coalesced: 0, stale: 0)
        guard counts.produced > 0 else { return 0 }
        return Double(counts.coalesced) / Double(counts.produced)
    }

    public var isRunning: Bool { state.isRunning }

    /// True while the owner still retains a ScreenCaptureKit object whose stop
    /// has not been conclusively observed. A failed stop keeps this true and
    /// blocks `start`; direct module consumers can retain the owner and retry.
    public var hasUnconfirmedResource: Bool { stream != nil }

    // MARK: Layers

    /// Attaches a layer the stream presents every frame to, before the frame is
    /// yielded to `frames`.
    ///
    /// More than one is allowed and is the ordinary case: a consumer that shows
    /// the same Monitor in two places needs two layers, because a `CALayer` has
    /// one superlayer.
    public func attach(_ layer: MonitorLayer) {
        switch state {
        case .idle, .starting, .running:
            break
        case .stopping, .stopped, .failed:
            return
        }
        guard !layers.contains(where: { $0 === layer }) else { return }
        layers.append(layer)
    }

    public func detach(_ layer: MonitorLayer) {
        layers.removeAll { $0 === layer }
    }

    /// How many layers a frame is presented to. Internal: it is bookkeeping the
    /// unit tier asserts on, not something a consumer needs.
    var attachedLayerCount: Int { layers.count }

    // MARK: Lifecycle

    /// Starts the capture. Explicit, and refuses a second start rather than
    /// silently restarting: two live streams on one target is the thing the
    /// single owner invariant exists to prevent.
    nonisolated public func start(
        configuration: SeatCaptureConfiguration,
        timeout      : Duration = .seconds(5)
    ) async throws {

        let deadline = CaptureDeadline(timeout: timeout)
        try await start(configuration: configuration, deadline: deadline)
    }

    func start(
        configuration: SeatCaptureConfiguration,
        deadline     : CaptureDeadline
    ) async throws {

        if let refusal = startRefusal { throw refusal }

        nextGeneration &+= 1
        let generation = nextGeneration
        transition(to: .starting(generation: generation))

        try await withTaskCancellationHandler {
            try await start(
                configuration: configuration,
                generation   : generation,
                deadline     : deadline
            )
        } onCancel: {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard self?.cancelStart(generation: generation) == true else { return }
                    Task { @MainActor [weak self] in await self?.stopAfterCancelledStart() }
                }
            }
        }
    }

    /// Changes size or pace without tearing the pipeline down. This is how the
    /// quality policy degrades: `stopCapture` then `startCapture` would cost a
    /// visible black gap in the person's preview for something meant to be
    /// invisible.
    nonisolated public func updateConfiguration(
        _ configuration: SeatCaptureConfiguration,
        timeout        : Duration = .seconds(2)
    ) async throws {

        let deadline = CaptureDeadline(timeout: timeout)
        try await updateConfiguration(configuration, deadline: deadline)
    }

    func updateConfiguration(
        _ configuration: SeatCaptureConfiguration,
        deadline       : CaptureDeadline
    ) async throws {

        guard case .running = state, let stream else { throw CaptureFailure.notStarted }
        guard let generation = state.generation else { throw CaptureFailure.notStarted }
        try deadline.check(.configurationUpdate)

        let streamIdentity = StreamRequestIdentity(
            streamIdentifier : ObjectIdentifier(stream),
            source           : target.sourceIdentity,
            displayGeneration: displayGeneration,
            captureGeneration: generation
        )
        let requestIdentity = StreamConfigurationRequestIdentity(
            stream          : streamIdentity,
            pixelWidthBits  : Double(configuration.pixelSize.width).bitPattern,
            pixelHeightBits : Double(configuration.pixelSize.height).bitPattern,
            framesPerSecond : configuration.framesPerSecond
        )
        let compatibilityKey = CaptureCompatibilityKey.configurationUpdate(requestIdentity)
        guard pendingConfigurationUpdate == nil else {
            throw CaptureFailure.configurationUpdateInProgress
        }
        pendingConfigurationUpdate = requestIdentity
        let streamHandoff = Handoff(value: stream)
        let configurationHandoff = Handoff(
            value: configuration.makeStreamConfiguration(for: target)
        )
        let callWitness = CaptureCallWitness()

        do {
            let _: Void = try await CaptureFrameworkCoordinator.shared.value(
                key      : compatibilityKey,
                step     : .configurationUpdate,
                allowsQueue: false,
                deadline : deadline,
                operation: { completion in
                    callWitness.markStarted()
                    streamHandoff.value.updateConfiguration(configurationHandoff.value) { error in
                        callWitness.markCompleted(succeeded: error == nil)
                        if let error {
                            completion(.failure(CaptureFailure.wrapping(error)))
                        } else {
                            completion(.success(()))
                        }
                    }
                },
                onDiscard: { [self] result in
                    DispatchQueue.main.async { [self] in
                        MainActor.assumeIsolated {
                            self.retiredConfigurationCompleted(
                                capture     : streamHandoff.value,
                                generation  : generation,
                                request     : requestIdentity,
                                result      : result
                            )
                        }
                    }
                }
            )
        } catch {
            let call = callWitness.snapshot
            if !call.started || call.completed {
                if pendingConfigurationUpdate == requestIdentity {
                    pendingConfigurationUpdate = nil
                }
                if call.succeeded {
                    invalidateConfigurationState(capture: stream, generation: generation)
                }
            }
            throw CaptureFailure.wrapping(error)
        }
        do {
            try deadline.check(.configurationUpdate)
        } catch {
            if pendingConfigurationUpdate == requestIdentity {
                pendingConfigurationUpdate = nil
            }
            invalidateConfigurationState(capture: stream, generation: generation)
            throw CaptureFailure.wrapping(error)
        }
        guard owns(stream, generation: generation), case .running = state
        else { throw CaptureFailure.notStarted }
        if pendingConfigurationUpdate == requestIdentity { pendingConfigurationUpdate = nil }
        self.configuration = configuration
    }

    /// Stops the capture and finishes `frames`. Idempotent, and safe to call
    /// before `start`: a consumer already waiting on `frames` is released.
    nonisolated public func stop(timeout: Duration = .seconds(5)) async {
        let deadline = CaptureDeadline(timeout: timeout)
        await stop(deadline: deadline)
    }

    func stop(deadline: CaptureDeadline) async {

        let generation = state.generation ?? 0

        switch state {
        case .idle:
            finishFrameConsumers()
            transition(to: .stopped(generation: 0))
            finishStateConsumers()
            return

        case .stopped:
            finishFrameConsumers()
            finishStateConsumers()
            return

        case .failed where stream == nil:
            finishFrameConsumers()
            finishStateConsumers()
            return

        case .starting, .running, .stopping, .failed:
            isStopRequested = true
            transition(to: .stopping(generation: generation))
            finishFrameConsumers()
        }

        guard let capture = stream else {
            transition(to: .stopped(generation: generation))
            finishStateConsumers()
            return
        }

        await stopCapture(
            capture   : capture,
            generation: generation,
            deadline  : deadline
        )
    }

    /// The refusal is read by `Monitor` before it changes quality policy. This
    /// keeps a concurrent or terminal second start from mutating a running
    /// Monitor before `SeatCaptureStream.start` rejects it.
    var startRefusal: CaptureFailure? {
        switch state {
        case .idle:
            nil
        case .starting, .running, .stopping:
            .alreadyStarted
        case .failed where stream != nil:
            .alreadyStarted
        case .failed, .stopped:
            .notStarted
        }
    }

    private func start(
        configuration: SeatCaptureConfiguration,
        generation   : UInt64,
        deadline     : CaptureDeadline
    ) async throws {

        let identityWitness = Self.identityWitness(for: target)
        do {
            try Self.validateSourceBeforeContent(
                target,
                identityWitness: identityWitness
            )
        } catch {
            throw failStart(error, generation: generation)
        }
        try checkStartDeadline(deadline, generation: generation)

        let content: SCShareableContent
        do {
            content = try await shareableContent(deadline: deadline)
        } catch is CancellationError {
            cancelStart(generation: generation)
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                cancelStart(generation: generation)
                throw CancellationError()
            }
            throw failStart(error, generation: generation)
        }

        if Task.isCancelled {
            cancelStart(generation: generation)
            throw CancellationError()
        }
        guard state == .starting(generation: generation) else {
            throw CaptureFailure.notStarted
        }
        try checkStartDeadline(deadline, generation: generation)

        let filter: SCContentFilter
        do {
            filter = try Self.filter(
                for            : target,
                in             : content,
                identityWitness: identityWitness
            )
        } catch {
            if Task.isCancelled {
                cancelStart(generation: generation)
                throw CancellationError()
            }
            throw failStart(error, generation: generation)
        }

        let receiver = FrameReceiver(
            displayGeneration: displayGeneration,
            captureGeneration: generation,
            source           : target.sourceIdentity,
            capturesFullWindow: target.windowNumber != nil,
            framing          : target.framing,
            present          : { [weak self] frame, callbackGeneration in
                self?.present(frame, generation: callbackGeneration)
            },
            stopped          : { [weak self] callbackGeneration, streamIdentifier, failure in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.captureDidStop(
                            generation      : callbackGeneration,
                            streamIdentifier: streamIdentifier,
                            failure         : failure
                        )
                    }
                }
            },
            sourceFailure    : Self.sourceFailure(
                for            : target,
                identityWitness: identityWitness
            ),
            sourceInvalidated: { [weak self] callbackGeneration, streamIdentifier, failure in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.captureSourceInvalidated(
                            generation      : callbackGeneration,
                            streamIdentifier: streamIdentifier,
                            failure         : failure
                        )
                    }
                }
            }
        )
        let capture = SCStream(
            filter       : filter,
            configuration: configuration.makeStreamConfiguration(for: target),
            delegate     : receiver
        )

        do {
            try capture.addStreamOutput(
                receiver,
                type              : .screen,
                sampleHandlerQueue: deliveryQueue
            )
        } catch {
            if Task.isCancelled {
                cancelStart(generation: generation)
                throw CancellationError()
            }
            throw failStart(error, generation: generation)
        }

        guard state == .starting(generation: generation), !Task.isCancelled else {
            cancelStart(generation: generation)
            if Task.isCancelled { throw CancellationError() }
            throw CaptureFailure.notStarted
        }
        try checkStartDeadline(deadline, generation: generation)

        self.receiver   = receiver
        self.stream     = capture
        isStartPending  = true

        let captureHandoff = Handoff(value: capture)
        let callWitness = CaptureCallWitness()

        do {
            let _: Void = try await CaptureFrameworkCoordinator.shared.value(
                key        : nil,
                step       : .streamStart,
                allowsQueue: false,
                deadline   : deadline,
                operation  : { completion in
                    callWitness.markStarted()
                    captureHandoff.value.startCapture { error in
                        callWitness.markCompleted(succeeded: error == nil)
                        if let error {
                            completion(.failure(CaptureFailure.wrapping(error)))
                        } else {
                            completion(.success(()))
                        }
                    }
                },
                onDiscard  : { [self] result in
                    DispatchQueue.main.async { [self] in
                        MainActor.assumeIsolated {
                            self.retiredStartCompleted(
                                capture   : captureHandoff.value,
                                generation: generation,
                                result    : result
                            )
                        }
                    }
                }
            )
        } catch {
            guard owns(capture, generation: generation) else {
                throw terminalStartError(fallback: CaptureFailure.wrapping(error))
            }

            let call = callWitness.snapshot
            if call.completed { isStartPending = false }
            finishFrameConsumers()

            let isCancellation = error is CancellationError || Task.isCancelled
            let failure = isCancellation ? nil : CaptureFailure.wrapping(error)
            if isCancellation {
                isStopRequested = true
                transition(to: .stopping(generation: generation))
            } else if let failure, !isStopRequested {
                transition(to: .failed(
                    generation: generation,
                    failure   : preservedFailure(or: failure)
                ))
            }

            if call.started {
                scheduleStopCapture(capture: capture, generation: generation)
            } else {
                isStartPending = false
                self.receiver?.refuseFurtherFrames()
                self.receiver = nil
                stream = nil
                if isCancellation {
                    transition(to: .stopped(generation: generation))
                }
                finishStateConsumers()
            }

            if isCancellation { throw CancellationError() }
            throw failure ?? CaptureFailure.notStarted
        }

        guard owns(capture, generation: generation) else {
            // Reclaim an obsolete successful start before returning. There is
            // only one start generation per owner, so an empty slot can safely
            // retain this exact object until its final stop is confirmed.
            reclaimObsoleteStart(
                capture   : capture,
                receiver  : receiver,
                generation: generation
            )
            scheduleStopCapture(capture: capture, generation: generation)
            throw terminalStartError(fallback: .notStarted)
        }

        isStartPending = false

        if Task.isCancelled {
            isStopRequested = true
            transition(to: .stopping(generation: generation))
            finishFrameConsumers()
            scheduleStopCapture(capture: capture, generation: generation)
            throw CancellationError()
        }

        guard state == .starting(generation: generation) else {
            scheduleStopCapture(capture: capture, generation: generation)
            throw terminalStartError(fallback: .notStarted)
        }

        do {
            try deadline.check(.streamStart)
        } catch {
            let failure = CaptureFailure.wrapping(error)
            transition(to: .failed(generation: generation, failure: failure))
            finishFrameConsumers()
            scheduleStopCapture(capture: capture, generation: generation)
            throw failure
        }

        self.configuration = configuration
        transition(to: .running(generation: generation))
        presentPendingStartupFrame(generation: generation)
        Self.log.info("""
            capture started, \(String(describing: self.target), privacy: .public) \
            \(Int(configuration.pixelSize.width), privacy: .public)x\
            \(Int(configuration.pixelSize.height), privacy: .public) at \
            \(configuration.framesPerSecond, privacy: .public) fps, \
            generation \(generation, privacy: .public)
            """)
    }

    /// Requests stop for one exact stream. A failure retains the resource and
    /// its identity, so another `start` cannot allocate a duplicate pipeline
    /// and a later `stop` can retry the same object.
    private func stopCapture(
        capture   : SCStream,
        generation: UInt64,
        deadline  : CaptureDeadline
    ) async {

        guard owns(capture, generation: generation) else { return }
        if isStartPending, isStopAcknowledgedWhileStarting { return }

        let requestIdentity = StreamRequestIdentity(
            streamIdentifier : ObjectIdentifier(capture),
            source           : target.sourceIdentity,
            displayGeneration: displayGeneration,
            captureGeneration: generation
        )
        let compatibilityKey = CaptureCompatibilityKey.streamStop(requestIdentity)
        let attemptID: UInt64
        let joinsPendingAttempt: Bool
        if let pendingStopAttemptID {
            guard CaptureFrameworkCoordinator.shared.isAcceptingWaiters(
                for: compatibilityKey
            ) else { return }
            attemptID = pendingStopAttemptID
            joinsPendingAttempt = true
        } else {
            nextStopAttemptID &+= 1
            attemptID = nextStopAttemptID
            pendingStopAttemptID = attemptID
            joinsPendingAttempt = false
        }
        isStopCallPending = true
        isStopAcknowledgedWhileStarting = false
        let captureHandoff = Handoff(value: capture)
        let callWitness = CaptureCallWitness()

        do {
            let _: Void = try await CaptureFrameworkCoordinator.shared.value(
                key        : compatibilityKey,
                step       : .streamStop,
                callClass  : .cleanup,
                allowsQueue: true,
                deadline   : deadline,
                operation  : { completion in
                    callWitness.markStarted()
                    captureHandoff.value.stopCapture { error in
                        let result: Result<Void, CaptureFailure>
                        if let error {
                            result = .failure(CaptureFailure.wrapping(error))
                        } else {
                            result = .success(())
                        }
                        callWitness.markCompleted(succeeded: error == nil)
                        DispatchQueue.main.async { [self] in
                            MainActor.assumeIsolated {
                                self.completeStop(
                                    capture   : captureHandoff.value,
                                    generation: generation,
                                    attemptID : attemptID,
                                    result    : result
                                )
                            }
                        }
                        completion(result)
                    }
                }
            )
        } catch {
            guard owns(capture, generation: generation) else { return }
            if joinsPendingAttempt {
                if error is CancellationError { return }
                let failure = CaptureFailure.wrapping(error)
                switch failure {
                case .timedOut(.streamStop), .frameworkCallLimitReached(.streamStop):
                    return
                default:
                    completeStop(
                        capture   : capture,
                        generation: generation,
                        attemptID : attemptID,
                        result    : .failure(failure)
                    )
                    return
                }
            }
            let call = callWitness.snapshot
            if call.completed {
                completeStop(
                    capture   : capture,
                    generation: generation,
                    attemptID : attemptID,
                    result    : call.succeeded
                        ? .success(())
                        : .failure(CaptureFailure.wrapping(error))
                )
                return
            }
            guard !call.started else {
                // A started attempt is resolved only by its real callback.
                // That callback retains this owner through the main-actor
                // handoff, independently of every waiter.
                return
            }
            guard pendingStopAttemptID == attemptID else { return }
            pendingStopAttemptID = nil
            isStopCallPending = false

            let failure = CaptureFailure.wrapping(error)
            transition(to: .failed(
                generation: generation,
                failure   : preservedFailure(or: failure)
            ))
            Self.log.error("capture stop failed: \(String(describing: failure), privacy: .public)")
            return
        }

        // Make the acknowledged state visible before the public stop returns.
        // The real callback's strong handoff remains the independent owner;
        // the attempt guard makes whichever main-actor path runs second inert.
        completeStop(
            capture   : capture,
            generation: generation,
            attemptID : attemptID,
            result    : .success(())
        )
    }

    private func completeStop(
        capture   : SCStream,
        generation: UInt64,
        attemptID : UInt64,
        result    : Result<Void, CaptureFailure>
    ) {

        guard owns(capture, generation: generation),
              pendingStopAttemptID == attemptID
        else { return }
        pendingStopAttemptID = nil
        isStopCallPending = false

        if case .failure(let failure) = result {
            transition(to: .failed(
                generation: generation,
                failure   : preservedFailure(or: failure)
            ))
            Self.log.error("capture stop failed: \(String(describing: failure), privacy: .public)")
            return
        }

        // A stop that completes before the outstanding start is not final: its
        // late successful completion can activate the stream again. The start
        // path sees `stopping` and issues the final stop itself.
        guard !isStartPending else {
            isStopAcknowledgedWhileStarting = true
            return
        }

        let terminalFailure: CaptureFailure?
        if !isStopRequested, case .failed(_, let failure) = state {
            terminalFailure = failure
        } else {
            terminalFailure = nil
        }

        receiver?.refuseFurtherFrames()
        receiver = nil
        stream   = nil
        pendingConfigurationUpdate = nil
        isStopAcknowledgedWhileStarting = false

        if let terminalFailure {
            transition(to: .failed(generation: generation, failure: terminalFailure))
        } else {
            transition(to: .stopped(generation: generation))
        }
        finishStateConsumers()
    }

    /// Keeps cleanup outside the expired caller while retaining this owner and
    /// the exact framework object for one bounded stop attempt.
    private func scheduleStopCapture(capture: SCStream, generation: UInt64) {
        guard owns(capture, generation: generation) else { return }
        Task { @MainActor [self] in
            await stopCapture(
                capture   : capture,
                generation: generation,
                deadline  : CaptureDeadline(timeout: .seconds(5))
            )
        }
    }

    private func stopAfterCancelledStart() async {
        guard let capture = stream, let generation = state.generation else { return }
        await stopCapture(
            capture   : capture,
            generation: generation,
            deadline  : CaptureDeadline(timeout: .seconds(5))
        )
    }

    /// Handles the real start callback after its caller was retired. A success
    /// is never promoted to running; both outcomes retain and stop the exact
    /// object because a failed start does not certify cleanup either.
    private func retiredStartCompleted(
        capture   : SCStream,
        generation: UInt64,
        result    : Result<Void, CaptureFailure>
    ) {

        guard owns(capture, generation: generation) else { return }
        isStartPending = false
        isStopAcknowledgedWhileStarting = false
        finishFrameConsumers()

        if state == .starting(generation: generation) {
            let failure: CaptureFailure
            switch result {
            case .success:
                failure = .timedOut(.streamStart)
            case .failure(let observed):
                failure = observed
            }
            transition(to: .failed(generation: generation, failure: failure))
        }
        scheduleStopCapture(capture: capture, generation: generation)
    }

    /// Records what ScreenCaptureKit actually applied while refusing to turn a
    /// late callback into success for the caller whose budget already ended.
    private func retiredConfigurationCompleted(
        capture   : SCStream,
        generation: UInt64,
        request   : StreamConfigurationRequestIdentity,
        result    : Result<Void, CaptureFailure>
    ) {
        if pendingConfigurationUpdate == request { pendingConfigurationUpdate = nil }
        guard owns(capture, generation: generation), case .running = state else { return }
        invalidateConfigurationState(capture: capture, generation: generation)
    }

    private func invalidateConfigurationState(capture: SCStream, generation: UInt64) {
        guard owns(capture, generation: generation), case .running = state else { return }
        configuration = nil
        let failure = CaptureFailure.configurationStateUnknown
        transition(to: .failed(generation: generation, failure: failure))
        finishFrameConsumers()
        scheduleStopCapture(capture: capture, generation: generation)
    }

    private func preservedFailure(or fallback: CaptureFailure) -> CaptureFailure {
        guard !isStopRequested, case .failed(_, let failure) = state else { return fallback }
        return failure
    }

    private func checkStartDeadline(_ deadline: CaptureDeadline, generation: UInt64) throws {
        do {
            try deadline.check(.streamStart)
        } catch {
            throw failStart(error, generation: generation)
        }
    }

    /// Marks cancellation synchronously and answers whether an exact stream is
    /// already present and needs an asynchronous stop request.
    @discardableResult
    private func cancelStart(generation: UInt64) -> Bool {
        guard state == .starting(generation: generation) else { return false }
        isStopRequested = true
        transition(to: .stopping(generation: generation))
        finishFrameConsumers()

        // No SCStream exists while shareable content is pending. Retiring the
        // generation now makes its eventual callback harmless.
        guard stream != nil else {
            transition(to: .stopped(generation: generation))
            finishStateConsumers()
            return false
        }
        return true
    }

    private func captureDidStop(
        generation      : UInt64,
        streamIdentifier: ObjectIdentifier,
        failure         : CaptureFailure
    ) {

        guard let stream,
              ObjectIdentifier(stream) == streamIdentifier,
              state.generation == generation
        else {
            Self.log.debug("ignored obsolete capture stop callback, generation \(generation)")
            return
        }

        receiver?.refuseFurtherFrames()
        finishFrameConsumers()

        // A delegate stop while start is pending is not the final word: the
        // outstanding start completion can still arrive successfully. Keep
        // the exact object and generation until that ACK is handled.
        if isStartPending {
            if !isStopRequested {
                transition(to: .failed(generation: generation, failure: failure))
            }
            return
        }

        receiver         = nil
        self.stream       = nil
        isStopCallPending = false
        pendingStopAttemptID = nil
        pendingConfigurationUpdate = nil
        isStopAcknowledgedWhileStarting = false

        if isStopRequested {
            transition(to: .stopped(generation: generation))
        } else {
            transition(to: .failed(generation: generation, failure: failure))
            Self.log.error("stream stopped by ScreenCaptureKit: \(String(describing: failure), privacy: .public)")
        }
        finishStateConsumers()
    }

    /// A WindowServer ownership mismatch is evidence about the source, not an
    /// SCStream stop acknowledgement. Publish failure immediately, then stop
    /// the exact retained object through the normal ownership path.
    private func captureSourceInvalidated(
        generation      : UInt64,
        streamIdentifier: ObjectIdentifier,
        failure         : CaptureFailure
    ) {
        let acceptsInvalidation = state == .starting(generation: generation)
            || state == .running(generation: generation)
        guard let capture = stream,
              ObjectIdentifier(capture) == streamIdentifier,
              acceptsInvalidation
        else {
            Self.log.debug("ignored obsolete capture source invalidation, generation \(generation)")
            return
        }

        sourceInvalidationCount += 1
        receiver?.refuseFurtherFrames()
        finishFrameConsumers()
        transition(to: .failed(generation: generation, failure: failure))

        scheduleStopCapture(capture: capture, generation: generation)
    }

    private func failStart(_ error: any Error, generation: UInt64) -> CaptureFailure {
        let failure = CaptureFailure.wrapping(error)
        guard state == .starting(generation: generation) else { return .notStarted }
        finishFrameConsumers()
        transition(to: .failed(generation: generation, failure: failure))
        finishStateConsumers()
        return failure
    }

    private func terminalStartError(fallback: CaptureFailure) -> any Error {
        if Task.isCancelled { return CancellationError() }
        if case .failed(_, let failure) = state { return failure }
        return fallback
    }

    private func owns(_ capture: SCStream, generation: UInt64) -> Bool {
        stream === capture && state.generation == generation
    }

    private func reclaimObsoleteStart(
        capture   : SCStream,
        receiver  : FrameReceiver,
        generation: UInt64
    ) {
        guard stream == nil else { return }
        self.stream       = capture
        self.receiver     = receiver
        isStartPending    = false
        isStopRequested   = true
        transition(to: .stopping(generation: generation))
        finishFrameConsumers()
    }

    private func transition(to state: CaptureLifecycle) {
        guard self.state != state else { return }
        self.state = state
        for observer in stateObservers.values { observer.yield(state) }
    }

    private func finishFrameConsumers() {
        receiver?.refuseFurtherFrames()
        pendingStartupFrame = nil
        configuration = nil
        layers.removeAll()
        continuation.finish()
    }

    private func finishStateConsumers() {
        for observer in stateObservers.values { observer.finish() }
        stateObservers.removeAll()
    }

    private var isStateConsumerTerminal: Bool {
        switch state {
        case .stopped:
            true
        case .failed where stream == nil:
            true
        case .idle, .starting, .running, .stopping, .failed:
            false
        }
    }

    // MARK: Stills

    /// still takes one frame of this stream's target, on request, whether or
    /// not the stream is running.
    ///
    /// It is a Still and not a snapshot: a snapshot in this vocabulary is the
    /// accessibility model of a window, and the two would be impossible to tell
    /// apart in a report.
    nonisolated public func still(timeout: Duration = .seconds(2)) async throws -> SeatFrame {
        let deadline = CaptureDeadline(timeout: timeout)
        return try await still(deadline: deadline)
    }

    private func still(deadline: CaptureDeadline) async throws -> SeatFrame {
        try await Self.still(
            of               : target,
            pixelSize        : configuration?.pixelSize,
            displayGeneration: displayGeneration,
            captureGeneration: state.generation ?? 0,
            deadline         : deadline
        )
    }

    /// The one-shot capture, without a stream.
    ///
    /// `SCScreenshotManager` is asked for a sample buffer rather than a
    /// `CGImage` so that the result is a `SeatFrame` like any other, with the
    /// surface and the BGRA pixel buffer, and the caller decides whether it
    /// ever needs pixels it can read.
    ///
    /// The deadline is not decoration: the Ledger records that this completion
    /// handler sometimes does not arrive, and without a gate the caller would
    /// wait forever with no name for what went wrong.
    /// `observationBarrier` separates two otherwise identical requests that
    /// belong to different observational moments. A request issued after a
    /// Command completed must not join a job that started before it: the
    /// coalescing key carries the barrier so the later requester waits for a
    /// capture of its own instead of inheriting pre barrier pixels.
    nonisolated public static func still(
        of target        : SeatCaptureTarget,
        pixelSize        : CGSize?   = nil,
        displayGeneration: UInt64    = 0,
        captureGeneration: UInt64    = 0,
        observationBarrier: UInt64   = 0,
        timeout          : Duration  = .seconds(2)
    ) async throws -> SeatFrame {

        let deadline = CaptureDeadline(timeout: timeout)
        return try await still(
            of                : target,
            pixelSize         : pixelSize,
            displayGeneration : displayGeneration,
            captureGeneration : captureGeneration,
            observationBarrier: observationBarrier,
            deadline          : deadline
        )
    }

    /// Captures the first complete stream frame that carries WindowServer's
    /// documented display timestamp.
    ///
    /// `SCScreenshotManager` may return a valid image with no frame attachments.
    /// This fallback uses the ordinary stream lifecycle because its complete
    /// frames carry `SCStreamFrameInfoDisplayTime` on supported targets. Frames
    /// without that timestamp remain unqualified and are skipped until the
    /// capture deadline expires. The stream is stopped before this call returns.
    ///
    /// `pixelSize` is optional, and nil is the answer for every caller that has
    /// no reason of its own to pin a size. A stream's size is fixed when it
    /// starts and ScreenCaptureKit does not stretch a source that no longer has
    /// that shape to fill it: it writes the content where it fits and leaves the
    /// rest of the buffer black. A size measured for an earlier capture is
    /// therefore not a size for this one, and the window this fallback exists
    /// for is exactly the window a placement may have just resized. Nil takes
    /// the size from the filter this call builds, which is the same
    /// `naturalPixelSize` rule `still` has always used.
    ///
    /// The ceiling, and it is the reason a wrong size cannot be caught after the
    /// fact: `SeatFrame.fallbackGeometry`, which is what a frame arriving with
    /// no attachments is certified from, declares the content rectangle to be
    /// the whole surface by construction. A frame on that path reports a full
    /// buffer whatever is actually in it, so no content-rectangle reasoning,
    /// this one or `MonitorLayer.contentsRect`, can see a band on it. Sizing the
    /// capture correctly in the first place is the only defence there is.
    nonisolated package static func timestampedStill(
        of target        : SeatCaptureTarget,
        pixelSize        : CGSize? = nil,
        displayGeneration: UInt64 = 0,
        timeout          : Duration = .seconds(2)
    ) async throws -> SeatFrame {

        let deadline = CaptureDeadline(timeout: timeout)
        return try await timestampedStill(
            of                : target,
            pixelSize         : pixelSize,
            displayGeneration: displayGeneration,
            deadline         : deadline
        )
    }

    private static func timestampedStill(
        of target         : SeatCaptureTarget,
        pixelSize         : CGSize?,
        displayGeneration : UInt64,
        deadline          : CaptureDeadline
    ) async throws -> SeatFrame {

        // Resolved before the owner exists, so a target that cannot be sized
        // fails without a stream to stop.
        let size: CGSize
        if let pixelSize {
            size = pixelSize
        } else {
            size = try await naturalPixelSize(of: target, deadline: deadline)
        }

        let owner = SeatCaptureStream(
            target           : target,
            displayGeneration: displayGeneration
        )
        var capturedFrame: SeatFrame?
        var captureError : (any Error)?
        do {
            try await owner.start(
                configuration: SeatCaptureConfiguration(
                    pixelSize      : size,
                    framesPerSecond: 60
                ),
                deadline: deadline
            )
            let frame = try await firstTimestampedFrame(
                in      : owner.frames,
                deadline: deadline
            )
            capturedFrame = frame
        } catch {
            captureError = error
        }

        await owner.stop(deadline: CaptureDeadline(timeout: .seconds(5)))
        guard case .stopped = owner.state, !owner.hasUnconfirmedResource else {
            if case .failed(_, let failure) = owner.state { throw failure }
            throw CaptureFailure.timedOut(.streamStop)
        }
        if let captureError { throw captureError }
        try deadline.check(.still)
        guard let capturedFrame else { throw CaptureFailure.frameUnavailable }
        return capturedFrame
    }

    static func firstTimestampedFrame(
        in frames       : AsyncStream<SeatFrame>,
        deadline        : CaptureDeadline
    ) async throws -> SeatFrame {

        try deadline.check(.still)
        return try await withThrowingTaskGroup(of: SeatFrame.self) { group in
            group.addTask {
                let clock = MachAbsoluteContentClock()
                for await frame in frames {
                    try Task.checkCancellation()
                    try deadline.check(.still)
                    guard let ticks = frame.displayTime,
                          let displayedAt = clock.displayTimeNanoseconds(fromMachTicks: ticks),
                          displayedAt < deadline.expiresAt
                    else { continue }

                    // ScreenCaptureKit can deliver a frame before its scheduled display instant.
                    // Wait against the original deadline without changing the frame's timestamp.
                    var now = DispatchTime.now().uptimeNanoseconds
                    while displayedAt > now {
                        try await Task.sleep(nanoseconds: displayedAt - now)
                        try Task.checkCancellation()
                        try deadline.check(.still)
                        now = DispatchTime.now().uptimeNanoseconds
                    }
                    try deadline.check(.still)
                    return frame
                }
                try Task.checkCancellation()
                throw CaptureFailure.frameUnavailable
            }
            group.addTask {
                let remaining = deadline.remainingNanoseconds
                guard remaining > 0 else { throw CaptureFailure.timedOut(.still) }
                try await Task.sleep(nanoseconds: remaining)
                throw CaptureFailure.timedOut(.still)
            }
            defer { group.cancelAll() }
            guard let frame = try await group.next() else {
                throw CaptureFailure.frameUnavailable
            }
            return frame
        }
    }

    private static func still(
        of target         : SeatCaptureTarget,
        pixelSize         : CGSize?,
        displayGeneration : UInt64,
        captureGeneration : UInt64,
        observationBarrier: UInt64 = 0,
        deadline          : CaptureDeadline
    ) async throws -> SeatFrame {

        let identityWitness = identityWitness(for: target)
        try validateSourceBeforeContent(
            target,
            identityWitness: identityWitness
        )
        try deadline.check(.still)
        let content = try await shareableContent(deadline: deadline)
        try deadline.check(.still)
        let filter = try filter(
            for            : target,
            in             : content,
            identityWitness: identityWitness
        )
        let size    = pixelSize ?? naturalPixelSize(of: target, filter: filter)
        let configuration = SeatCaptureConfiguration(pixelSize: size, framesPerSecond: 60)
            .makeStillConfiguration(for: target)

        try deadline.check(.still)
        let requestIdentity = StillRequestIdentity(
            source            : target.sourceIdentity,
            pixelWidthBits    : Double(size.width).bitPattern,
            pixelHeightBits   : Double(size.height).bitPattern,
            framesPerSecond   : 60,
            displayGeneration : displayGeneration,
            captureGeneration : captureGeneration,
            observationBarrier: observationBarrier
        )
        let filterHandoff        = Handoff(value: filter)
        let configurationHandoff = Handoff(value: configuration)

        let reply: StillCaptureReply = try await CaptureFrameworkCoordinator.shared.value(
            key     : .still(requestIdentity),
            step    : .still,
            deadline: deadline
        ) { completion in
            SCScreenshotManager.captureSampleBuffer(
                contentFilter: filterHandoff.value,
                configuration: configurationHandoff.value
            ) { sampleBuffer, error in
                if let sampleBuffer {
                    completion(.success(StillCaptureReply(
                        sampleBuffer    : sampleBuffer,
                        receivedAt      : mach_absolute_time(),
                        observedRevision: StillObservationSequence.shared.next()
                    )))
                } else {
                    completion(.failure(
                        error.map(CaptureFailure.wrapping) ?? CaptureFailure.frameUnavailable
                    ))
                }
            }
        }

        try deadline.check(.still)
        if let failure = Self.sourceFailure(
            for            : target,
            identityWitness: identityWitness
        )() {
            throw failure
        }
        guard let frame = SeatFrame(
            sampleBuffer     : reply.sampleBuffer,
            source           : target.sourceIdentity,
            displayGeneration: displayGeneration,
            captureGeneration: captureGeneration,
            observedRevision : reply.observedRevision,
            capturesFullWindow: target.windowNumber != nil,
            framing           : target.framing,
            receivedAt       : reply.receivedAt
        ) else { throw CaptureFailure.frameUnavailable }
        try Task.checkCancellation()
        try deadline.check(.still)
        return frame
    }

    // MARK: Internals

    /// Presents on the main actor: the layers first, then the data consumers.
    ///
    /// The order is the point. The person's preview is what a dropped frame is
    /// visible in, so it is served before anything that might be slow, and the
    /// yield after it is a store into a one element buffer.
    private func present(_ frame: SeatFrame, generation: UInt64) {
        if state == .starting(generation: generation) {
            pendingStartupFrame = frame
            return
        }
        guard state == .running(generation: generation) else { return }
        presentToConsumers(frame)
    }

    /// Presents at most one frame retained while the matching start ACK was in
    /// flight. Stop and failure clear it through `finishFrameConsumers`.
    private func presentPendingStartupFrame(generation: UInt64) {
        guard state == .running(generation: generation), let frame = pendingStartupFrame else { return }
        pendingStartupFrame = nil
        presentToConsumers(frame)
    }

    private func presentToConsumers(_ frame: SeatFrame) {
        for layer in layers { layer.present(frame) }
        // Two multiplications, after the person's preview and before the yield:
        // the reading is taken here because only a frame carries the geometry.
        lastContentPixelSize = frame.geometry.contentPixelSize
        continuation.yield(frame)
    }

    /// The pixel size the target has now, read from a filter built for it here.
    ///
    /// It is the opening of `still` without the capture: the same identity
    /// binding before the shareable-content snapshot, the same deadline checks
    /// on both sides of it, and the same filter helper, so a target that cannot
    /// be filtered fails with the vocabulary it already fails with rather than a
    /// refusal of its own. The cost is one extra shareable-content fetch, which
    /// `CaptureFrameworkCoordinator` coalesces with any that is already in
    /// flight, on a path that is about to pay for a whole stream start and stop.
    private static func naturalPixelSize(
        of target: SeatCaptureTarget,
        deadline : CaptureDeadline
    ) async throws -> CGSize {

        let identityWitness = identityWitness(for: target)
        try validateSourceBeforeContent(
            target,
            identityWitness: identityWitness
        )
        try deadline.check(.still)
        let content = try await shareableContent(deadline: deadline)
        try deadline.check(.still)
        let filter = try filter(
            for            : target,
            in             : content,
            identityWitness: identityWitness
        )
        return naturalPixelSize(of: target, filter: filter)
    }

    /// The pixel size the target already has: the filter's own rectangle at its
    /// own scale. It is what a Still uses when the caller did not ask for a
    /// size, so that a screenshot of a window comes back at the window's real
    /// resolution instead of at some default.
    static func naturalPixelSize(of filter: SCContentFilter) -> CGSize {
        let scale = max(1, CGFloat(filter.pointPixelScale))
        return CGSize(
            width : max(1, filter.contentRect.width  * scale),
            height: max(1, filter.contentRect.height * scale)
        )
    }

    private static func naturalPixelSize(
        of target: SeatCaptureTarget,
        filter: SCContentFilter
    ) -> CGSize {
        guard case .attestedWindowRegion(_, _, let displayID, let screenRect, _) = target,
              let mode = CGDisplayCopyDisplayMode(displayID), mode.width > 0, mode.height > 0
        else { return naturalPixelSize(of: filter) }
        let scale = CGFloat(mode.pixelWidth) / CGFloat(mode.width)
        guard scale.isFinite, scale > 0 else { return naturalPixelSize(of: filter) }
        return CGSize(
            width : max(1, screenRect.width * scale),
            height: max(1, screenRect.height * scale)
        )
    }

    static func filter(
        for target             : SeatCaptureTarget,
        in content             : SCShareableContent,
        identityWitness        : WindowIdentityWitness?
    ) throws -> SCContentFilter {

        switch target {
        case .display(let displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID })
            else { throw CaptureFailure.displayNotShareable(displayID) }
            return SCContentFilter(display: display, excludingWindows: [])

        case .window(windowNumber: let windowNumber):
            guard let window = content.windows.first(where: { Int($0.windowID) == windowNumber })
            else { throw CaptureFailure.windowNotShareable(windowNumber: windowNumber) }
            return SCContentFilter(desktopIndependentWindow: window)

        case .attestedWindow(let identity):
            let firstIdentity = identityWitness?.identity(of: identity.windowNumber)
            guard firstIdentity == identity else {
                throw CaptureFailure.windowIdentityChanged(expected: identity, observed: firstIdentity)
            }
            guard let window = content.windows.first(where: { Int($0.windowID) == identity.windowNumber })
            else { throw CaptureFailure.windowNotShareable(windowNumber: identity.windowNumber) }
            guard window.owningApplication?.processID == identity.processID else {
                throw CaptureFailure.windowIdentityChanged(
                    expected: identity,
                    observed: identityWitness?.identity(of: identity.windowNumber)
                )
            }
            let secondIdentity = identityWitness?.identity(of: identity.windowNumber)
            guard secondIdentity == identity else {
                throw CaptureFailure.windowIdentityChanged(expected: identity, observed: secondIdentity)
            }
            return SCContentFilter(desktopIndependentWindow: window)

        case .attestedWindowRegion(let host, let children, let displayID, _, _):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureFailure.displayNotShareable(displayID)
            }
            let identities = [host] + children
            let windows = try identities.map { identity -> SCWindow in
                guard let window = content.windows.first(where: { Int($0.windowID) == identity.windowNumber }),
                      window.owningApplication?.processID == identity.processID
                else { throw CaptureFailure.windowNotShareable(windowNumber: identity.windowNumber) }
                guard identityWitness?.identity(of: identity.windowNumber) == identity else {
                    throw CaptureFailure.windowIdentityChanged(expected: identity,
                                                                observed: identityWitness?.identity(of: identity.windowNumber))
                }
                return window
            }
            return SCContentFilter(display: display, including: windows)
        }
    }

    /// Binds the requested identity before ScreenCaptureKit gathers its
    /// shareable-content snapshot. `filter` performs the matching checks after
    /// that call and compares SCK's owning PID, so a recycled Window ID cannot
    /// inherit the identity configured for an earlier window lifetime.
    private static func validateSourceBeforeContent(
        _ target              : SeatCaptureTarget,
        identityWitness       : WindowIdentityWitness?
    ) throws {
        let identities: [WindowIdentity]
        switch target {
        case .attestedWindow(let identity): identities = [identity]
        case .attestedWindowRegion(let host, let children, _, _, _): identities = [host] + children
        case .display, .window: return
        }
        for identity in identities {
            let observed = identityWitness?.identity(of: identity.windowNumber)
            guard observed == identity else {
                throw CaptureFailure.windowIdentityChanged(expected: identity, observed: observed)
            }
        }
    }

    private static func sourceFailure(
        for target             : SeatCaptureTarget,
        identityWitness        : WindowIdentityWitness?
    ) -> @Sendable () -> CaptureFailure? {
        switch target {
        case .display, .window(windowNumber: _):
            return { nil }
        case .attestedWindow(let identity):
            return {
                let observed = identityWitness?.identity(of: identity.windowNumber)
                guard observed != identity else { return nil }
                return .windowIdentityChanged(expected: identity, observed: observed)
            }
        case .attestedWindowRegion(let host, let children, _, _, _):
            let identities = [host] + children
            return {
                for identity in identities where identityWitness?.identity(of: identity.windowNumber) != identity {
                    return .windowIdentityChanged(expected: identity,
                                                  observed: identityWitness?.identity(of: identity.windowNumber))
                }
                return nil
            }
        }
    }

    private static func identityWitness(
        for target: SeatCaptureTarget
    ) -> WindowIdentityWitness? {
        switch target {
        case .attestedWindow, .attestedWindowRegion:
            return WindowIdentityWitness()
        case .display, .window:
            return nil
        }
    }
}
