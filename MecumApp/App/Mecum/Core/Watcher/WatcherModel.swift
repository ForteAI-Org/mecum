import Foundation
import InteractionListener
import InteractionObservation
import Observation

/// WatcherModel owns the app's single run across windows. Start is explicit; restart never overlaps
/// old teardown. Recent display records are capped and are not persisted or sent to a model.
@Observable
@MainActor
final class WatcherModel {
    enum Phase: Equatable { case idle, starting, watching, stopping, failed(String) }

    private(set) var phase: Phase = .idle
    private(set) var access: WatcherAccess
    private(set) var applications: [WatcherApplication] = []
    var selectedApplication: WatcherApplication?
    private(set) var entries: [WatcherEntry] = []
    private(set) var totalEvents = 0
    private(set) var runID = UUID()
    private(set) var detail = "Choose an app, then start watching."
    private(set) var activeApplication: WatcherApplication?

    private let permissions: @MainActor () -> WatcherAccess
    private let runningApps: @MainActor () -> [WatcherApplication]
    private let makeSession: @MainActor (WatcherApplication?) throws -> any WatcherSession
    private var session: (any WatcherSession)?
    private var task: Task<Void, Never>?
    private var health: Task<Void, Never>?
    private var generation = UUID()
    private var stopReason: String?
    private var isShuttingDown = false

    init(
        permissions: @escaping @MainActor () -> WatcherAccess = WatcherAccess.current,
        runningApps: @escaping @MainActor () -> [WatcherApplication] = WatcherApplication.running,
        makeSession: @escaping @MainActor (WatcherApplication?) throws -> any WatcherSession = { try NativeWatcherSession(application: $0) }
    ) {
        self.permissions = permissions
        self.runningApps = runningApps
        self.makeSession = makeSession
        access = permissions()
        applications = runningApps()
    }

    isolated deinit {
        task?.cancel()
        health?.cancel()
    }

    var isActive: Bool { task != nil }
    var canStart: Bool { !isShuttingDown && !isActive && access.blockingReason == nil }
    var statusTitle: String {
        switch phase {
        case .idle: "Stopped"
        case .starting: "Waiting for input"
        case .watching: "Watching"
        case .stopping: "Stopping"
        case .failed: "Stopped with an issue"
        }
    }

    func refreshEnvironment() {
        access = permissions()
        applications = runningApps()
    }

    func start() {
        guard !isActive, !isShuttingDown else { return }
        refreshEnvironment()
        if let reason = access.blockingReason { phase = .failed(reason); return }
        if let selectedApplication, !applications.contains(selectedApplication) {
            phase = .failed("The selected application closed. Choose a running app.")
            return
        }
        let current: any WatcherSession
        do { current = try makeSession(selectedApplication) }
        catch { phase = .failed(String(describing: error)); return }
        let run = UUID()
        generation = run
        runID = run
        activeApplication = selectedApplication
        stopReason = nil
        entries.removeAll()
        totalEvents = 0
        detail = "Move the pointer into the app and wait for a scene before clicking."
        phase = .starting
        session = current
        task = Task { [weak self] in
            var failure: String?
            do {
                try await current.run(report: { [weak self] report in
                    guard let self, self.generation == run, self.isActive, self.phase != .stopping else { return }
                    self.phase = .watching
                    self.totalEvents += 1
                    self.entries.insert(WatcherEntry(report), at: 0)
                    if self.entries.count > 100 { self.entries.removeLast(self.entries.count - 100) }
                }, status: { [weak self] status in
                    guard let self, self.generation == run, self.isActive, self.phase != .stopping else { return }
                    self.phase = .watching
                    switch status {
                    case .ready(let window, let count):
                        let title = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
                        self.detail = "Ready: \(title.prefix(200)) · window \(window.number) · \(count) elements"
                    case .perceptionUnavailable(let reason):
                        self.detail = "Perception unavailable: \(reason)"
                    }
                })
                if !Task.isCancelled { failure = "The listener ended. Start again to resume watching." }
            } catch is CancellationError { }
            catch { if !Task.isCancelled { failure = String(describing: error) } }
            await current.stop()
            self?.finished(run: run, failure: failure)
        }
        health = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                await self.checkHealth()
                if !self.isActive { return }
            }
        }
    }

    /// Cancellation stops new reports immediately; return waits for the tap and capture to end.
    func stop(reason: String? = nil) async {
        guard let running = task, let current = session else { return }
        if let reason { stopReason = reason }
        phase = .stopping
        health?.cancel()
        health = nil
        running.cancel()
        await current.stop()
        await running.value
    }

    /// Rechecks grants and the exact target instance without rebinding to a relaunched app.
    func checkHealth() async {
        guard isActive, phase != .stopping else { return }
        refreshEnvironment()
        let reason = access.blockingReason ?? activeApplication.flatMap {
            applications.contains($0) ? nil : "The watched application closed. Select it again after reopening it."
        }
        if let reason { await stop(reason: reason) }
    }

    func shutdown() async {
        isShuttingDown = true
        await stop()
    }

    func clear() { entries.removeAll(); totalEvents = 0 }

    private func finished(run: UUID, failure: String?) {
        guard generation == run else { return }
        generation = UUID()
        health?.cancel()
        health = nil
        task = nil
        session = nil
        activeApplication = nil
        phase = (stopReason ?? failure).map(Phase.failed) ?? .idle
        detail = "Watching has stopped. Recent observations remain here until cleared or the app closes."
    }
}
