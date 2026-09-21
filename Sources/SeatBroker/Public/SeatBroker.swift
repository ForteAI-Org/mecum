import AppKit
import Foundation

/// The piece that brokers seats between an agent and the applications it
/// uses: it lists targets, reports capabilities and opens sessions. Everything
/// below (seat driver, perception, execution, verification) stays behind
/// `AgentSession`.
///
/// Main-actor bound on purpose: the seat driver is main-actor by contract and
/// needs the application's own event loop turning.
@MainActor
public final class SeatBroker {
    public let configuration: SeatBrokerConfiguration
    private let perception: LocatorPerceptionAdapter
    private let recorder: RunRecorder
    private let ledger = LaunchLedger()

    public init(configuration: SeatBrokerConfiguration = .init()) {
        self.configuration = configuration
        SeatDriver.setResearchOptIn(configuration.allowUnvalidatedBuild)
        self.perception = LocatorPerceptionAdapter(storeDirectory: configuration.perceptionStoreDirectory)
        self.recorder = RunRecorder(directory: configuration.recordingDirectory)
    }

    /// Every recorded run, newest first.
    public func runHistory() -> [RunRecord] {
        recorder.load()
    }

    /// The PNG of the last frame a recorded run saw, if it was saved.
    public func finalFrameURL(for record: RunRecord) -> URL? {
        recorder.frameURL(for: record)
    }

    public func capabilities() -> CapabilityReport {
        SeatDriver.capabilities()
    }

    /// Prompts for every grant that is still missing, and answers whether
    /// they are all there now. Screen Recording is read once per process, so a
    /// fresh grant needs an app restart. macOS shows each prompt once: after a
    /// denial nothing appears again and `openPermissionSettings` is the only
    /// way left.
    @discardableResult
    public func requestMissingPermissions() -> Bool {
        SeatDriver.requestMissingPermissions()
    }

    /// Opens the System Settings pane of the first grant the driver is missing.
    /// False when nothing is missing.
    @discardableResult
    public func openPermissionSettings() -> Bool {
        SeatDriver.openPermissionSettings()
    }

    /// Screen Recording was granted after launch and this process cannot see
    /// it yet; the app has to relaunch before capture works.
    public func screenRecordingNeedsRelaunch() async -> Bool {
        await SeatDriver.screenRecordingNeedsRelaunch()
    }

    /// Models the local Ollama server has pulled.
    public nonisolated func ollamaModels(host: String) async throws -> [String] {
        try await OllamaClient.models(host: host)
    }

    /// nil when the provider is usable now (signed in, key present, server
    /// reachable with models), otherwise the reason it is not.
    public nonisolated func providerStatus(_ provider: ModelProvider, settings: ProviderSettings) async -> String? {
        await ProviderCatalog.status(provider, settings: settings)
    }

    /// Models the provider itself reports as available.
    public nonisolated func availableModels(for provider: ModelProvider, settings: ProviderSettings) async throws -> [String] {
        try await ProviderCatalog.models(provider, settings: settings)
    }

    /// Installed and running applications, alphabetical.
    public func runningTargets() -> [TargetApp] {
        TargetEnumerator.targets()
    }

    /// Launches an installed application without activating it and waits for
    /// its first on-screen window, so it can be adopted like any other. An app
    /// that is already running just gets its windows re-read.
    ///
    /// This is the only place in the kit that starts a process, so it is where
    /// provenance is recorded: an application opened here is the agent's to
    /// quit once it is finished with it. Finding one already running is not
    /// evidence of who started it, so that branch records nothing and the
    /// ledger answers for it: not the lab's, so not the lab's to quit.
    public func launch(_ app: TargetApp, timeout: Duration = .seconds(20)) async throws -> TargetApp {
        let pid: pid_t
        if let running = app.pid {
            pid = running
        } else {
            guard let url = app.bundleURL else {
                throw SeatBrokerError.driver("\(app.name) is not running and has no bundle to launch.")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            pid = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration).processIdentifier
            ledger.record(.openedByAgent, for: pid)
        }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let windows = TargetEnumerator.windows(of: pid)
            if !windows.isEmpty {
                return TargetApp(pid: pid, bundleID: app.bundleID, name: app.name,
                                 bundleURL: app.bundleURL, windows: windows)
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        throw SeatBrokerError.driver("\(app.name) launched but showed no window within \(timeout.components.seconds) s.")
    }

    /// A seat with nothing on it, and nothing brought up yet.
    ///
    /// Neither synchronous nor failable by accident: the driver raises the
    /// background display on its first adoption, so making a session costs one
    /// allocation, needs no grant and cannot fail. That is what lets the chat
    /// exist before any application does. `AgentSession.use` puts the first one
    /// on the seat, `open(applicationNamed:)` is the planner's way in, and
    /// `AgentSession.close` takes the display back down.
    public func openSession() -> AgentSession {
        AgentSession(driver: SeatDriver(), ledger: ledger, perception: perception,
                     recorder: recorder, environment: self)
    }
}
