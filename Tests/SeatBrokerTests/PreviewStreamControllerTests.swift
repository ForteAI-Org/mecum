import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import IOSurface
@testable import SeatCapture
import SeatCore
import SeatDriving
import SeatSession
import Testing
@testable import SeatBroker

@MainActor
private final class FakePreviewStream: PreviewCaptureStreaming {
    enum Failure: Error { case start }

    let target: SeatCaptureTarget
    let name: String
    let events: EventLog
    var isRunning = false
    var hasUnconfirmedResource = false
    var startFails = false
    var startPauses = false
    var stopKeepsResource = false
    var updateFails = false
    private(set) var configuredPixelSize: CGSize = .zero
    private(set) var configuredFramesPerSecond = 0
    private var startContinuation: CheckedContinuation<Void, Never>?

    init(target: SeatCaptureTarget, name: String, events: EventLog) {
        self.target = target
        self.name = name
        self.events = events
        events.values.append("make \(name)")
    }

    func start(configuration: SeatCaptureConfiguration, timeout: Duration) async throws {
        events.values.append("start \(name)")
        hasUnconfirmedResource = true
        configuredPixelSize = configuration.pixelSize
        configuredFramesPerSecond = configuration.framesPerSecond
        if startPauses {
            await withCheckedContinuation { startContinuation = $0 }
        }
        if startFails { throw Failure.start }
        isRunning = true
    }

    func updateConfiguration(_ configuration: SeatCaptureConfiguration, timeout: Duration) async throws {
        events.values.append("update \(name)")
        if updateFails { throw Failure.start }
        configuredPixelSize = configuration.pixelSize
        configuredFramesPerSecond = configuration.framesPerSecond
    }

    func stop(timeout: Duration) async {
        events.values.append("stop \(name)")
        isRunning = false
        if !stopKeepsResource { hasUnconfirmedResource = false }
    }

    func attach(_ layer: MonitorLayer) {
        events.values.append("attach \(name)")
    }

    func detach(_ layer: MonitorLayer) {
        events.values.append("detach \(name)")
    }

    func resumeStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    /// What `firstFrame` answers; nil answers a timeout.
    var offeredFrame: SeatFrame?
    private(set) var frameWaits: [(notBefore: UInt64, bound: Duration)] = []
    private(set) var readingInvalidations = 0

    /// True makes the next wait find the frames ended, as a stream that stopped does.
    var endsFrames = false

    /// When set, waits are served by the running stream's own waiting, fed by `offer`.
    var waiters: FrameWaiters?

    func firstFrame(displayedAfter notBefore: UInt64, within bound: Duration) async throws -> SeatFrame {
        frameWaits.append((notBefore, bound))
        if endsFrames {
            isRunning = false
            throw CaptureFailure.frameUnavailable
        }
        if let waiters {
            return try await waiters.first(displayedAfter: notBefore, deadline: CaptureDeadline(timeout: bound))
        }
        guard let offeredFrame else { throw CaptureFailure.timedOut(.still) }
        return offeredFrame
    }

    func invalidateWindowServerReadings() {
        readingInvalidations += 1
    }
}

@MainActor
private final class EventLog {
    var values: [String] = []
}

private func identity(_ windowNumber: Int) -> WindowIdentity {
    WindowIdentity(
        process: ProcessIdentity(
            processID: 42,
            serialNumberHigh: 1,
            serialNumberLow: 2
        ),
        windowNumber: windowNumber,
        ownerConnectionID: 3
    )
}

@Test @MainActor
func previewReplacesItsStreamAndCarriesTheAttachedLayer() async throws {
    let events = EventLog()
    var streams: [FakePreviewStream] = []
    let controller = PreviewStreamController { target in
        let stream = FakePreviewStream(target: target, name: "s\(streams.count + 1)", events: events)
        streams.append(stream)
        return stream
    }
    let layer = MonitorLayer(contentsScale: 2)
    controller.attach(layer)

    try await controller.start(
        identity: identity(10),
        frame: CGRect(x: 1, y: 2, width: 300, height: 200),
        pixelSize: CGSize(width: 600, height: 400)
    )
    events.values.removeAll()

    let nextFrame = CGRect(x: 10, y: 20, width: 180, height: 120)
    controller.follow(
        identity: identity(11),
        frame: nextFrame,
        pixelSize: CGSize(width: 360, height: 240)
    )
    await controller.waitForPendingTransition()

    #expect(events.values == ["detach s1", "stop s1", "make s2", "attach s2", "start s2"])
    #expect(controller.target == .attestedWindow(identity(11)))
    #expect(controller.windowFrame == nextFrame)

    events.values.removeAll()
    controller.follow(
        identity: identity(11),
        frame: nextFrame,
        pixelSize: CGSize(width: 360, height: 240)
    )
    await controller.waitForPendingTransition()
    #expect(events.values.isEmpty)

    controller.detach(layer)
    #expect(events.values == ["detach s2"])
}

@Test @MainActor
func nestedHostedSheetPreviewKeepsTheWholeAttestedCaptureFamily() async throws {
    let events = EventLog()
    var streams: [FakePreviewStream] = []
    let controller = PreviewStreamController { target in
        let stream = FakePreviewStream(target: target, name: "s\(streams.count + 1)", events: events)
        streams.append(stream)
        return stream
    }
    let host   = identity(110)
    let parent = identity(111)
    let leaf   = identity(112)
    let crop   = CGRect(x: 1_900, y: 200, width: 891, height: 552)
    let hostFrame = CGRect(x: 1_985, y: 200, width: 500, height: 552)
    let target = SeatCaptureTarget.attestedWindowRegion(
        host: host,
        children: [parent, leaf],
        displayID: 17,
        screenRect: crop,
        sourceWindowFrame: hostFrame
    )

    // The delivery target is already the full ancestry capture produced by the
    // seat. Preview must keep it verbatim instead of rebuilding a leaf-only
    // window target, which would crop the parent panel out of the stream.
    controller.follow(
        target: target,
        frame: crop,
        pixelSize: crop.size
    )
    await controller.waitForPendingTransition()

    #expect(controller.target == target)
    #expect(streams.map(\.target) == [target])
    #expect(controller.windowFrame == crop)
}

