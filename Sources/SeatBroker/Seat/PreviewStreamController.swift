import CoreGraphics
import Foundation
#if MECUM_PHASES
import PhaseSignposts
#endif
import SeatCapture
import SeatCore
import SeatSession

@MainActor
protocol PreviewCaptureStreaming: AnyObject {
    var target: SeatCaptureTarget { get }
    var isRunning: Bool { get }
    var hasUnconfirmedResource: Bool { get }

    func start(configuration: SeatCaptureConfiguration, timeout: Duration) async throws
    func updateConfiguration(_ configuration: SeatCaptureConfiguration, timeout: Duration) async throws
    func stop(timeout: Duration) async
    func attach(_ layer: MonitorLayer)
    func detach(_ layer: MonitorLayer)
    func firstFrame(displayedAfter notBefore: UInt64, within bound: Duration) async throws -> SeatFrame
    func invalidateWindowServerReadings()
}

extension SeatCaptureStream: PreviewCaptureStreaming {}

/// What the person's live picture is worth right now, which is not what the
/// adoption is worth. The seat holds the window in every one of these.
enum PreviewAvailability: Equatable {

    /// Nothing is being shown and nothing was asked for.
    case idle

    /// A stream is up.
    case live

    /// The picture stopped and a bounded recovery is still trying.
    case suspended(String)

    /// The bounded recovery ended with no stream. Nothing else is tried until
    /// the next adoption, pin or observation asks for one.
    case unavailable(String)
}

/// How many times, and for how long, a failed preview is tried again.
///
/// Both bounds are real: the count stops a stream that fails instantly from
/// spinning, and the monotone window stops one that fails slowly from retrying
/// for the life of the adoption. Whichever is reached first ends it.
struct PreviewRecoveryPlan: Equatable {
    var attemptLimit     : Int      = 3
    var pause            : Duration = .milliseconds(500)
    var windowNanoseconds: UInt64   = 10 * NSEC_PER_SEC

    /// Whether another attempt is allowed. `now` is a monotone reading and is
    /// a parameter so the bound can be driven without spending the time.
    func mayRetry(attempts: Int, startedAt: UInt64, now: UInt64) -> Bool {
        attempts < attemptLimit && now &- startedAt < windowNanoseconds
    }
}

/// Owns the one capture stream shown by the Lab preview.
///
/// An observation can move the seat from the adopted window to another window
/// of the same application. The preview follows that exact recipient. Layers
/// belong to this controller rather than to one stream so replacing a stream
/// cannot detach the view permanently.
@MainActor
final class PreviewStreamController {
    typealias StreamFactory = @MainActor (SeatCaptureTarget) -> any PreviewCaptureStreaming

    private let makeStream: StreamFactory
    private let recovery: PreviewRecoveryPlan
    private var layers: [MonitorLayer] = []
    private var desiredTarget: SeatCaptureTarget?
    private var transition: Task<Void, Never>?
    private var transitionGeneration: UInt64 = 0
    private var isStoppingOrStopped = false

    /// The whole display while the person has pinned the preview to it, and
    /// nil while the preview follows the window.
    ///
    /// The pin exists because a window on the background display captures its
    /// first frame and then breaks, and watching the display instead of the
    /// one window is what says whether the capture or the window is at fault.
    /// It outranks observation: `follow` runs on every one of them and would
    /// otherwise drag the picture back to the window within milliseconds.
    private var pinnedTarget: SeatCaptureTarget?

    /// The window the preview shows when nothing is pinned, and the size it
    /// shows it at: the adopted window until an observation names another
    /// recipient, then that one. It is what unpinning goes back to.
    private var windowTarget: SeatCaptureTarget?
    private var windowPixelSize: CGSize?

    /// True while the layers have been taken off the current stream and nothing
    /// has put them back. A transition that finds the stream it wanted already
    /// running re-attaches only then: the Lab follows the same window on every
    /// observation, and re-attaching each time is work that changes nothing.
    private var layersAreDetached = false
    private(set) var stream: (any PreviewCaptureStreaming)?

    /// The output size the running stream was started with.
    ///
    /// A stream carries its configuration and never publishes it, so the one
    /// way to know whether the size it is producing is still the size wanted is
    /// to remember what it was asked for. Without it the size was applied at
    /// `start` and never again, and a preview that began at the wrong one
    /// stayed wrong for the life of the adoption however many observations
    /// corrected the figure.
    private var streamPixelSize: CGSize?

