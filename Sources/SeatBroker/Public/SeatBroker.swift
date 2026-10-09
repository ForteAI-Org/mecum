import AccessibilityFacts
import AppKit
import Foundation
import ModelTransports
import Perception
import PixelControlState
import PixelRegions
import PixelSections
import VisionText
import WindowPlacement

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
    /// The one place the Perception layer is composed: Vision for text through
    /// the lab's best-effort wrapper, the pixel segmenter and its media filter
    /// for regions, the colour section detector for panels, and the
    /// accessibility tree as the stage that only ever adds. The pixel control
    /// state reader speaks last, for the switches and checkboxes no
    /// application answered for. It captures nothing: every frame comes from
    /// the seat.
    ///
    /// The accessibility budget is 0.35 s rather than the augmenter's own
    /// 1.5 s. Electron trees are deep and slow to walk, and the budget is the
    /// ceiling on what accessibility may add, not a target: it keeps one
    /// observation under a second, and running out returns fewer labels and
    /// never wrong ones.
    private let perception = ScenePipeline(
        text        : BestEffortTextRecognizer(),
        regions     : ConnectedComponentSegmenter(),
        regionFilter: MediaRegionFilter(),
        sections    : ColorSectionDetector(),
        augmentation: AccessibilityAugmenter(
            budgetSeconds: 0.35,
            windowNumberResolver: { WindowRelocator.windowNumber(of: $0) }
        ),
        // Off for now, and the owner's call to put back. Measured on one Slack
        // window of 89 elements, same frame, same scene: perception 2.76 s with
        // the reader and 1.93 s without it, so it renders the frame again per
        // mark candidate for about 0.83 s a frame. What it buys is the state of
        // the switches and checkboxes accessibility did not answer for, which
        // is a gap and not the common case.
        controlState: nil
    )
    private let recorder: RunRecorder
    private let ledger: LaunchLedger

    /// The way a consumer gets a seat, and the only way: see `SeatQueue`.
    /// Built here rather than handed in because the queue needs the broker it
    /// takes seats from, and a consumer that could supply its own would be a
    /// consumer that could route around the wait.
    public private(set) lazy var queue = SeatQueue(broker: self, capacity: configuration.seatCapacity)

    /// The virtual display a new seat is made with. A change closes the parked seats, so the next
    /// turn that needs the computer gets one of the new size; a seat in use keeps its display until
    /// it is given back, and is then closed instead of parked for reuse.
    public var display = SeatDisplay.standard {
        didSet {
            guard display != oldValue else { return }
            Task { await queue.shutdown() }
        }
    }

    public convenience init(configuration: SeatBrokerConfiguration = .init()) {
        self.init(configuration: configuration, ledger: LaunchLedger())
    }

    /// `ledger` is supplied by the controlled tests, which record provenance and read the quit.
    init(configuration: SeatBrokerConfiguration, ledger: LaunchLedger) {
        self.configuration = configuration
        self.ledger        = ledger
        SeatDriver.setResearchOptIn(configuration.allowUnvalidatedBuild)
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

    /// The macOS permissions a worker's seat needs, and which of them this process holds.
    public func desktopGrants() -> [DesktopGrant] {
        SeatDriver.grants()
    }

    /// This Mac's macOS build and whether the ledger lists it.
    public func buildValidation() -> BuildValidation {
        SeatDriver.buildValidation()
    }

    /// Asks for the first grant still missing, one system prompt at a time, and answers whether
    /// every grant is there. Screen Recording is read once per process, so a fresh grant needs an
    /// app restart.
    @discardableResult
    public func requestMissingPermissions() -> Bool {
        SeatDriver.requestMissingPermissions()
    }

    /// Asks for `grant`: its system prompt the first time, its pane of System Settings after that,
    /// since macOS shows each prompt once per app.
    public func request(_ grant: DesktopGrant) {
        SeatDriver.request(grant.kind)
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
        try await ProviderCatalog.ollamaModels(host: host)
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

    /// How long a launched application that already shows a window may take to show one the seat
    /// can take: DaVinci Resolve loads behind its splash screen for longer than the 20 s a first
    /// window is given.
    static let startupAllowance: Duration = .seconds(60)

    /// Launches an installed application without activating it and waits for
    /// its first on-screen window, so it can be adopted like any other. An app
    /// that is already running gets its windows re-read, and is asked for one
    /// when it has none.
    ///
    /// This is the only place in the kit that starts a process, so it is where
    /// provenance is recorded: an application opened here is the agent's to
    /// quit once it is finished with it. Finding one already running is not
    /// evidence of who started it, so that branch records nothing and the
    /// ledger answers for it: not the lab's, so not the lab's to quit. An application this call
    /// launched that shows no window in time is quit again before the refusal, since no seat ever
    /// took a window of it; one found running is left alone.
    public func launch(_ app: TargetApp, timeout: Duration = .seconds(20)) async throws -> TargetApp {
        let pid: pid_t
        var comeback: LaunchFocusComeback?
        if let running = app.pid {
            pid = running
            let shown = TargetEnumerator.windows(of: running)
            // A window on another desktop is not a missing one: answer at once (ADR 0037).
            if shown.isEmpty, TargetEnumerator.hasWindowOnAnotherDesktop(of: running) {
                throw SeatBrokerError.windowOnAnotherDesktop(application: app.name)
            }
            // A running application with no window is asked for one, the way a click on its Dock icon
            // asks, and is left behind: Finder opens a window, most applications a new document.
            // Without it the wait below could only run out, since the seat never brings it forward.
            if shown.isEmpty, let url = app.bundleURL {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            }
        } else {
            guard let url = app.bundleURL else {
                throw SeatBrokerError.driver("\(app.name) is not running and has no bundle to launch.")
            }
            // Read before the launch: the application may take the front as it starts.
            comeback = LaunchFocusComeback(allowUnvalidatedBuild: self.configuration.allowUnvalidatedBuild)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            pid = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration).processIdentifier
            ledger.record(.openedByAgent, for: pid)
        }
        // A launching application can first show a window accessibility names only for an instant,
        // DaVinci Resolve's splash among them: adopting it failed and quit the application just
        // opened. `LaunchWindowWatch` has what was measured. A launched application is read up to
        // the modal panel level, since Resolve's Project Manager stands at level 4 while Resolve
        // keeps itself active after its start. A running application is taken as it is.
        let launched     = app.pid == nil
        let started      = ContinuousClock.now
        let maximumLayer = launched ? Int(CGWindowLevelForKey(.modalPanelWindow)) : 0
        var watch        = LaunchWindowWatch(timeout: timeout, allowance: Self.startupAllowance)
        var shown: [TargetWindow] = []
        while true {
            comeback?.restore(ifTakenBy: pid)
            shown = TargetEnumerator.windows(of: pid, maximumLayer: maximumLayer)
            guard launched else {
                if !shown.isEmpty || ContinuousClock.now - started >= timeout { break }
                try await Task.sleep(for: .milliseconds(300))
                continue
            }
            switch watch.read(shown: shown, named: TargetEnumerator.accessibleWindowNumbers(of: pid),
                              at: ContinuousClock.now - started) {
                case .adopt(let adoptable):
                    return TargetApp(pid: pid, bundleID: app.bundleID, name: app.name,
                                     bundleURL: app.bundleURL, windows: adoptable)
                case .timedOut:
                    break
                case .wait:
                    try await Task.sleep(for: .milliseconds(300))
                    continue
            }
            break
        }
        // Only windows the seat cannot name: they are handed on, so the adoption says why.
        if !shown.isEmpty {
            return TargetApp(pid: pid, bundleID: app.bundleID, name: app.name,
                             bundleURL: app.bundleURL, windows: shown)
        }
        let wasLaunched = app.pid == nil
        throw SeatBrokerError.noWindowShown(
            application: app.name,
            seconds    : timeout.components.seconds,
            wasLaunched: wasLaunched,
            wasQuit    : wasLaunched && ledger.quitUnseated(pid)
        )
    }

    /// A seat with nothing on it, and nothing brought up yet.
    ///
    /// **Not public.** A seat is scarce and every consumer has to be able to
    /// wait for one, so `SeatQueue` is the only thing that may make one: a
    /// consumer holding this would be a consumer that can skip the queue, and
    /// the wait would go back to being good manners rather than the structure.
    ///
    ///
    /// Neither synchronous nor failable by accident: the driver raises the
    /// background display on its first adoption, so making a session costs one
    /// allocation, needs no grant and cannot fail. That is what lets the chat
    /// exist before any application does. `AgentSession.use` puts the first one
    /// on the seat, `open(applicationNamed:)` is the planner's way in, and
    /// `AgentSession.close` takes the display back down.
    func openSession() -> AgentSession {
        AgentSession(driver: SeatDriver(display: display), ledger: ledger, perception: perception,
                     recorder: recorder, environment: self)
    }
}