@Test @MainActor
func previewDoesNotCreateASecondStreamWhenStopIsUnconfirmed() async throws {
    let events = EventLog()
    var streams: [FakePreviewStream] = []
    let controller = PreviewStreamController { target in
        let stream = FakePreviewStream(target: target, name: "s\(streams.count + 1)", events: events)
        streams.append(stream)
        return stream
    }
    try await controller.start(
        identity: identity(20),
        frame: CGRect(x: 0, y: 0, width: 200, height: 100),
        pixelSize: CGSize(width: 400, height: 200)
    )
    streams[0].stopKeepsResource = true
    events.values.removeAll()

    controller.follow(
        identity: identity(21),
        frame: CGRect(x: 4, y: 5, width: 100, height: 80),
        pixelSize: CGSize(width: 200, height: 160)
    )
    await controller.waitForPendingTransition()

    #expect(streams.count == 1)
    #expect(controller.target == .attestedWindow(identity(20)))
    #expect(controller.stream?.hasUnconfirmedResource == true)
    #expect(controller.lastFailure != nil)
    #expect(events.values == ["stop s1"])
}

@Test @MainActor
func previewStartFailureDoesNotEscapeAndReleasesTheFailedOwner() async throws {
    let events = EventLog()
    var streams: [FakePreviewStream] = []
    let controller = PreviewStreamController(
        recovery: PreviewRecoveryPlan(attemptLimit: 0)
    ) { target in
        let stream = FakePreviewStream(target: target, name: "s\(streams.count + 1)", events: events)
        if !streams.isEmpty { stream.startFails = true }
        streams.append(stream)
        return stream
    }
    try await controller.start(
        identity: identity(30),
        frame: CGRect(x: 0, y: 0, width: 200, height: 100),
        pixelSize: CGSize(width: 400, height: 200)
    )
    events.values.removeAll()

    controller.follow(
        identity: identity(31),
        frame: CGRect(x: 2, y: 3, width: 120, height: 90),
        pixelSize: CGSize(width: 240, height: 180)
    )
    await controller.waitForPendingTransition()

    #expect(events.values == ["stop s1", "make s2", "start s2", "stop s2"])
    #expect(controller.stream == nil)
    #expect(controller.lastFailure != nil)
}

@Test @MainActor
func consecutiveRetargetsInstallOnlyTheLatestRecipient() async throws {
    let events = EventLog()
    var streams: [FakePreviewStream] = []
    let controller = PreviewStreamController { target in
        let stream = FakePreviewStream(target: target, name: "s\(streams.count + 1)", events: events)
        streams.append(stream)
        return stream
    }
    try await controller.start(
        identity: identity(50),
        frame: CGRect(x: 0, y: 0, width: 200, height: 100),
        pixelSize: CGSize(width: 400, height: 200)
    )
    events.values.removeAll()

    controller.follow(identity: identity(51), frame: CGRect(x: 1, y: 1, width: 100, height: 80),
                      pixelSize: CGSize(width: 200, height: 160))
    controller.follow(identity: identity(52), frame: CGRect(x: 2, y: 2, width: 90, height: 70),
                      pixelSize: CGSize(width: 180, height: 140))
    await controller.waitForPendingTransition()

    #expect(streams.count == 2)
    #expect(controller.target == .attestedWindow(identity(52)))
    #expect(events.values == ["stop s1", "make s2", "start s2"])
}

@Test @MainActor
func stopDuringRetargetCannotResurrectTheReplacement() async throws {
    let events = EventLog()
    var streams: [FakePreviewStream] = []
    let controller = PreviewStreamController { target in
        let stream = FakePreviewStream(target: target, name: "s\(streams.count + 1)", events: events)
        if !streams.isEmpty { stream.startPauses = true }
        streams.append(stream)
        return stream
    }
    try await controller.start(
        identity: identity(60),
        frame: CGRect(x: 0, y: 0, width: 200, height: 100),
        pixelSize: CGSize(width: 400, height: 200)
    )
    events.values.removeAll()
    controller.follow(identity: identity(61), frame: CGRect(x: 3, y: 3, width: 100, height: 80),
                      pixelSize: CGSize(width: 200, height: 160))

    while streams.count < 2 { await Task.yield() }
    let stop = Task { @MainActor in await controller.stop() }
    await Task.yield()
    streams[1].resumeStart()
    await stop.value

    #expect(controller.stream == nil)
    #expect(events.values == ["stop s1", "make s2", "start s2", "stop s2"])
}

