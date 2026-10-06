import AppKit
import EngineCore
import Foundation
import PerceptionCore
import WindowServerListing

/// AutomationSessionOperating is the application-session boundary consumed by tool adapters.
/// Calls are serialized by the owner. close follows cancellation/draining and invalidates the session ID.
@MainActor
public protocol AutomationSessionOperating: AnyObject {
    var id: UUID? { get }
    func open(application: String, window: String?) async throws -> SceneSnapshot
    func observe() async throws -> SceneSnapshot
    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome
    func select(control: String, item: String) async throws -> ActOutcome
    /// Types, presses a key, scrolls, drags or chooses a contextual menu item, resolved and verified.
    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome
    /// Lists or presses an item of the held application's menu bar by a path such as "File > Close".
    func menu(path: String) async throws -> ActOutcome
    /// Presses a button of the held application's dialog or alert in front, by its title.
    func press(button: String) async throws -> ActOutcome
    func close() async
    /// Any work left after the latest completed close, such as an application deferring its quit.
    var closeWarning: String? { get }
    /// What the latest scene went ahead without: other windows of the application it does not
    /// show, such as one left on the person's screen, in one sentence; nil when there are none.
    var seatNotice: String? { get }
    /// The applications `open` can open that `query` names, best first, or all of them when it is nil.
    /// Read-only: it needs no open session and opens nothing.
    func applications(matching query: String?) async throws -> [ApplicationCandidate]
    /// Read-only window candidates exposed by this session's discovery policy; no adoption or input.
    func windowCandidates(ownedBy processID: pid_t) throws -> [WindowRow]
}

public extension AutomationSessionOperating {

    var closeWarning: String? { nil }

    var seatNotice: String? { nil }

    func windowCandidates(ownedBy processID: pid_t) throws -> [WindowRow] {
        try WindowServerWindowListing().windows(ownedBy: processID)
    }

    /// A session with no application to read a menu bar of.
    func menu(path: String) async throws -> ActOutcome {
        throw AutomationFailure("The menu bar is not available in this session.")
    }

    /// A session with no application whose dialog could be read.
    func press(button: String) async throws -> ActOutcome {
        throw AutomationFailure("Pressing a dialog button is not available in this session.")
    }

    /// Running regular applications only, since that is all `RunningApplicationLookup` opens. A query
    /// keeps the ones whose bundle ID or one of whose names contains it, ignoring case; the names are
    /// those `RunningApplicationLookup.running` matches, so "Calculator" keeps "Calcolatrice".
    func applications(matching query: String?) async throws -> [ApplicationCandidate] {
        let wanted  = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let browser = WebBrowsers.defaultBundleID()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { app in
                wanted.isEmpty || (app.bundleIdentifier ?? "").localizedCaseInsensitiveContains(wanted)
                    || RunningApplicationLookup.names(of: app).contains { $0.localizedCaseInsensitiveContains(wanted) }
            }
            .map { app in
                ApplicationCandidate(name: app.localizedName ?? "", bundleID: app.bundleIdentifier ?? "",
                                     version: app.bundleURL.flatMap { Bundle(url: $0) }?
                                        .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                                     isRunning: true,
                                     isDefaultBrowser: app.bundleIdentifier != nil && app.bundleIdentifier == browser)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// ApplicationCandidate is one application the apps tool offers: its name, the bundle ID to open it by,
/// its version when the bundle declares one and whether it is running. `location` is set only where it
/// tells apart two candidates that share a name. `isDefaultBrowser` marks the application that opens
/// web links by default (`WebBrowsers.defaultBundleID`), which the worker uses for anything on the web.
nonisolated public struct ApplicationCandidate: Sendable, Equatable {
    public let name: String
    public let bundleID: String
    public let version: String?
    public let isRunning: Bool
    public let location: String?
    public let isDefaultBrowser: Bool

    public init(name: String, bundleID: String, version: String?, isRunning: Bool, location: String? = nil,
                isDefaultBrowser: Bool = false) {
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.isRunning = isRunning
        self.location = location
        self.isDefaultBrowser = isDefaultBrowser
    }
}