    /// The reading before the one in hand, which is the other half of the
    /// settle budget `CaptureShapeStabilisation` asks for. It is kept per
    /// window target: a reading of one window says nothing about the next.
    private var previousWindowPixelSize: CGSize?

    private(set) var windowFrame: CGRect?
    private(set) var lastFailure: String?

    /// Whether the person has a live picture, and why not when they do not.
    /// It is nothing to do with the adoption: the seat holds the window in
    /// every one of these states and input still waits for a fresh observation.
    #if MECUM_PHASES
    private(set) var availability: PreviewAvailability = .idle {
        didSet { PhaseInterval.event("preview.availability", String(describing: availability)) }
    }
    #else
    private(set) var availability: PreviewAvailability = .idle
    #endif

    /// The bounded recovery: the task running it, how many attempts it has
    /// spent, and the monotone instant its window started at.
    private var recoveryTask: Task<Void, Never>?
    private var recoveryAttempts = 0
    private var recoveryStartedAt: UInt64?

    /// The rate the stream runs at while it is used or shown.
    static let activeFramesPerSecond = 30

    /// The rest (ADR 0036): whether the rate wanted is the plan's, the rate the running stream
    /// was last started or updated with, the uptime of the last use, and the task that waits for
    /// the delay. A frame is handed over only once the stream is confirmed at the active rate.
    private let rest: PreviewRestPlan
    private(set) var isResting = false
    private var streamFramesPerSecond: Int?
    private var lastActivityAt: UInt64 = 0
    private var restTimer: Task<Void, Never>?

    /// The size and the previous reading the last transition was asked for, with `desiredTarget`:
    /// a rate change re-runs that same transition, so it can never undo a newer wish.
    private var desiredPixelSize: CGSize?
    private var desiredPreviousReading: CGSize?

    init(
        recovery  : PreviewRecoveryPlan = PreviewRecoveryPlan(),
        rest      : PreviewRestPlan = PreviewRestPlan(),
        makeStream: @escaping StreamFactory = { SeatCaptureStream(target: $0) }
    ) {
        self.recovery   = recovery
        self.rest       = rest
        self.makeStream = makeStream
    }

    var target: SeatCaptureTarget? { stream?.target }

    var isPinnedToDisplay: Bool { pinnedTarget != nil }

    func start(identity: WindowIdentity, frame: CGRect, pixelSize: CGSize) async throws {
        // A stop ends one application's preview, not the controller: the seat
        // outlives the application, and the next one starts on the same layers.
        isStoppingOrStopped = false
        windowFrame = frame
        let target = SeatCaptureTarget.attestedWindow(identity)
        windowTarget = target
        windowPixelSize = pixelSize
        previousWindowPixelSize = nil
        // An adoption under a pin records the window it would show and leaves
        // the display stream running. Starting one here beside it is the two
        // streams the transition exists to make impossible.
        guard pinnedTarget == nil else { return }
        desiredTarget          = target
        desiredPixelSize       = pixelSize
        desiredPreviousReading = nil
        // An adoption is a use: the new stream starts at the full rate.
        isResting      = false
        lastActivityAt = DispatchTime.now().uptimeNanoseconds
        let stream = makeStream(target)
        self.stream = stream
        streamPixelSize = pixelSize
        let configuration = configuration(pixelSize: pixelSize)
        streamFramesPerSecond = configuration.framesPerSecond
        attachLayersToCurrentStream()
        do {
            try await stream.start(configuration: configuration, timeout: .seconds(5))
            lastFailure  = nil
            availability = .live
            armRestTimer()
        } catch {
            lastFailure = String(describing: error)
            // The window is the seat's either way. The picture is what failed,
            // so it is suspended and tried again inside its own bounds, and the
            // caller is told rather than made to undo the adoption.
            suspend(String(describing: error))
            await stream.stop(timeout: .seconds(5))
            if !stream.hasUnconfirmedResource {
                self.stream = nil
                streamPixelSize = nil
            }
            scheduleRecovery(target: target, pixelSize: pixelSize)
            throw error
        }
    }