/// The size the preview was started with used to be the size it kept for the
/// life of the adoption. A window whose first figure was wrong showed at its
/// own size in the corner of a frame four times its area, with black around
/// it, and no later observation could put it right. The figure was wrong for
/// every window: the background display publishes one pixel per point and the
/// driver asked for two.
///
/// A settled change is now reshaped in place instead of restarted: the kit's
/// own rule says when the shape has settled, and ScreenCaptureKit replaces the
/// surface pool without the black gap a stop and a start cost.
@Test @MainActor
func previewFollowsASizeChangeOnTheSameWindow() async throws {
    let events = EventLog()
    var streams: [FakePreviewStream] = []
    let controller = PreviewStreamController { target in
        let stream = FakePreviewStream(target: target, name: "s\(streams.count + 1)", events: events)
        streams.append(stream)
        return stream
    }
    let window = identity(30)
    let frame  = CGRect(x: 0, y: 0, width: 300, height: 200)
    let layer  = MonitorLayer(contentsScale: 2)
    controller.attach(layer)

    try await controller.start(
        identity: window,
        frame: frame,
        pixelSize: CGSize(width: 600, height: 400)
    )
    events.values.removeAll()

    // One reading of a new shape is not a settled shape, so nothing moves yet.
    controller.follow(identity: window, frame: frame,
                      pixelSize: CGSize(width: 300, height: 200))
    await controller.waitForPendingTransition()
    #expect(events.values.isEmpty)

    controller.follow(identity: window, frame: frame,
                      pixelSize: CGSize(width: 300, height: 200))
    await controller.waitForPendingTransition()

    #expect(events.values == ["update s1"])
    #expect(streams.count == 1)
    #expect(streams[0].configuredPixelSize == CGSize(width: 300, height: 200))
    #expect(controller.target == .attestedWindow(window))

    // And the new size is the one it keeps: the same figure again is the same
    // stream, so a preview does not restart once per observation.
    events.values.removeAll()
    controller.follow(
        identity: window,
        frame: frame,
        pixelSize: CGSize(width: 300, height: 200)
    )
    await controller.waitForPendingTransition()
    #expect(events.values.isEmpty)
}

/// A window on the Virtual Display captures its first frame and then breaks:
/// content in part of the frame, black in the rest, in more than one
/// application. Watching the whole display instead of the one window is what
/// says whether the capture is broken or the window is drawn that way, and
/// the pin is what makes that possible without disturbing the agent.
@Test @MainActor
func pinningToTheDisplayReplacesTheWindowStreamAndCarriesTheLayer() async throws {
    let events = EventLog()
    var streams: [FakePreviewStream] = []
    let controller = PreviewStreamController { target in
        let stream = FakePreviewStream(target: target, name: "s\(streams.count + 1)", events: events)
        streams.append(stream)
        return stream
    }
    let layer = MonitorLayer(contentsScale: 2)
    controller.attach(layer)

    try await controller.start(
        identity: identity(70),
        frame: CGRect(x: 0, y: 0, width: 300, height: 200),
        pixelSize: CGSize(width: 300, height: 200)
    )
    events.values.removeAll()

    controller.pin(to: .display(7), pixelSize: CGSize(width: 1_920, height: 1_080))
    await controller.waitForPendingTransition()

    #expect(events.values == ["detach s1", "stop s1", "make s2", "attach s2", "start s2"])
    #expect(controller.target == .display(7))
    #expect(controller.isPinnedToDisplay)
}

/// The assertion the feature stands on. `follow` runs on every observation
/// and would drag the picture straight back to the window, which is the one
/// thing a person watching the display cannot have happen.
@Test @MainActor
func anObservationWhilePinnedDoesNotReplaceTheDisplayStream() async throws {
    let events = EventLog()
    var streams: [FakePreviewStream] = []
    let controller = PreviewStreamController { target in
        let stream = FakePreviewStream(target: target, name: "s\(streams.count + 1)", events: events)
        streams.append(stream)
        return stream
    }
    try await controller.start(
        identity: identity(80),
        frame: CGRect(x: 0, y: 0, width: 300, height: 200),
        pixelSize: CGSize(width: 300, height: 200)
    )
    controller.pin(to: .display(9), pixelSize: CGSize(width: 1_920, height: 1_080))
    await controller.waitForPendingTransition()
    events.values.removeAll()

    let observed = CGRect(x: 40, y: 50, width: 180, height: 120)
    controller.follow(identity: identity(81), frame: observed,
                      pixelSize: CGSize(width: 180, height: 120))
    await controller.waitForPendingTransition()

    #expect(events.values.isEmpty)
    #expect(controller.target == .display(9))
    // The geometry is still recorded: the monitor shapes itself by it the
    // moment the pin comes off.
    #expect(controller.windowFrame == observed)
}

@Test @MainActor
func unpinningReturnsToTheLastObservedRecipient() async throws {
    let events = EventLog()
    var streams: [FakePreviewStream] = []
    let controller = PreviewStreamController { target in
        let stream = FakePreviewStream(target: target, name: "s\(streams.count + 1)", events: events)
        streams.append(stream)
        return stream
    }
    try await controller.start(
        identity: identity(90),
        frame: CGRect(x: 0, y: 0, width: 300, height: 200),
        pixelSize: CGSize(width: 300, height: 200)
    )
    controller.pin(to: .display(11), pixelSize: CGSize(width: 1_920, height: 1_080))
    await controller.waitForPendingTransition()
    controller.follow(identity: identity(91), frame: CGRect(x: 1, y: 1, width: 180, height: 120),
                      pixelSize: CGSize(width: 180, height: 120))
    await controller.waitForPendingTransition()
    events.values.removeAll()

    controller.pin(to: nil, pixelSize: .zero)
    await controller.waitForPendingTransition()

    #expect(events.values == ["stop s2", "make s3", "start s3"])
    #expect(controller.target == .attestedWindow(identity(91)))
    #expect(!controller.isPinnedToDisplay)
}

/// Watching the display before and during the move onto it is the case the
/// whole feature exists for, so the pin cannot require an adopted window.
@Test @MainActor
func pinningWithNothingAdoptedStartsADisplayStream() async throws {
    let events = EventLog()
    var streams: [FakePreviewStream] = []
    let controller = PreviewStreamController { target in
        let stream = FakePreviewStream(target: target, name: "s\(streams.count + 1)", events: events)
        streams.append(stream)
        return stream
    }
    controller.pin(to: .display(13), pixelSize: CGSize(width: 1_920, height: 1_080))
    await controller.waitForPendingTransition()

    #expect(events.values == ["make s1", "start s1"])
    #expect(controller.target == .display(13))

    // And unpinning with nothing ever adopted leaves no stream rather than a
    // display the person asked to stop watching.
    events.values.removeAll()
    controller.pin(to: nil, pixelSize: .zero)
    await controller.waitForPendingTransition()

    #expect(events.values == ["stop s1"])
    #expect(controller.stream == nil)
}

