import AppKit
import EngineCore
import Foundation
import Memory
import PerceptionCore

/// AutomationSessionOperating is the application-session boundary consumed by tool adapters.
/// Calls are serialized by the owner. close follows cancellation/draining and invalidates the session ID.
///
/// Every call that perceives or acts takes the `ActionContext` of the call it serves: the session
/// records the call's samples and the brain's learning under that context's event, and leaves what
/// the call saw in `lastReport` for the adapter that records the call itself. A conformer that
/// records nothing (a test double) leaves the defaults.
@MainActor
public protocol AutomationSessionOperating: AnyObject {
    var id: UUID? { get }
    /// The application the open session drives, as the memory names it; nil without one.
    var application: AppContextIdentity? { get }
    /// What the last call left for its record: the effect the engine attributed and the memory's notes.
    var lastReport: CallRecorder.Report? { get }
    func open(application: String, window: String?, context: ActionContext) async throws -> SceneSnapshot
    func observe(context: ActionContext) async throws -> SceneSnapshot
    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?,
             context: ActionContext) async throws -> ActOutcome
    func select(control: String, item: String, context: ActionContext) async throws -> ActOutcome
    /// Types, presses a key, scrolls, drags or chooses a contextual menu item, resolved and verified.
    func deliver(_ input: InputRequest.Input, section: String?, context: ActionContext) async throws -> ActOutcome
    func close() async
    /// The applications `open` can open that `query` names, best first, or all of them when it is nil.
    /// Read-only: it needs no open session and opens nothing.
    func applications(matching query: String?) async throws -> [ApplicationCandidate]
}

public extension AutomationSessionOperating {

    var application: AppContextIdentity? { nil }

    var lastReport: CallRecorder.Report? { nil }

    /// Running regular applications only, since that is all `RunningApplicationLookup` opens. A query
    /// keeps the ones whose name or bundle ID contains it, ignoring case.
    func applications(matching query: String?) async throws -> [ApplicationCandidate] {
        let wanted = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { app in
                ApplicationCandidate(name: app.localizedName ?? "", bundleID: app.bundleIdentifier ?? "",
                                     version: app.bundleURL.flatMap { Bundle(url: $0) }?
                                        .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                                     isRunning: true)
            }
            .filter { wanted.isEmpty || $0.name.localizedCaseInsensitiveContains(wanted)
                || $0.bundleID.localizedCaseInsensitiveContains(wanted) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

public extension AppContextIdentity {

    /// The context of a running application as the memory names it: its bundle id (or a stand-in
    /// from its pid) and the short version its bundle declares; the locale is not read.
    init(_ application: NSRunningApplication) {
        self.init(
            bundleID: application.bundleIdentifier ?? "pid.\(application.processIdentifier)",
            version : application.bundleURL.flatMap { Bundle(url: $0) }?
                .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            locale  : nil
        )
    }
}

/// ApplicationCandidate is one application the apps tool offers: its name, the bundle ID to open it by,
/// its version when the bundle declares one and whether it is running. `location` is set only where it
/// tells apart two candidates that share a name.
nonisolated public struct ApplicationCandidate: Sendable, Equatable {
    public let name: String
    public let bundleID: String
    public let version: String?
    public let isRunning: Bool
    public let location: String?

    public init(name: String, bundleID: String, version: String?, isRunning: Bool, location: String? = nil) {
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.isRunning = isRunning
        self.location = location
    }
}