    /// Shows the delivered sample immediately, then changes the live source.
    /// Stream replacement is deliberately best effort: preview failure cannot
    /// invalidate an observation that Mecum has already qualified.
    func follow(_ delivery: SeatObservationDelivery) {
        guard !isStoppingOrStopped else { return }
        #if MECUM_PHASES
        PhaseInterval.event("preview.follow", "pinned=\(pinnedTarget != nil)")
        #endif
        let target = delivery.captureTarget
            ?? .attestedWindow(delivery.reference.recipient)
        // Under a pin the window's own frame is the one thing taken from the
        // delivery. Presenting it would put a frame of the window into layers
        // showing the display, which is the picture the person asked to leave.
        if pinnedTarget == nil {
            if stream?.target != target || stream?.isRunning != true {
                detachLayersFromCurrentStream()
            }
            for layer in layers { layer.present(delivery.frame) }
        }
        follow(
            target: target,
            frame: delivery.frame.geometry.screenRect,
            // The part of the buffer the capture filled, not the buffer: the
            // remainder is padding, and a stream sized to it keeps the black.
            pixelSize: delivery.frame.geometry.contentPixelSize ?? delivery.frame.pixelSize
        )
    }

    /// The identity-only seam keeps replacement policy testable without
    /// manufacturing a framework-qualified `SeatFrame` in a consumer package.
    func follow(identity: WindowIdentity, frame: CGRect, pixelSize: CGSize) {
        follow(target: .attestedWindow(identity), frame: frame, pixelSize: pixelSize)
    }

    /// Hosted-sheet pixels occupy an attested family crop, which is distinct
    /// from the host's window-local coordinate frame. Keep the preview stream
    /// on that same target so it cannot reintroduce host-sized letterboxing.
    func follow(target: SeatCaptureTarget, frame: CGRect, pixelSize: CGSize) {
        guard !isStoppingOrStopped else { return }
        noteActivity(.observation)
        // An observation that saw the window elsewhere or at another size makes the stream read
        // the window server again instead of reusing its cached answers.
        if frame != windowFrame || pixelSize != windowPixelSize {
            stream?.invalidateWindowServerReadings()
        }
        windowFrame = frame
        // A reading only settles against the reading before it of the same
        // window. A new recipient starts the budget again.
        previousWindowPixelSize = windowTarget == target ? windowPixelSize : nil
        windowTarget = target
        windowPixelSize = pixelSize
        guard pinnedTarget == nil else { return }
        transition(to: windowTarget, pixelSize: pixelSize,
                   previousReading: previousWindowPixelSize)
    }

    /// Pins the live picture to `target` — the whole background display — or
    /// gives it back to the window when `target` is nil.
    ///
    /// Both directions go through the one transition a window change uses, so
    /// the generation guard, the layer re-attachment and the refusal to leave
    /// an unconfirmed resource behind cover the pin as they cover everything
    /// else. Unpinning with nothing ever adopted leaves no stream at all,
    /// which is the honest answer to a seat holding nothing.
    func pin(to target: SeatCaptureTarget?, pixelSize: CGSize) {
        pinnedTarget = target
        // A pinned size is the display's bounds and not a measurement of what a
        // capture filled, so it needs no settle budget: it is handed in as its
        // own previous reading, which is what says "already settled".
        guard let target else {
            guard !isStoppingOrStopped else { return }
            let size = windowPixelSize ?? pixelSize
            transition(to: windowTarget, pixelSize: size, previousReading: size)
            return
        }
        // A stop ends one application's preview, not the controller, and the
        // display outlives every window put on it: watching it with the seat
        // empty is the case the pin exists for.
        isStoppingOrStopped = false
        transition(to: target, pixelSize: pixelSize, previousReading: pixelSize)
    }

    private func transition(to target: SeatCaptureTarget?, pixelSize: CGSize,
                            previousReading: CGSize? = nil) {
        desiredTarget          = target
        desiredPixelSize       = pixelSize
        desiredPreviousReading = previousReading
        transitionGeneration &+= 1
        let generation = transitionGeneration
        let preceding = transition
        transition = Task { @MainActor [weak self] in
            await preceding?.value
            guard let self, !self.isStoppingOrStopped,
                  self.transitionGeneration == generation
            else { return }
            await self.replaceStreamIfNeeded(
                target: target,
                pixelSize: pixelSize,
                previousReading: previousReading,
                generation: generation
            )
            if self.transitionGeneration == generation {
                self.transition = nil
            }
        }
    }

    /// A layer is the person watching: while one is attached the stream never rests, and
    /// attaching one wakes it.
    func attach(_ layer: MonitorLayer) {
        guard !layers.contains(where: { $0 === layer }) else { return }
        layers.append(layer)
        if stream?.target == desiredTarget { stream?.attach(layer) }
        noteActivity(.layer)
    }

    /// Detaching the last layer starts the rest delay from now.
    func detach(_ layer: MonitorLayer) {
        layers.removeAll { $0 === layer }
        stream?.detach(layer)
        noteActivity(.layer)
    }