/// A release runs at the start of every handover, a moment before the next
/// window is moved onto the display. A pin that did not survive it blanked the
/// monitor exactly when the move it was pinned to watch was about to happen.
@Test @MainActor
func aDisplayPinSurvivesAnApplicationHandover() async throws {
    let events = EventLog()
    var streams: [FakePreviewStream] = []
    let controller = PreviewStreamController { target in
        let stream = FakePreviewStream(target: target, name: "s\(streams.count + 1)", events: events)
        streams.append(stream)
        return stream
    }
    let layer = MonitorLayer(contentsScale: 2)
    controller.attach(layer)

    try await controller.start(
        identity: identity(50),
        frame: CGRect(x: 0, y: 0, width: 300, height: 200),
        pixelSize: CGSize(width: 300, height: 200)
    )
    controller.pin(to: .display(9), pixelSize: CGSize(width: 2560, height: 1440))
    await controller.waitForPendingTransition()
    #expect(controller.target == .display(9))
    events.values.removeAll()

    // What a handover does to the preview, in order: the application is given
    // back, then the next one is adopted.
    await controller.stop()
    #expect(controller.target == .display(9))
    #expect(controller.isPinnedToDisplay)
    #expect(events.values.isEmpty)

    try await controller.start(
        identity: identity(51),
        frame: CGRect(x: 0, y: 0, width: 400, height: 300),
        pixelSize: CGSize(width: 400, height: 300)
    )
    #expect(controller.target == .display(9))
    #expect(events.values.isEmpty)

    // And the host taking the display away takes the pin with it.
    await controller.tearDown()
    #expect(controller.target == nil)
    #expect(!controller.isPinnedToDisplay)
    #expect(events.values == ["detach s2", "stop s2"])
}

// MARK: Recoverable preview, stable size

/// A controller whose recovery pause costs nothing, so a bounded recovery is
/// measured in attempts rather than in wall clock.
@MainActor
private func recoverableController(
    plan: PreviewRecoveryPlan,
    make: @escaping @MainActor (SeatCaptureTarget) -> any PreviewCaptureStreaming
) -> PreviewStreamController {
    PreviewStreamController(recovery: plan, makeStream: make)
}

/// The adoption used to be undone by the preview: the start was in the same
/// `do`, so a capture that could not begin ran `release()` and handed the
/// window back. Adoption and preview availability are separate states now.
@Test @MainActor
func aTransientPreviewFailureSuspendsThePictureAndRecoversInsideItsBounds() async throws {
    let events = EventLog()
    var streams: [FakePreviewStream] = []
    // The first start fails and every later one works: a transient error.
    let controller = recoverableController(
        plan: PreviewRecoveryPlan(attemptLimit: 3, pause: .zero)
    ) { target in
        let stream = FakePreviewStream(target: target, name: "s\(streams.count + 1)", events: events)
        if streams.isEmpty { stream.startFails = true }
        streams.append(stream)
        return stream
    }
    let window = identity(100)
    let frame  = CGRect(x: 0, y: 0, width: 300, height: 200)

    await #expect(throws: (any Error).self) {
        try await controller.start(identity: window, frame: frame,
                                   pixelSize: CGSize(width: 300, height: 200))
    }
    // The picture is suspended. Nothing here says the window was given back:
    // the controller holds no adoption to give back in the first place, and
    // the driver's own `adopt` no longer releases on this path.
    #expect(controller.availability == .suspended(String(describing: FakePreviewStream.Failure.start)))
    #expect(controller.stream == nil)

    // The scheduled recovery puts it back without anyone asking again.
    while controller.availability != .live { await Task.yield() }
    #expect(streams.count == 2)
    #expect(controller.target == .attestedWindow(window))
    #expect(controller.lastFailure == nil)
}

/// Bounded means bounded: a preview that never comes back stops being tried.
@Test @MainActor
func aPreviewThatNeverStartsIsGivenUpAfterTheAttemptLimit() async throws {
    let events = EventLog()
    var streams: [FakePreviewStream] = []
    let controller = recoverableController(
        plan: PreviewRecoveryPlan(attemptLimit: 3, pause: .zero)
    ) { target in
        let stream = FakePreviewStream(target: target, name: "s\(streams.count + 1)", events: events)
        stream.startFails = true
        streams.append(stream)
        return stream
    }

    await #expect(throws: (any Error).self) {
        try await controller.start(identity: identity(101),
                                   frame: CGRect(x: 0, y: 0, width: 300, height: 200),
                                   pixelSize: CGSize(width: 300, height: 200))
    }
    while case .suspended = controller.availability { await Task.yield() }

    // The first start plus exactly three retries, and then nothing more.
    #expect(streams.count == 4)
    guard case .unavailable = controller.availability else {
        Issue.record("the recovery ended at \(controller.availability)")
        return
    }
    let seen = streams.count
    await Task.yield()
    await Task.yield()
    #expect(streams.count == seen)
}

/// The two bounds, driven directly so the monotone one costs no wall clock.
@Test
func theRecoveryPlanIsBoundedByCountAndByItsWindow() {
    let plan = PreviewRecoveryPlan(attemptLimit: 3, pause: .zero,
                                   windowNanoseconds: 10 * NSEC_PER_SEC)
    let start: UInt64 = 1_000
    #expect(plan.mayRetry(attempts: 0, startedAt: start, now: start))
    #expect(plan.mayRetry(attempts: 2, startedAt: start, now: start + NSEC_PER_SEC))
    // The count alone ends it.
    #expect(!plan.mayRetry(attempts: 3, startedAt: start, now: start + NSEC_PER_SEC))
    // And the window alone ends it, however few attempts were spent.
    #expect(!plan.mayRetry(attempts: 0, startedAt: start, now: start + 10 * NSEC_PER_SEC))
}

