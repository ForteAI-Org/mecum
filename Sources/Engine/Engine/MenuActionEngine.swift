import EngineCore
import Foundation
import PerceptionCore

/// MenuActionEngine executes one explicit native path and verifies a requested newly opened window.
/// Window and menu routes never fall back into one another. Unsupported effects remain unverified.
@MainActor
public struct MenuActionEngine {
    private let menus: any ApplicationMenuOperating
    private let scenes: any SceneProviding
    private let windows: any WindowListing
    private let permissions: ActionPermissions

    public init(menus: any ApplicationMenuOperating, scenes: any SceneProviding,
                windows: any WindowListing, permissions: ActionPermissions = .init()) {
        self.menus = menus
        self.scenes = scenes
        self.windows = windows
        self.permissions = permissions
    }

    public func perform(path: [String], expectingWindow: String, processID: pid_t) async -> ActOutcome {
        guard (2...8).contains(path.count), path.allSatisfy({ !MenuCatalog.key($0).isEmpty }), !expectingWindow.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ActOutcome(.refused, "Provide a full menu path and the exact expected new window title.")
        }
        guard permissions.allowsDestructive || !ActionPolicy.isDestructive(menuPath: path) else {
            return ActOutcome(.refused, "The requested menu path is destructive and has not been authorized.")
        }
        var delivered = false
        var evidence: MenuEvidence?
        do {
            let source = try await scenes.currentScene(of: processID)
            guard let before = try windows.allWindows(ownedBy: processID),
                  !before.contains(where: { $0.title == expectingWindow }) else {
                return ActOutcome(.refused, "The expected window already exists or the complete inventory is unavailable.",
                                  scene: source.scene)
            }
            let result = try await menus.invoke(path: path, processID: processID)
            delivered = true
            evidence = MenuEvidence(bundleID: source.scene.bundleID, windowTitle: source.scene.windowTitle,
                                    path: path, expectedWindow: expectingWindow, effect: .unverified)
            if case .uncertain(let reason) = result {
                return ActOutcome(.actedUnverified, reason + " Observe before doing anything else.", evidence: evidence.map(ActEvidence.menu))
            }
            // Allow the Seat to adopt a newly born dialog before capturing it; never resend the command.
            try await Task.sleep(for: .milliseconds(350))
            guard let first = try windows.allWindows(ownedBy: processID) else {
                return ActOutcome(.actedUnverified, "Menu requested; complete readback unavailable. Do not replay.", evidence: evidence.map(ActEvidence.menu))
            }
            let after = try await scenes.currentScene(of: processID)
            let second = try windows.allWindows(ownedBy: processID)
            guard Self.openedWindow(expectingWindow, before: before, first: first, second: second,
                                   after: after, source: source) else {
                return ActOutcome(.actedUnverified, "Menu requested, but opening '\(expectingWindow)' was not verified. Do not replay.",
                                  scene: after.scene, evidence: evidence.map(ActEvidence.menu))
            }
            return ActOutcome(.foundActed, "Menu '\(path.joined(separator: " > "))' opened '\(expectingWindow)' "
                              + "(verified in two complete inventories and the captured scene).", scene: after.scene,
                              evidence: .menu(MenuEvidence(bundleID: source.scene.bundleID,
                                  windowTitle: source.scene.windowTitle, path: path, expectedWindow: expectingWindow,
                                  effect: .openedWindow)))
        } catch {
            return ActOutcome(delivered ? .actedUnverified : .refused,
                              "\(error)" + (delivered ? " The command may have happened; do not replay." : ""), evidence: evidence.map(ActEvidence.menu))
        }
    }

    nonisolated static func openedWindow(_ title: String, before: [WindowRow], first: [WindowRow], second: [WindowRow]?,
                             after: PerceivedWindow, source: PerceivedWindow) -> Bool {
        guard let second, source.scene.coverage == .window, after.scene.coverage == .window,
              !source.scene.windowTitle.isEmpty, after.scene.bundleID == source.scene.bundleID, after.scene.windowTitle == title,
              !before.contains(where: { $0.title == title }) else { return false }
        for rows in [before, first, second] {
            guard Set(rows.map(\.number)).count == rows.count else { return false }
        }
        let candidates = second.filter { $0.title == title && $0.frame == after.frame && $0.number > 0 }
        guard candidates.count == 1, let opened = candidates.first,
              !before.contains(where: { $0.number == opened.number }),
              first.filter({ $0.title == title }).count == 1,
              second.filter({ $0.title == title }).count == 1,
              first.contains(where: { $0.number == opened.number && $0.title == title }) else { return false }
        let priorIDs = Set(before.map(\.number))
        let sourceMatches = before.filter { $0.title == source.scene.windowTitle && $0.frame == source.frame }
        guard sourceMatches.count == 1, let origin = sourceMatches.first,
              second.contains(where: { $0.number == origin.number && $0.title == origin.title }) else { return false }
        let newWindows = second.filter {
            !priorIDs.contains($0.number) && WindowSurfaceClassifier.isWindowLayer($0.layer)
                && WindowSurfaceClassifier.isSubstantialWindow($0.frame)
        }
        return newWindows.count == 1 && newWindows.first?.number == opened.number
    }
}