    /// Records a use of the stream: it restarts the rest delay and, if the stream rests, asks
    /// for the active rate at once. `SeatDriver` calls it for a Turn and a Command; frame requests,
    /// observations and layers call it here.
    func noteActivity(_ activity: PreviewActivity) {
        lastActivityAt = DispatchTime.now().uptimeNanoseconds
        armRestTimer()
        guard isResting else { return }
        isResting = false
        #if MECUM_PHASES
        PhaseInterval.event("preview.rest", "leave.\(activity.rawValue)")
        #endif
        applyRate()
    }

    /// Test join point: waits for the rest delay to run out, then for the rate change it queued.
    func waitForRestTimer() async {
        await restTimer?.value
        await transition?.value
    }

    /// Ends the preview of one application's window.
    ///
    /// A pin to the whole display outlives it, and that is the whole point of
    /// the pin. The display is not the application's: it is what applications
    /// are put on, and the seat gives one back and takes the next one on the
    /// same display. A release runs at the start of every handover, a moment
    /// before the next window is moved in, so taking the picture away here
    /// would blank the monitor exactly when it is worth watching.
    ///
    /// A host that is taking the display away with it calls `tearDown`.
    func stop() async {
        windowTarget = nil
        windowPixelSize = nil
        previousWindowPixelSize = nil
        guard pinnedTarget == nil else { return }
        await tearDown()
    }

    /// Ends the preview outright, pin included. It is the teardown for a driver
    /// that is about to stop the host, which is what makes the display the pin
    /// is watching cease to exist.
    func tearDown() async {
        isStoppingOrStopped = true
        desiredTarget = nil
        pinnedTarget = nil
        windowTarget = nil
        windowPixelSize = nil
        previousWindowPixelSize = nil
        availability = .idle
        endRecovery()
        restTimer?.cancel()
        restTimer = nil
        isResting = false
        transitionGeneration &+= 1
        detachLayersFromCurrentStream()
        let pending = transition
        await pending?.value
        transition = nil
        guard let stream else { return }
        await stream.stop(timeout: .seconds(5))
        guard !stream.hasUnconfirmedResource else { return }
        self.stream = nil
        streamPixelSize = nil
    }

    /// Test join point for an asynchronously scheduled replacement.
    func waitForPendingTransition() async {
        await transition?.value
    }

    private func replaceStreamIfNeeded(
        target: SeatCaptureTarget?,
        pixelSize: CGSize,
        previousReading: CGSize?,
        generation: UInt64
    ) async {
        // The same window at a new size used to be replaced exactly as another
        // window would be, on an exact comparison of the two figures. That is
        // two faults in one line: a reading a pixel off the last one cost a
        // stop and a start, and a size that really moved cost them too, when
        // ScreenCaptureKit reshapes a running stream without tearing the
        // pipeline down. So the shape question is put to the kit's own rule,
        // the one `Monitor.followTargetShape` runs, and the answer is applied
        // to the running stream.
        if let target, let stream, stream.target == target, stream.isRunning,
           let running = streamPixelSize {
            let settled = CaptureShapeStabilisation.settledShape(
                running        : running,
                reading        : pixelSize,
                previousReading: previousReading
            )
            // The rate wanted is read now, so a rest or a wake queued behind this is never undone.
            guard settled != nil || streamFramesPerSecond != framesPerSecond else {
                if layersAreDetached { attachLayersToCurrentStream() }
                return
            }
            if await reshape(stream, to: settled ?? running) {
                if layersAreDetached { attachLayersToCurrentStream() }
                return
            }
            // The framework refused the update. A restart is what is left, and
            // it falls through to the replacement below.
        }

        if let stream {
            #if MECUM_PHASES
            PhaseInterval.event("preview.replace", "stop")
            #endif
            detachLayersFromCurrentStream()
            await stream.stop(timeout: .seconds(5))
            guard !stream.hasUnconfirmedResource else {
                lastFailure = "The previous preview stream did not release its capture resource."
                // Unavailable and not suspended: a resource the framework kept
                // is not something another attempt talks it out of, so nothing
                // is retried and the sentence says so.
                for layer in layers { layer.markStale() }
                availability = .unavailable(lastFailure ?? "")
                return
            }
            self.stream = nil
            streamPixelSize = nil
        }

        guard !isStoppingOrStopped, transitionGeneration == generation,
              desiredTarget == target
        else { return }

        // Unpinning with no window to go back to wants no stream, not a
        // display the person has just asked to stop watching.
        guard let target else {
            availability = .idle
            return
        }

        #if MECUM_PHASES
        PhaseInterval.event("preview.replace", "start")
        #endif
        let replacement = makeStream(target)
        stream = replacement
        streamPixelSize = pixelSize
        let configuration = configuration(pixelSize: pixelSize)
        streamFramesPerSecond = configuration.framesPerSecond
        attachLayersToCurrentStream()
        do {
            try await replacement.start(
                configuration: configuration,
                timeout: .seconds(5)
            )
            guard !isStoppingOrStopped, transitionGeneration == generation,
                  desiredTarget == target
            else { return }
            lastFailure  = nil
            availability = .live
            endRecovery()
            armRestTimer()
        } catch {
            lastFailure = String(describing: error)
            await replacement.stop(timeout: .seconds(5))
            if !replacement.hasUnconfirmedResource {
                stream = nil
                streamPixelSize = nil
            }
            suspend(String(describing: error))
            scheduleRecovery(target: target, pixelSize: pixelSize)
        }
    }