/// A window whose reported size wobbles by a pixel between observations. The
/// exact comparison this replaced restarted the stream on every one of them.
@Test @MainActor
func aOnePixelOscillationRestartsNothingAcrossManyObservations() async throws {
    let events = EventLog()
    var streams: [FakePreviewStream] = []
    let controller = recoverableController(plan: PreviewRecoveryPlan()) { target in
        let stream = FakePreviewStream(target: target, name: "s\(streams.count + 1)", events: events)
        streams.append(stream)
        return stream
    }
    let window = identity(110)
    let frame  = CGRect(x: 0, y: 0, width: 300, height: 200)
    try await controller.start(identity: window, frame: frame,
                               pixelSize: CGSize(width: 600, height: 400))
    events.values.removeAll()

    let readings = [
        CGSize(width: 601, height: 400), CGSize(width: 600, height: 401),
        CGSize(width: 599, height: 400), CGSize(width: 600, height: 399),
        CGSize(width: 601, height: 401), CGSize(width: 600, height: 400),
        CGSize(width: 599, height: 401), CGSize(width: 601, height: 399)
    ]
    for reading in readings {
        controller.follow(identity: window, frame: frame, pixelSize: reading)
        await controller.waitForPendingTransition()
    }

    // Nothing at all: no restart, and no reconfiguration either. The oracle is
    // the kit's own rule, read here independently of the controller.
    #expect(events.values.isEmpty)
    #expect(streams.count == 1)
    for (previous, reading) in zip(readings, readings.dropFirst()) {
        #expect(CaptureShapeStabilisation.settledShape(
            running: CGSize(width: 600, height: 400),
            reading: reading,
            previousReading: previous) == nil)
    }
}

/// A real resize: the window is half the size it was. The readings are still
/// noisy on the way, and what converges is one reconfiguration and no more.
@Test @MainActor
func arealShapeChangeConvergesOnceAndStalesWhatWasOnScreen() async throws {
    let events = EventLog()
    var streams: [FakePreviewStream] = []
    let controller = recoverableController(plan: PreviewRecoveryPlan()) { target in
        let stream = FakePreviewStream(target: target, name: "s\(streams.count + 1)", events: events)
        streams.append(stream)
        return stream
    }
    let window = identity(120)
    let frame  = CGRect(x: 0, y: 0, width: 300, height: 200)
    let layer  = MonitorLayer(contentsScale: 2)
    controller.attach(layer)
    try await controller.start(identity: window, frame: frame,
                               pixelSize: CGSize(width: 600, height: 400))
    events.values.removeAll()

    // Mid-resize: no two readings agree, so nothing is chased.
    for reading in [CGSize(width: 520, height: 350), CGSize(width: 410, height: 280)] {
        controller.follow(identity: window, frame: frame, pixelSize: reading)
        await controller.waitForPendingTransition()
    }
    #expect(events.values.isEmpty)

    // It came to rest, and two agreeing readings are the settle budget.
    for _ in 0..<4 {
        controller.follow(identity: window, frame: frame,
                          pixelSize: CGSize(width: 300, height: 200))
        await controller.waitForPendingTransition()
    }

    #expect(events.values == ["update s1"])
    #expect(streams.count == 1)
    #expect(streams[0].configuredPixelSize == CGSize(width: 300, height: 200))
    // What is on the layer was captured at the old shape and is no longer
    // live. It stays on screen saying so until a frame of the new shape lands.
    #expect(layer.presentation.isLive == false)
}

/// The configuration update is the path taken when the framework allows it,
/// and the restart is what is left when it refuses. The same settled change,
/// twice, with the only difference being the framework's answer.
@Test @MainActor
func aRefusedConfigurationUpdateFallsBackToARestart() async throws {
    let events = EventLog()
    var streams: [FakePreviewStream] = []
    let controller = recoverableController(plan: PreviewRecoveryPlan()) { target in
        let stream = FakePreviewStream(target: target, name: "s\(streams.count + 1)", events: events)
        stream.updateFails = true
        streams.append(stream)
        return stream
    }
    let window = identity(130)
    let frame  = CGRect(x: 0, y: 0, width: 300, height: 200)
    try await controller.start(identity: window, frame: frame,
                               pixelSize: CGSize(width: 600, height: 400))
    events.values.removeAll()

    for _ in 0..<2 {
        controller.follow(identity: window, frame: frame,
                          pixelSize: CGSize(width: 300, height: 200))
        await controller.waitForPendingTransition()
    }

    #expect(events.values == ["update s1", "stop s1", "make s2", "start s2"])
    #expect(streams.count == 2)
    #expect(streams[1].configuredPixelSize == CGSize(width: 300, height: 200))
    #expect(controller.availability == .live)
}

/// The two consumers of the shape rule are the kit's Monitor and this
/// controller, and there is one rule. The Monitor's own answer is built on
/// `CaptureShapeStabilisation`, so agreeing with it here is agreeing with the
/// Monitor: when the stabiliser says nothing, `following` answers nil, and
/// when it says a shape, `following` asks the stream for that shape.
@Test
func theLabAndTheKitFollowTheSameShapeRule() {
    let asked = MonitorConfiguration(targetFrameRate: .sixty,
                                     output: .fixed(CGSize(width: 600, height: 400)))
    let running = asked.captureConfiguration(for: .standard).pixelSize
    let cases: [(CGSize, CGSize?)] = [
        (CGSize(width: 601, height: 400), nil),
        (CGSize(width: 600, height: 400), nil),
        (CGSize(width: 300, height: 200), CGSize(width: 300, height: 200)),
        (CGSize(width: 0,   height: 200), nil),
        (CGSize(width: CGFloat.infinity, height: 200), nil)
    ]
    for (reading, expected) in cases {
        let stabilised = CaptureShapeStabilisation.settledShape(
            running: running, reading: reading, previousReading: reading)
        #expect(stabilised == expected)
        let followed = asked.following(contentPixelSize: reading,
                                       previousReading: reading, at: .standard)
        #expect(followed?.captureConfiguration(for: .standard).pixelSize == expected)
    }
}

