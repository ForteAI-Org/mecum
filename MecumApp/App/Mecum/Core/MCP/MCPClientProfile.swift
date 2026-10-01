import Foundation

/// MCPClientProfile records a person's local grant. Credentials are generated separately each launch.
struct MCPClientProfile: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let desktop: Bool
    let browser: Bool
    let watcher: Bool
    let sharedMemory: Bool
    var enabled: Bool

    init(id: UUID = UUID(), name: String, desktop: Bool = true, browser: Bool = true,
         watcher: Bool = false, sharedMemory: Bool = false, enabled: Bool = false) {
        self.id = id
        self.name = name
        self.desktop = desktop
        self.browser = browser
        self.watcher = watcher
        self.sharedMemory = sharedMemory
        self.enabled = enabled
    }

    func allows(_ tool: String) -> Bool {
        if tool.hasPrefix("browser_") { return browser }
        if tool.hasPrefix("watch_") { return watcher }
        if tool == "memory_recall" { return sharedMemory }
        if tool == "task_begin" || tool == "task_end" { return true }
        return desktop
    }
}