    /// Reshapes the running stream in place, and answers whether the framework
    /// took it. `SCStream.updateConfiguration` replaces the surface pool without
    /// tearing the pipeline down, so the price is the frames in flight rather
    /// than the black gap a stop and a start cost.
    ///
    /// What is on the layers was captured at the old shape, so it is marked
    /// stale: it stays on screen, saying what it is, until a frame of the new
    /// shape replaces it. Nothing here authorises a coordinate — the agent's
    /// own observation does that, and it is taken fresh every time.
    ///
    /// The same update carries the rate. One that changes the rate only keeps the picture live,
    /// and in the phase build its `preview.update` interval is named `rate.<fps>`.
    private func reshape(_ stream: any PreviewCaptureStreaming, to size: CGSize) async -> Bool {
        let configuration = configuration(pixelSize: size)
        let isReshape = size != streamPixelSize
        #if MECUM_PHASES
        let phase = PhaseInterval.begin("preview.update")
        #endif
        do {
            try await stream.updateConfiguration(configuration, timeout: .seconds(2))
            streamPixelSize       = size
            streamFramesPerSecond = configuration.framesPerSecond
            if isReshape { for layer in layers { layer.markStale() } }
            lastFailure = nil
            #if MECUM_PHASES
            phase.end(isReshape ? "reshape" : "rate.\(configuration.framesPerSecond)")
            if isReshape { PhaseInterval.event("preview.reshape", "ok") }
            #endif
            return true
        } catch {
            lastFailure = String(describing: error)
            #if MECUM_PHASES
            PhaseInterval.event("preview.reshape", isReshape ? "refused" : "refused.rate")
            #endif
            return false
        }
    }

    private var framesPerSecond: Int {
        isResting ? rest.framesPerSecond : Self.activeFramesPerSecond
    }