/// A 32BGRA frame of `window` over a surface this process made.
private func liveFrame(of window: WindowIdentity, displayTime: UInt64 = 9) -> SeatFrame? {
    let properties: [IOSurfacePropertyKey: any Sendable] = [
        .width: 4, .height: 4, .bytesPerElement: 4, .bytesPerRow: 16,
        .pixelFormat: kCVPixelFormatType_32BGRA,
    ]
    guard let surface = IOSurface(properties: properties) else { return nil }
    var unmanaged: Unmanaged<CVPixelBuffer>?
    guard CVPixelBufferCreateWithIOSurface(
              kCFAllocatorDefault, unsafeBitCast(surface, to: IOSurfaceRef.self), nil, &unmanaged
          ) == kCVReturnSuccess,
          let buffer = unmanaged?.takeRetainedValue()
    else { return nil }
    let size = CGSize(width: 4, height: 4)
    return SeatFrame(
        surface          : surface,
        pixelBuffer      : buffer,
        presentationTime : .zero,
        receivedAt       : 1,
        displayTime      : displayTime,
        displayGeneration: 1,
        source           : .window(window),
        geometry         : FrameGeometryObservation(
            source              : .window(window),
            screenRect          : CGRect(origin: .zero, size: size),
            contentRectInSurface: CGRect(origin: .zero, size: size),
            scaleFactor         : 1,
            contentScale        : 1,
            pixelSize           : size,
            version             : GeometryObservationVersion(observerGeneration: 1, sequence: 1),
            capturesFullWindow  : true
        )
    )
}

/// Observation reads the preview first, and only the live stream of the very window it asks for.
@Test @MainActor
func theLivePreviewOffersAFrameOfItsOwnWindowOnly() async throws {
    let events = EventLog()
    var streams: [FakePreviewStream] = []
    let controller = PreviewStreamController { target in
        let stream = FakePreviewStream(target: target, name: "s\(streams.count + 1)", events: events)
        streams.append(stream)
        return stream
    }
    // Never started: there is nothing to read.
    #expect(await controller.liveFrame(of: identity(20), displayedAfter: 0, within: .milliseconds(100))
            .failureReason == .notLive)

    try await controller.start(
        identity : identity(20),
        frame    : CGRect(x: 0, y: 0, width: 4, height: 4),
        pixelSize: CGSize(width: 4, height: 4)
    )
    let stream = try #require(streams.first)
    let offered = try #require(liveFrame(of: identity(20)))
    stream.offeredFrame = offered

    let answer = await controller.liveFrame(of: identity(20), displayedAfter: 77, within: .milliseconds(100))
    #expect(try answer.get().surface === offered.surface)
    #expect(stream.frameWaits.first?.notBefore == 77)
    #expect(stream.frameWaits.first?.bound == .milliseconds(100))

    #expect(await controller.liveFrame(of: identity(21), displayedAfter: 0, within: .milliseconds(100))
            .failureReason == .otherWindow)

    stream.offeredFrame = nil
    #expect(await controller.liveFrame(of: identity(20), displayedAfter: 0, within: .milliseconds(100))
            .failureReason == .noFrameInBound)
}

/// A pin to the display outranks observation here as everywhere: no display frame is cropped.
@Test @MainActor
func aPinnedPreviewOffersNoWindowFrame() async throws {
    let events = EventLog()
    let controller = PreviewStreamController { target in
        FakePreviewStream(target: target, name: "s", events: events)
    }
    try await controller.start(
        identity : identity(30),
        frame    : CGRect(x: 0, y: 0, width: 4, height: 4),
        pixelSize: CGSize(width: 4, height: 4)
    )
    controller.pin(to: .display(7), pixelSize: CGSize(width: 1_920, height: 1_080))
    await controller.waitForPendingTransition()
    #expect(await controller.liveFrame(of: identity(30), displayedAfter: 0, within: .milliseconds(100))
            .failureReason == .pinnedToDisplay)
}

/// A preview in its bounded recovery is not a picture to observe from.
@Test @MainActor
func aRecoveringPreviewOffersNoFrame() async throws {
    let events = EventLog()
    let controller = recoverableController(
        plan: PreviewRecoveryPlan(attemptLimit: 3, pause: .seconds(60))
    ) { target in
        let stream = FakePreviewStream(target: target, name: "s", events: events)
        stream.startFails = true
        return stream
    }
    await #expect(throws: (any Error).self) {
        try await controller.start(identity: identity(40),
                                   frame: CGRect(x: 0, y: 0, width: 4, height: 4),
                                   pixelSize: CGSize(width: 4, height: 4))
    }
    #expect(await controller.liveFrame(of: identity(40), displayedAfter: 0, within: .milliseconds(100))
            .failureReason == .recovering)
    await controller.tearDown()
}

