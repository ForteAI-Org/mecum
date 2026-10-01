import AccessibilityActions
import AppKit
import Engine
import EngineCore
import Foundation
import PerceptionCore
import PrivateSymbols
import SeatCore
import WindowServerListing

/// RecentDocumentRuntime composes startup menu delivery for a running app under the caller's ownership.
/// It never launches, activates or quits an application. The caller retains ownership through adoption.
@MainActor
public enum RecentDocumentRuntime {
    public static func catalog(application: String) throws -> MenuCatalog {
        let running = try RunningApplicationLookup.running(application)
        return try AccessibilityMenuController().catalog(processID: running.processIdentifier)
    }

    public static func open(application: String, path: [String],
                            validateOwnership: @escaping @MainActor () throws -> Void,
                            adopt: @escaping @MainActor (String) async throws -> SceneSnapshot) async -> ActOutcome {
        do {
            let running = try RunningApplicationLookup.running(application)
            guard let bundleID = running.bundleIdentifier else { throw MenuFailure("Application identity unavailable.") }
            if let missing = Permissions.firstMissing(of: [.screenRecording, .accessibility, .postEvent]) {
                throw MenuFailure("Missing macOS permission: \(missing). No command was delivered.")
            }
            let menus = StartupMenus(application: running, validateOwnership: validateOwnership)
            return await RecentDocumentOpening(menus: menus, windows: WindowServerWindowListing())
                .perform(path: path, processID: running.processIdentifier, bundleID: bundleID) { title in
                    try menus.validate(running.processIdentifier)
                    let scene = try await adopt(title)
                    try menus.validate(running.processIdentifier)
                    return scene
                }
        } catch { return ActOutcome(.refused, String(describing: error)) }
    }

    /// Rejects a collapsed/helper capture as the first usable scene, even if adoption itself succeeded.
    public static func validateOpening(_ scene: SceneSnapshot) throws {
        guard scene.viewportPixelSize.width >= 120, scene.viewportPixelSize.height >= 120 else {
            throw MenuFailure("The application exposed only a tiny or collapsed window. No usable session was opened. "
                              + "For a recent document, read menus with app and use open_recent.")
        }
    }
}

@MainActor
private final class StartupMenus: ApplicationMenuOperating {
    let application: NSRunningApplication
    let validateOwnership: @MainActor () throws -> Void
    let native = AccessibilityMenuController()

    init(application: NSRunningApplication, validateOwnership: @escaping @MainActor () throws -> Void) {
        self.application = application
        self.validateOwnership = validateOwnership
    }

    func catalog(processID: pid_t) throws -> MenuCatalog {
        try validate(processID)
        return try native.catalog(processID: processID)
    }

    func invoke(path: [String], processID: pid_t) async throws -> MenuDelivery {
        try native.openRecent(path: path, processID: processID) { try self.validate(processID) }
    }

    func validate(_ pid: pid_t) throws {
        try Task.checkCancellation()
        guard !application.isTerminated, application.processIdentifier == pid,
              NSRunningApplication(processIdentifier: pid)?.launchDate == application.launchDate else {
            throw MenuFailure("The application process changed before document opening.")
        }
        try validateOwnership()
    }
}
