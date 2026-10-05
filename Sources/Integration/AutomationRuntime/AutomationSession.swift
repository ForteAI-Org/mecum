import AppKit
import Engine
import EngineCore
import Foundation
import Memory
import Perception
import PerceptionCore
import PrivateSymbols
import SeatCore
import SeatDriving
import SeatSession
import VisionText
import WindowServerListing

/// AutomationSession owns one application's Seat across model turns. It contains no MCP, provider,
/// terminal or transcript code. Its caller serializes operations and drains them before closing.
/// Every action captures again through the same EngineRuntime used by ordinary terminal commands,
/// and records what it saw under the call's context through the runtime's recorder.
@MainActor
public final class AutomationSession: AutomationSessionOperating {
    private let memory: MemoryService
    private let allowsDestructive: Bool
    private var target: SeatTarget?
    private var runtime: EngineRuntime?
    private var runningApplication: NSRunningApplication?
    private var closing: Task<Void, Never>?
    private var revision: Int64 = 0
    public private(set) var id: UUID?
    public private(set) var lastReport: CallRecorder.Report?

    public init(memory: MemoryService, allowsDestructive: Bool = false) {
        self.memory = memory
        self.allowsDestructive = allowsDestructive
    }

    public var application: AppContextIdentity? {
        runningApplication.map(AppContextIdentity.init)
    }

    public func open(application word: String, window title: String?, context: ActionContext) async throws -> SceneSnapshot {
        guard target == nil, closing == nil else {
            throw AutomationFailure("A Seat is already open. Observe it or close_session before opening another app.")
        }
        let application = try RunningApplicationLookup.running(word)
        if let missing = Permissions.firstMissing(of: [.screenRecording, .accessibility, .postEvent]) {
            throw AutomationFailure("Missing macOS permission: \(missing). Grant access to the terminal launching Mecum, "
                                    + "then relaunch it if needed. MCP does not bypass macOS permissions.")
        }
        let rows = try WindowServerWindowListing().windows(ownedBy: application.processIdentifier)
        let selected: WindowRow?
        if let title {
            let matches = rows.filter { $0.title?.caseInsensitiveCompare(title) == .orderedSame }
            guard matches.count == 1 else {
                throw AutomationFailure("Expected one open window named '\(title)'. Available: "
                                        + rows.map { $0.title ?? "untitled" }.joined(separator: ", "))
            }
            selected = matches.first
        } else {
            selected = WindowSurfaceClassifier.classify(rows).interaction
        }
        guard let selected else { throw AutomationFailure("The application has no interaction window to adopt.") }
        let target = SeatTarget(configuration: SeatHostConfiguration(followsNewWindows: true, restoresUserFocus: true))
        self.target = target
        self.runningApplication = application
        do {
            try await target.start()
            for row in rows.reversed() where row.number != selected.number
                && WindowSurfaceClassifier.isWindowLayer(row.layer)
                && WindowSurfaceClassifier.isSubstantialWindow(row.frame) {
                try Task.checkCancellation()
                try await target.adopt(windowNumber: row.number, processID: application.processIdentifier,
                                       title: row.title ?? "")
            }
            try await target.adopt(windowNumber: selected.number, processID: application.processIdentifier,
                                   title: selected.title ?? "")
            runtime = EngineRuntime(memory: memory, seat: target)
            id = UUID()
            // The call's event was planned before the application was known: the first scene is the
            // session's own observation, another event with the application named.
            return try await observe(context: context.another(sessionID: id?.uuidString), asOwnObservation: true)
        } catch {
            await close()
            throw error
        }
    }

    public func observe(context: ActionContext) async throws -> SceneSnapshot {
        try await observe(context: context, asOwnObservation: false)
    }

    private func observe(context: ActionContext, asOwnObservation: Bool) async throws -> SceneSnapshot {
        let (application, runtime, _) = try current()
        let perceived = try await runtime.scenes.currentScene(of: application.processIdentifier)
        revision += 1
        let recorder = runtime.recorder(for: context, sessionRevision: revision)
        let scene = asOwnObservation
            ? await recorder.observe(perceived, recordingObservationOf: AppContextIdentity(application))
            : await recorder.observe(perceived)
        lastReport = await recorder.report()
        return scene
    }

    public func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?,
                    context: ActionContext) async throws -> ActOutcome {
        let (application, runtime, seat) = try current()
        guard try seat.agentSeat().state == .ready else {
            throw AutomationFailure("The Seat is not ready for input. Observe, then close and reopen if recovery is needed.")
        }
        if verb == .setToggle, desiredState != .on && desiredState != .off {
            throw AutomationFailure("set_toggle requires value on or off.")
        }
        let request = ActionRequest(
            processID: application.processIdentifier,
            bundleID: application.bundleIdentifier ?? "pid.\(application.processIdentifier)",
            appName: application.localizedName ?? "application",
            target: target, verb: verb, section: section, desiredState: desiredState
        )
        let recorder = runtime.recorder(for: context, sessionRevision: revision)
        let outcome = try await runtime.engine(allowsDestructive: allowsDestructive, observer: recorder).act(request)
        lastReport = await recorder.report()
        return outcome
    }

    public func deliver(_ input: InputRequest.Input, section: String?, context: ActionContext) async throws -> ActOutcome {
        let (application, runtime, seat) = try current()
        guard try seat.agentSeat().state == .ready else {
            throw AutomationFailure("The Seat is not ready for input. Observe, then close and reopen if recovery is needed.")
        }
        let request = InputRequest(
            processID: application.processIdentifier,
            bundleID: application.bundleIdentifier ?? "pid.\(application.processIdentifier)",
            appName: application.localizedName ?? "application",
            input: input, section: section
        )
        let recorder = runtime.recorder(for: context, sessionRevision: revision)
        let outcome = try await runtime.engine(allowsDestructive: allowsDestructive, observer: recorder).deliver(request)
        lastReport = await recorder.report()
        return outcome
    }

    public func select(control: String, item: String, context: ActionContext) async throws -> ActOutcome {
        let (application, runtime, target) = try current()
        let selector = SeatDropdownSelector(target: target, pipeline: ScenePipeline(text: VisionTextRecognizer()))
        let recorder = runtime.recorder(for: context, sessionRevision: revision)
        let result = try await selector.select(
            control: control, item: item,
            identity: SeatDriving.ApplicationIdentity(
                bundleID: application.bundleIdentifier ?? "pid.\(application.processIdentifier)",
                name: application.localizedName ?? "application"
            ),
            permissions: ActionPermissions(allowsDestructive: allowsDestructive),
            dryRun: false
        )
        await recorder.record(before: result.before, menu: result.menu, after: result.after)
        lastReport = await recorder.report()
        return result.outcome
    }

    public func close() async {
        if let closing { await closing.value; return }
        let target = self.target
        let cleanup = Task {
            if let target { await target.stop() }
        }
        closing = cleanup
        self.runtime = nil
        self.target = nil
        runningApplication = nil
        id = nil
        await cleanup.value
        closing = nil
    }

    private func current() throws -> (NSRunningApplication, EngineRuntime, SeatTarget) {
        guard let application = runningApplication, !application.isTerminated, let runtime, let target else {
            throw AutomationFailure("No live application session. Use windows and open_session, then observe.")
        }
        return (application, runtime, target)
    }
}