/// The stream's cached window server answers are dropped when an observation saw the window
/// elsewhere or at another size, and kept when it saw it where it was.
@Test @MainActor
func followDropsTheStreamsCachedReadingsOnlyOnAChange() async throws {
    let events = EventLog()
    var streams: [FakePreviewStream] = []
    let controller = PreviewStreamController { target in
        let stream = FakePreviewStream(target: target, name: "s\(streams.count + 1)", events: events)
        streams.append(stream)
        return stream
    }
    let frame = CGRect(x: 0, y: 0, width: 300, height: 200)
    let size  = CGSize(width: 600, height: 400)
    try await controller.start(identity: identity(50), frame: frame, pixelSize: size)
    let stream = try #require(streams.first)

    controller.follow(identity: identity(50), frame: frame, pixelSize: size)
    await controller.waitForPendingTransition()
    #expect(stream.readingInvalidations == 0)

    controller.follow(identity: identity(50), frame: frame.offsetBy(dx: 5, dy: 0), pixelSize: size)
    await controller.waitForPendingTransition()
    #expect(stream.readingInvalidations == 1)

    controller.follow(identity: identity(50), frame: frame.offsetBy(dx: 5, dy: 0),
                      pixelSize: CGSize(width: 602, height: 400))
    await controller.waitForPendingTransition()
    #expect(stream.readingInvalidations == 2)
}

/// A controller whose rest delay is `delay`, over fake streams kept in `streams`.
@MainActor
private func restingController(
    delay  : Duration,
    events : EventLog,
    streams: @escaping (FakePreviewStream) -> Void
) -> PreviewStreamController {
    PreviewStreamController(rest: PreviewRestPlan(delay: delay)) { target in
        let stream = FakePreviewStream(target: target, name: "s", events: events)
        streams(stream)
        return stream
    }
}

/// With nothing using it and nobody watching, the stream asks for the rest rate after the delay,
/// in place: the same stream, still live.
@Test @MainActor
func anUnusedStreamRestsAfterTheDelay() async throws {
    let events = EventLog()
    var streams: [FakePreviewStream] = []
    let controller = restingController(delay: .milliseconds(20), events: events) { streams.append($0) }
    try await controller.start(identity: identity(60), frame: CGRect(x: 0, y: 0, width: 4, height: 4),
                               pixelSize: CGSize(width: 4, height: 4))
    let stream = try #require(streams.first)
    #expect(stream.configuredFramesPerSecond == 30)
    events.values.removeAll()

    await controller.waitForRestTimer()

    #expect(controller.isResting)
    #expect(stream.configuredFramesPerSecond == 1)
    #expect(events.values == ["update s"])
    #expect(streams.count == 1)
    #expect(controller.availability == .live)
    await controller.tearDown()
}

/// A Turn, a Command or a followed observation wakes the stream before any frame is asked for,
/// so the frame request that follows reads the stream at its full rate.
@Test @MainActor
func aUseLeavesTheRestBeforeAFrameIsRequested() async throws {
    let window = identity(61)
    for activity in [PreviewActivity.turn, .command, .observation] {
        let events = EventLog()
        var streams: [FakePreviewStream] = []
        let controller = restingController(delay: .milliseconds(200), events: events) { streams.append($0) }
        let frame = CGRect(x: 0, y: 0, width: 4, height: 4)
        try await controller.start(identity: window, frame: frame, pixelSize: CGSize(width: 4, height: 4))
        let stream = try #require(streams.first)
        await controller.waitForRestTimer()
        #expect(stream.configuredFramesPerSecond == 1)

        if activity == .observation {
            controller.follow(identity: window, frame: frame, pixelSize: CGSize(width: 4, height: 4))
        } else {
            controller.noteActivity(activity)
        }
        #expect(!controller.isResting)
        await controller.waitForPendingTransition()
        #expect(stream.configuredFramesPerSecond == 30, "\(activity)")

        let offered = try #require(liveFrame(of: window))
        stream.offeredFrame = offered
        let answer = await controller.liveFrame(of: window, displayedAfter: 5, within: .milliseconds(100))
        #expect(try answer.get().surface === offered.surface, "\(activity)")
        #expect(stream.frameWaits.map(\.notBefore) == [5])
        await controller.tearDown()
    }
}

/// A frame request that finds the stream resting never reaches the stream, so no frame from the
/// rest can be handed over: it declines with `resting`, which is the Still, and wakes the stream
/// for the next request, which waits for a frame displayed after its own instant.
@Test @MainActor
func aRequestDuringRestTakesTheStillAndWakesTheStream() async throws {
    let events = EventLog()
    var streams: [FakePreviewStream] = []
    let controller = restingController(delay: .milliseconds(200), events: events) { streams.append($0) }
    let window = identity(62)
    try await controller.start(identity: window, frame: CGRect(x: 0, y: 0, width: 4, height: 4),
                               pixelSize: CGSize(width: 4, height: 4))
    let stream = try #require(streams.first)
    stream.offeredFrame = liveFrame(of: window)
    await controller.waitForRestTimer()

    let during = await controller.liveFrame(of: window, displayedAfter: 7, within: .milliseconds(100))
    #expect(during.failureReason == .resting)
    #expect(stream.frameWaits.isEmpty)
    #expect(!controller.isResting)

    // The wake is queued, not confirmed: the next request still takes the Still.
    let waking = await controller.liveFrame(of: window, displayedAfter: 8, within: .milliseconds(100))
    #expect(waking.failureReason == .resting)
    #expect(stream.frameWaits.isEmpty)

    await controller.waitForPendingTransition()
    #expect(stream.configuredFramesPerSecond == 30)
    let after = await controller.liveFrame(of: window, displayedAfter: 9, within: .milliseconds(100))
    #expect(after.failureReason == nil)
    #expect(stream.frameWaits.last?.notBefore == 9)
    await controller.tearDown()
}

