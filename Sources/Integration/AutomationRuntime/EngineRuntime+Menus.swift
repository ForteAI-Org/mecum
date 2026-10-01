import AppKit
import AccessibilityActions
import Engine
import EngineCore
import PerceptionCore

extension EngineRuntime {
    /// Reads current native capabilities without activating or opening a menu.
    public func menuCatalog(processID: pid_t) throws -> MenuCatalog {
        if let menus { return try menus.catalog(processID: processID) }
        return try AccessibilityMenuController().catalog(processID: processID)
    }

    public func resolveAction(_ query: String, processID: pid_t) async throws -> ActionRoute {
        let scene = try await scenes.currentScene(of: processID).scene
        return try ActionRoute(query: query, scene: scene, catalog: menuCatalog(processID: processID))
    }

    public func performMenu(path: [String], expectingWindow: String, processID: pid_t,
                            allowsDestructive: Bool = false) async -> ActOutcome {
        guard let menus else { return ActOutcome(.refused, "Menu execution requires a background Seat.") }
        return await MenuActionEngine(menus: menus, scenes: scenes, windows: windows,
                                      permissions: .init(allowsDestructive: allowsDestructive))
            .perform(path: path, expectingWindow: expectingWindow, processID: processID)
    }
}
