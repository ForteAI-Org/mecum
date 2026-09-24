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
/// Every action captures again through the same EngineRuntime used by ordinary terminal commands.
/// Every scene it already holds, observed or returned by an action, goes through one `SceneIntake`;
/// memory never causes a capture.
@MainActor
public final class AutomationSession: AutomationSessionOperating {
    private let knowledgeDirectory: URL
    private let allowsDestructive: Bool
    private let livingMemory: (any LivingMemoryStoring)?
    private var target: SeatTarget?
    private var runtime: EngineRuntime?
    private var application: NSRunningApplication?
    private var closing: Task<Void, Never>?
    public private(set) var id: UUID?

    /// - Parameter livingMemory: where sightings are recorded; owned by the composition and shared
    ///   across sessions. Nil records none.
    public init(knowledgeDirectory: URL, allowsDestructive: Bool = false,
                livingMemory: (any LivingMemoryStoring)? = nil) {
        self.knowledgeDirectory = knowledgeDirectory
        self.allowsDestructive = allowsDestructive
        self.livingMemory = livingMemory
    }

    public func open(application word: String, window title: String?) async throws -> SceneSnapshot {
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
        self.application = application
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
            runtime = EngineRuntime(knowledgeDirectory: knowledgeDirectory, seat: target)
            id = UUID()
            return try await observe()
        } catch {
            await close()
            throw error
        }
    }

    public func observe() async throws -> SceneSnapshot {
        let (application, runtime, _) = try current()
        let perceived = try await runtime.scenes.currentScene(of: application.processIdentifier)
        let learning = try await intake(runtime).learn(from: perceived.scene)
        report(learning.sightings)
        return learning.scene
    }

    public func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
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
        let outcome = await runtime.engine(allowsDestructive: allowsDestructive).act(request)
        await learnAfterAction(from: outcome.scene, runtime: runtime)
        return outcome
    }

    public func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
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
        return await runtime.engine(allowsDestructive: allowsDestructive).deliver(request)
    }

    public func select(control: String, item: String) async throws -> ActOutcome {
        let (application, runtime, target) = try current()
        let selector = SeatDropdownSelector(target: target, pipeline: ScenePipeline(text: VisionTextRecognizer()))
        let result = try await selector.select(
            control: control, item: item,
            identity: SeatDriving.ApplicationIdentity(
                bundleID: application.bundleIdentifier ?? "pid.\(application.processIdentifier)",
                name: application.localizedName ?? "application"
            ),
            permissions: ActionPermissions(allowsDestructive: allowsDestructive),
            dryRun: false
        )
        await learnAfterAction(from: result.outcome.scene, runtime: runtime)
        // A process-number fallback names this run, not the application, so it carries no evidence.
        guard application.bundleIdentifier == nil else { return result.outcome }
        return ActOutcome(result.outcome.kind, result.outcome.message, scene: result.outcome.scene)
    }

    public func close() async {
        if let closing { await closing.value; return }
        let runtime = self.runtime
        let target = self.target
        let cleanup = Task {
            await runtime?.finish()
            await target?.stop()
        }
        closing = cleanup
        self.runtime = nil
        self.target = nil
        application = nil
        id = nil
        await cleanup.value
        closing = nil
    }

    private func intake(_ runtime: EngineRuntime) -> SceneIntake {
        SceneIntake(brain: runtime.memory, livingMemory: livingMemory)
    }

    /// Learns from the scene an action returned. The action already happened, so a memory failure
    /// is reported and never turns its outcome into an error; a missing scene teaches nothing.
    private func learnAfterAction(from scene: SceneSnapshot?, runtime: EngineRuntime) async {
        do {
            guard let learning = try await intake(runtime).learn(fromOutcomeScene: scene) else { return }
            report(learning.sightings)
        } catch {
            diagnose("[memory] the brain did not learn from the action's scene: \(error)")
        }
    }

    private func report(_ sightings: SceneIntake.Sightings) {
        if case .failed(let why) = sightings { diagnose("[memory] sightings were not recorded: \(why)") }
    }

    private func diagnose(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private func current() throws -> (NSRunningApplication, EngineRuntime, SeatTarget) {
        guard let application, !application.isTerminated, let runtime, let target else {
            throw AutomationFailure("No live application session. Use windows and open_session, then observe.")
        }
        return (application, runtime, target)
    }
}