/// While a layer shows the stream it keeps its rate whatever the delay; closing the picture
/// starts the delay, and opening it again wakes the stream.
@Test @MainActor
func aShownStreamDoesNotRest() async throws {
    let events = EventLog()
    var streams: [FakePreviewStream] = []
    let controller = restingController(delay: .milliseconds(20), events: events) { streams.append($0) }
    let layer = MonitorLayer(contentsScale: 2)
    controller.attach(layer)
    try await controller.start(identity: identity(63), frame: CGRect(x: 0, y: 0, width: 4, height: 4),
                               pixelSize: CGSize(width: 4, height: 4))
    let stream = try #require(streams.first)

    await controller.waitForRestTimer()
    try await Task.sleep(for: .milliseconds(60))
    #expect(!controller.isResting)
    #expect(stream.configuredFramesPerSecond == 30)
    #expect(!events.values.contains("update s"))

    controller.detach(layer)
    await controller.waitForRestTimer()
    #expect(controller.isResting)
    #expect(stream.configuredFramesPerSecond == 1)

    controller.attach(layer)
    #expect(!controller.isResting)
    await controller.waitForPendingTransition()
    #expect(stream.configuredFramesPerSecond == 30)
    await controller.tearDown()
}

/// A stream pinned to the display is shown to the person, so it keeps its rate whatever the
/// delay; unpinning starts the delay.
@Test @MainActor
func aPinnedStreamDoesNotRest() async throws {
    let events = EventLog()
    var streams: [FakePreviewStream] = []
    let controller = restingController(delay: .milliseconds(20), events: events) { streams.append($0) }
    let size = CGSize(width: 4, height: 4)
    try await controller.start(identity: identity(64), frame: CGRect(origin: .zero, size: size),
                               pixelSize: size)

    controller.pin(to: .display(13), pixelSize: size)
    await controller.waitForPendingTransition()
    let pinned = try #require(streams.last)
    await controller.waitForRestTimer()
    try await Task.sleep(for: .milliseconds(60))
    #expect(!controller.isResting)
    #expect(pinned.configuredFramesPerSecond == 30)

    controller.pin(to: nil, pixelSize: size)
    await controller.waitForPendingTransition()
    let window = try #require(streams.last)
    await controller.waitForRestTimer()
    #expect(controller.isResting)
    #expect(window.configuredFramesPerSecond == 1)
    await controller.tearDown()
}

/// A stream whose frames ended is not live: the answer is `notLive`, never a frame wait that ran
/// out, the preview stops reading as live, and the next observation it follows replaces the stream.
@Test @MainActor
func aStreamWhoseFramesEndedIsNotLive() async throws {
    let events = EventLog()
    var streams: [FakePreviewStream] = []
    let controller = PreviewStreamController { target in
        let stream = FakePreviewStream(target: target, name: "s\(streams.count + 1)", events: events)
        streams.append(stream)
        return stream
    }
    let window = identity(70)
    let frame  = CGRect(x: 0, y: 0, width: 4, height: 4)
    try await controller.start(identity: window, frame: frame, pixelSize: frame.size)
    let ended = try #require(streams.first)
    ended.endsFrames = true

    #expect(await controller.liveFrame(of: window, displayedAfter: 0, within: .milliseconds(100))
            .failureReason == .notLive)
    #expect(controller.availability == .unavailable("The preview stream ended."))
    #expect(await controller.liveFrame(of: window, displayedAfter: 0, within: .milliseconds(100))
            .failureReason == .notLive)
    #expect(ended.frameWaits.count == 1, "a stream known to have ended is not waited on again")

    controller.follow(identity: window, frame: frame, pixelSize: frame.size)
    await controller.waitForPendingTransition()
    #expect(events.values.suffix(3) == ["stop s1", "make s2", "start s2"])
    #expect(controller.availability == .live)
    await controller.tearDown()
}

/// The live run of 7 October: a settle whose last frame wait ran to the cap, with no change, ended
/// the frames for every observation after it. The observation that follows must get its frame.
@Test @MainActor
func aSettleEndingAtItsCapLeavesTheStreamServingObservation() async throws {
    let events  = EventLog()
    let waiters = FrameWaiters()
    let controller = PreviewStreamController { target in
        let stream = FakePreviewStream(target: target, name: "s", events: events)
        stream.waiters = waiters
        return stream
    }
    let window = identity(71)
    let rect   = CGRect(x: 0, y: 0, width: 4, height: 4)
    try await controller.start(identity: window, frame: rect, pixelSize: rect.size)
    let clock = MachAbsoluteContentClock()

    // Two identical frames, each presented just before its wait, then none: the last wait runs
    // to the cap in the stream's own waiting.
    var answers: [LiveFrameFallback?] = []
    let ending = await SeatSettler.wait(
        cap        : .milliseconds(500),
        next       : { after, bound in
            if answers.count < 2, let frame = liveFrame(of: window, displayTime: mach_absolute_time()) {
                waiters.offer(frame)
            }
            let answer = await controller.liveFrame(of: window, displayedAfter: after, within: bound)
            answers.append(answer.failureReason)
            return answer
        },
        displayedAt: { $0.displayTime.flatMap { clock.displayTimeNanoseconds(fromMachTicks: $0) } },
        now        : { DispatchTime.now().uptimeNanoseconds },
        sleep      : { try? await Task.sleep(for: $0) }
    )
    #expect(ending == .quiet)
    #expect(answers == [nil, nil, .noFrameInBound])

    // The observation waits first; a frame presented off the main actor a moment later serves it.
    let notBefore = DispatchTime.now().uptimeNanoseconds
    let offered = try #require(liveFrame(of: window, displayTime: mach_absolute_time() + 1))
    Task.detached {
        try? await Task.sleep(for: .milliseconds(20))
        waiters.offer(offered)
    }
    let answer = await controller.liveFrame(of: window, displayedAfter: notBefore, within: .seconds(2))
    #expect(try answer.get().surface === offered.surface)
    await controller.tearDown()
}

private extension Result where Failure == LiveFrameFallback {
    var failureReason: LiveFrameFallback? {
        if case .failure(let reason) = self { return reason }
        return nil
    }
}
