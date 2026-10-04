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
@MainActor
public final class AutomationSession: AutomationSessionOperating {
    private let knowledgeDirectory: URL
    private let allowsDestructive: Bool
    private var target: SeatTarget?
    private var runtime: EngineRuntime?
    private var application: NSRunningApplication?
    private var closing: Task<Void, Never>?
    public private(set) var id: UUID?

    public init(knowledgeDirectory: URL, allowsDestructive: Bool = false) {
        self.knowledgeDirectory = knowledgeDirectory
        self.allowsDestructive = allowsDestructive
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
        _ = try await runtime.memory.observe(perceived.scene)
        return await runtime.memory.enrich(perceived.scene)
    }

    public func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        let (application, runtime, seat) = try current()
        if case .refuse(let sentence) = try await SeatAdmission.awaited(
            seat.agentSeat(),
            application: application.localizedName ?? "the application"
        ) {
            throw AutomationFailure(sentence)
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
        return await runtime.engine(
            allowsDestructive         : allowsDestructive,
            selectsFieldsByTripleClick: try seat.agentSeat().holdsRemoteFilePanel
        ).act(request)
    }

    public func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        let (application, runtime, seat) = try current()
        if case .refuse(let sentence) = try await SeatAdmission.awaited(
            seat.agentSeat(),
            application: application.localizedName ?? "the application"
        ) {
            throw AutomationFailure(sentence)
        }
        let request = InputRequest(
            processID: application.processIdentifier,
            bundleID: application.bundleIdentifier ?? "pid.\(application.processIdentifier)",
            appName: application.localizedName ?? "application",
            input: input, section: section
        )
        return await runtime.engine(
            allowsDestructive         : allowsDestructive,
            selectsFieldsByTripleClick: try seat.agentSeat().holdsRemoteFilePanel
        ).deliver(request)
    }

    public func menu(path: String) async throws -> ActOutcome {
        let (application, _, seat) = try current()
        if case .refuse(let sentence) = try await SeatAdmission.awaited(
            seat.agentSeat(),
            application: application.localizedName ?? "the application"
        ) {
            throw AutomationFailure(sentence)
        }
        return try await MenuBarCommand.perform(
            path,
            processID        : application.processIdentifier,
            allowsDestructive: allowsDestructive,
            observe          : { try await self.observe() }
        )
    }

    public func press(button: String) async throws -> ActOutcome {
        let (application, _, seat) = try current()
        let agentSeat = try seat.agentSeat()
        if case .refuse(let sentence) = await SeatAdmission.awaited(
            agentSeat,
            application: application.localizedName ?? "the application"
        ) {
            throw AutomationFailure(sentence)
        }
        return try await DialogButtonPress.perform(
            button,
            processID        : application.processIdentifier,
            dialogs          : agentSeat.openDialogs.map(\.windowNumber),
            allowsDestructive: allowsDestructive,
            observe          : { try await self.observe() }
        )
    }

    public func select(control: String, item: String) async throws -> ActOutcome {
        let (application, _, target) = try current()
        let selector = SeatDropdownSelector(target: target, pipeline: ProductionPerception.pipeline())
        let result = try await selector.select(
            control: control, item: item,
            identity: SeatDriving.ApplicationIdentity(
                bundleID: application.bundleIdentifier ?? "pid.\(application.processIdentifier)",
                name: application.localizedName ?? "application"
            ),
            permissions: ActionPermissions(allowsDestructive: allowsDestructive),
            dryRun: false
        )
        return result.outcome
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

    private func current() throws -> (NSRunningApplication, EngineRuntime, SeatTarget) {
        guard let application, !application.isTerminated, let runtime, let target else {
            throw AutomationFailure("No live application session. Use windows and open_session, then observe.")
        }
        return (application, runtime, target)
    }
}
