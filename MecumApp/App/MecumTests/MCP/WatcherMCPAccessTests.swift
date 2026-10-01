import Foundation
import LocalMCP
import Testing
@testable import Mecum

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WatcherMCPAccessTests {
    private let granted = WatcherAccess(inputMonitoring: true, screenRecording: true, accessibility: true)

    @Test func clientCannotReadOrStopAManualWatcher() async throws {
        let native = ControlledWatcherSession()
        let model = WatcherModel(permissions: { granted }, runningApps: { [] }, makeSession: { _ in native })
        let access = WatcherMCPAccess(watcher: model)
        let owner = UUID()
        model.start()
        await native.waitForStart()
        for name in ["watch_recent", "watch_stop", "watch_start"] {
            await #expect(throws: MCPRequestFailure.self) {
                _ = try await access.call(name, arguments: .object(["app": .string("*")]), owner: owner)
            }
        }
        await access.release(owner: owner)
        #expect(model.isActive)
        #expect(!native.didRequestStop)
        await model.stop()
    }

    @Test func ownedWatcherStopsOnDisconnectAndDoesNotLeakToAnotherClient() async throws {
        let native = ControlledWatcherSession()
        let model = WatcherModel(permissions: { granted }, runningApps: { [] }, makeSession: { _ in native })
        let access = WatcherMCPAccess(watcher: model)
        let owner = UUID()
        _ = try await access.call("watch_start", arguments: .object(["app": .string("*")]), owner: owner)
        await native.waitForStart()
        await #expect(throws: MCPRequestFailure.self) {
            _ = try await access.call("watch_recent", arguments: .object([:]), owner: UUID())
        }
        await access.release(owner: owner)
        #expect(!model.isActive)
        #expect(native.didRelease)
        #expect(model.entries.isEmpty)
    }

    @Test func manualRestartInvalidatesExternalOwnershipAndInvalidLimitHasNoEffect() async throws {
        let first = ControlledWatcherSession()
        let second = ControlledWatcherSession()
        var sessions = [first, second]
        let model = WatcherModel(permissions: { granted }, runningApps: { [] }, makeSession: { _ in sessions.removeFirst() })
        let access = WatcherMCPAccess(watcher: model)
        let owner = UUID()
        await #expect(throws: MCPRequestFailure.self) {
            _ = try await access.call("watch_start", arguments: .object(["app": .string("*"), "limit": .number(-1)]), owner: owner)
        }
        #expect(!model.isActive)
        _ = try await access.call("watch_start", arguments: .object(["app": .string("*")]), owner: owner)
        await first.waitForStart()
        await model.stop()
        model.start()
        await second.waitForStart()
        await access.release(owner: owner)
        #expect(model.isActive)
        #expect(!second.didRequestStop)
        await model.stop()
    }
}
