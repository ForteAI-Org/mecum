import CoreGraphics
import Foundation
import InteractionListener
import InteractionObservation
import Testing
@testable import Mecum

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct WatcherModelTests {
    private static let granted = WatcherAccess(inputMonitoring: true, screenRecording: true, accessibility: true)
    private static let finder = WatcherApplication(processID: 123, bundleID: "synthetic.finder", name: "Finder")

    private func report(_ sequence: UInt64 = 1) -> InteractionReport {
        InteractionReport(
            event: .init(kind: .click, timestamp: Date(), startedAt: 1, endedAt: 1,
                         precedingRevision: 0, revision: 1, point: .init(x: -100, y: 20),
                         window: nil, processID: 123, sourceProcessID: 456, sequence: sequence),
            app: "Synthetic", bundleID: "synthetic.finder", before: .missing("no_before_scene"),
            afterElement: nil, afterStatus: "input_during_observation", accessibility: nil
        )
    }

    @Test func constructionDoesNotStartAndGrantsAreRechecked() async {
        var access = WatcherAccess(inputMonitoring: false, screenRecording: true, accessibility: true)
        var creations = 0
        let session = ControlledWatcherSession()
        let model = WatcherModel(permissions: { access }, runningApps: { [] }, makeSession: { _ in
            creations += 1
            return session
        })
        #expect(creations == 0)
        #expect(!model.isActive)
        model.start()
        #expect(creations == 0)
        #expect(!model.canStart)
        access = Self.granted
        model.start()
        await session.waitForStart()
        #expect(creations == 1)
        await model.stop()
        #expect(session.didRelease)
        #expect(model.phase == .idle)
    }

    @Test func stoppingJoinsCleanupAndPreventsOverlappingRuns() async {
        let session = ControlledWatcherSession()
        session.holdsCleanup = true
        var creations = 0
        let model = WatcherModel(permissions: { Self.granted }, runningApps: { [] }, makeSession: { _ in
            creations += 1
            return session
        })
        model.start()
        await session.waitForStart()
        model.start()
        let stopping = Task { await model.stop() }
        await session.waitForStopRequest()
        #expect(model.phase == .stopping)
        #expect(model.isActive)
        #expect(!model.canStart)
        model.start()
        session.report?(report())
        #expect(model.entries.isEmpty)
        #expect(creations == 1)
        session.releaseCleanup()
        await stopping.value
        #expect(session.didRelease)
        #expect(!model.isActive)
        session.report?(report())
        #expect(model.entries.isEmpty)
        #expect(model.phase == .idle)
    }

    @Test func oldCallbacksCannotEnterANewRun() async {
        let first = ControlledWatcherSession()
        let second = ControlledWatcherSession()
        var sessions = [first, second]
        let model = WatcherModel(permissions: { Self.granted }, runningApps: { [] }, makeSession: { _ in
            sessions.removeFirst()
        })
        model.start()
        await first.waitForStart()
        await model.stop()
        model.start()
        await second.waitForStart()
        first.report?(report())
        first.status?(.perceptionUnavailable("old failure"))
        #expect(model.entries.isEmpty)
        #expect(!model.detail.contains("old failure"))
        second.report?(report(2))
        #expect(model.totalEvents == 1)
        await model.stop()
    }

    @Test func boundedHistoryKeepsUncertaintyAndSourceAttribution() async {
        let session = ControlledWatcherSession()
        let model = WatcherModel(permissions: { Self.granted }, runningApps: { [] }, makeSession: { _ in session })
        model.start()
        await session.waitForStart()
        for sequence in 1...130 { session.report?(report(UInt64(sequence))) }
        #expect(model.totalEvents == 130)
        #expect(model.entries.count == 100)
        #expect(model.entries.first?.before == "no_before_scene")
        #expect(model.entries.first?.after == "input_during_observation")
        #expect(model.entries.first?.input.contains("source PID 456") == true)
        #expect(model.entries.first?.input.contains("sequence 130") == true)
        #expect(model.entries.last?.input.contains("sequence 31") == true)
        model.clear()
        #expect(model.entries.isEmpty)
        #expect(model.totalEvents == 0)
        #expect(model.isActive)
        await model.stop()
    }

    @Test func permissionRevocationStopsTheSession() async {
        let session = ControlledWatcherSession()
        var access = Self.granted
        let model = WatcherModel(permissions: { access }, runningApps: { [] }, makeSession: { _ in session })
        model.start()
        await session.waitForStart()
        access = WatcherAccess(inputMonitoring: true, screenRecording: false, accessibility: true)
        await model.checkHealth()
        #expect(!model.isActive)
        #expect(session.didRelease)
        if case .failed(let reason) = model.phase { #expect(reason.contains("Screen Recording")) }
        else { Issue.record("Revoked grant did not explain the stop") }
    }

    @Test func closedTargetIsNotReboundAndCannotStartStale() async {
        let session = ControlledWatcherSession()
        var apps = [Self.finder]
        var selected: WatcherApplication?
        let model = WatcherModel(permissions: { Self.granted }, runningApps: { apps }, makeSession: {
            selected = $0
            return session
        })
        model.selectedApplication = Self.finder
        model.start()
        await session.waitForStart()
        #expect(selected == Self.finder)
        apps = [.init(processID: 124, bundleID: Self.finder.bundleID, name: "Finder")]
        await model.checkHealth()
        #expect(!model.isActive)
        #expect(session.didRelease)
        model.start()
        #expect(!model.isActive)
        if case .failed(let reason) = model.phase { #expect(reason.contains("closed")) }
        else { Issue.record("Closed target was accepted") }
    }

    @Test func missingAccessibilityAllowsPixelsAndShutdownPreventsRestart() async {
        let session = ControlledWatcherSession()
        let model = WatcherModel(
            permissions: { .init(inputMonitoring: true, screenRecording: true, accessibility: false) },
            runningApps: { [] }, makeSession: { _ in session }
        )
        #expect(model.canStart)
        model.start()
        await session.waitForStart()
        await model.shutdown()
        #expect(!model.canStart)
        model.start()
        #expect(!model.isActive)
    }

    @Test func listenerFailureSurfacesAfterCleanupAndCanRestart() async throws {
        let session = ControlledWatcherSession()
        let model = WatcherModel(permissions: { Self.granted }, runningApps: { [] }, makeSession: { _ in session })
        model.start()
        await session.waitForStart()
        session.fail(ListenerFailure.consumerTooSlow)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.isActive, ContinuousClock.now < deadline { await Task.yield() }
        #expect(!model.isActive)
        #expect(session.didRelease)
        #expect(model.canStart)
        if case .failed(let reason) = model.phase { #expect(reason.contains("could not keep up")) }
        else { Issue.record("Overflow was not visible to the user") }
        await model.stop()
    }
}