    /// Starts the wait for the rest delay unless one is running. It ends by resting the stream
    /// when nothing used it for the whole delay; a use during the wait only moves its end.
    private func armRestTimer() {
        guard restTimer == nil, !isStoppingOrStopped else { return }
        let delay = UInt64(rest.delay.components.seconds) * NSEC_PER_SEC
            + UInt64(rest.delay.components.attoseconds / 1_000_000_000)
        restTimer = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                let unused = DispatchTime.now().uptimeNanoseconds &- self.lastActivityAt
                guard unused < delay else {
                    self.restTimer = nil
                    self.enterRestIfUnused()
                    return
                }
                try? await Task.sleep(nanoseconds: delay - unused)
            }
        }
    }

    /// Rests the stream when nobody shows it and it runs live on the window or display wanted.
    /// Anything else leaves it alone, and the next use arms the delay again.
    private func enterRestIfUnused() {
        guard !isResting, layers.isEmpty, !isStoppingOrStopped, availability == .live,
              let stream, stream.isRunning, stream.target == desiredTarget
        else { return }
        isResting = true
        #if MECUM_PHASES
        PhaseInterval.event("preview.rest", "enter")
        #endif
        applyRate()
    }

    /// Asks the running stream for the rate wanted by re-running the last transition. A stream
    /// that is not running is left alone: it is started with the rate wanted then.
    private func applyRate() {
        guard let stream, stream.isRunning, stream.target == desiredTarget,
              let pixelSize = desiredPixelSize
        else { return }
        transition(to: desiredTarget, pixelSize: pixelSize, previousReading: desiredPreviousReading)
    }

    /// Takes the picture away without touching the adoption, and says why.
    private func suspend(_ why: String) {
        for layer in layers { layer.markStale() }
        availability = .suspended(why)
    }

    /// Ends the bounded recovery, whether it succeeded or ran out.
    private func endRecovery() {
        recoveryTask?.cancel()
        recoveryTask      = nil
        recoveryAttempts  = 0
        recoveryStartedAt = nil
    }

    /// Tries the failed preview again, at most `attemptLimit` times and only
    /// inside the plan's monotone window. One recovery runs at a time, and it
    /// stops the moment a stream is up, the target moves on, or the controller
    /// is stopped.
    private func scheduleRecovery(target: SeatCaptureTarget, pixelSize: CGSize) {
        guard recoveryTask == nil, !isStoppingOrStopped else { return }
        let startedAt = recoveryStartedAt ?? DispatchTime.now().uptimeNanoseconds
        recoveryStartedAt = startedAt
        recoveryTask = Task { @MainActor [weak self] in
            while let self, self.stream == nil, !self.isStoppingOrStopped,
                  !Task.isCancelled, self.desiredTarget == target,
                  self.recovery.mayRetry(
                      attempts : self.recoveryAttempts,
                      startedAt: startedAt,
                      now      : DispatchTime.now().uptimeNanoseconds
                  ) {
                try? await Task.sleep(for: self.recovery.pause)
                guard !self.isStoppingOrStopped, self.desiredTarget == target else { break }
                self.recoveryAttempts += 1
                #if MECUM_PHASES
                PhaseInterval.event("preview.recovery", "attempt=\(self.recoveryAttempts)")
                #endif
                // Through the transition chain and not straight into the
                // replacement: an observation arriving mid-recovery must not
                // end up building a second stream beside this one.
                self.transition(to: target, pixelSize: pixelSize, previousReading: pixelSize)
                await self.waitForPendingTransition()
            }
            // Not cleared when this run was cancelled: `endRecovery` already
            // took the slot, and a later failure may own it by now.
            guard let self, !Task.isCancelled else { return }
            self.recoveryTask = nil
            // Bounded means bounded: nothing else is tried until the next
            // adoption, pin or observation asks for a stream again.
            if self.stream == nil, case .suspended(let why) = self.availability {
                self.availability = .unavailable(why)
            }
        }
    }

    private func attachLayersToCurrentStream() {
        guard let stream else { return }
        for layer in layers { stream.attach(layer) }
        layersAreDetached = false
    }

    private func detachLayersFromCurrentStream() {
        guard let stream else { return }
        for layer in layers { stream.detach(layer) }
        layersAreDetached = true
    }

    private func configuration(pixelSize: CGSize) -> SeatCaptureConfiguration {
        SeatCaptureConfiguration(
            pixelSize: CGSize(width: max(1, pixelSize.width), height: max(1, pixelSize.height)),
            framesPerSecond: framesPerSecond
        )
    }
}

/// The preview is the running stream of the adopted window that observation reads first.
///
/// It offers a frame only while it is live on exactly that window: pinned to the display, in
/// recovery, idle, unavailable or on another target, it declines at once and the seat takes a
/// Still of its own. What it hands over is checked again by the seat; see `LiveFrameHandover`.
///
/// Every request is a use. One that finds the stream resting, or not yet confirmed back at the
/// active rate, wakes it and declines with `resting` at once: the worst case of the first
/// observation after a rest is the Still, never a wait on the update and never an older frame.
extension PreviewStreamController: LiveWindowFrameSourcing {

    func liveFrame(
        of identity             : WindowIdentity,
        displayedAfter notBefore: UInt64,
        within bound            : Duration
    ) async -> Result<SeatFrame, LiveFrameFallback> {

        noteActivity(.frameRequest)
        guard pinnedTarget == nil else { return .failure(.pinnedToDisplay) }
        switch availability {
            case .live                : break
            case .suspended           : return .failure(.recovering)
            case .idle, .unavailable  : return .failure(.notLive)
        }
        guard let stream, stream.isRunning else { return .failure(.notLive) }
        guard stream.target == .attestedWindow(identity) else { return .failure(.otherWindow) }
        guard streamFramesPerSecond == Self.activeFramesPerSecond else { return .failure(.resting) }
        do {
            return .success(try await stream.firstFrame(displayedAfter: notBefore, within: bound))
        } catch {
            return .failure(.noFrameInBound)
        }
    }
}
