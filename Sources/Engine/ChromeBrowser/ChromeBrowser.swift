import BrowserCore
import Foundation

/// ChromeBrowser implements BrowserControlling through native Swift CDP, with one explicit connection.
/// It serializes operations by refusing overlapping calls, and never closes a borrowed browser on disconnect.
/// Current-profile mode reads only DevToolsActivePort. Automation mode reuses its own directory without cloning.
public actor ChromeBrowser: BrowserControlling {
    let configuration: ChromeConfiguration
    var connection: CDPConnection?
    var info: BrowserConnection?
    var sessions: [String: String] = [:]
    var observations: [String: Observation] = [:]
    var busy = false
    private var launched: Process?

    public init(configuration: ChromeConfiguration) { self.configuration = configuration }

    func begin() throws {
        try Task.checkCancellation()
        guard !busy else { throw BrowserFailure(.busy, "Another browser operation is in progress.") }
        busy = true
    }

    public func connect(profile: BrowserProfile) async throws -> BrowserConnection {
        try begin()
        defer { busy = false }
        if let info {
            guard info.profile == profile else {
                throw BrowserFailure(.invalidArgument, "Disconnect before choosing another browser profile.")
            }
            _ = try await command("Browser.getVersion")
            return info
        }
        if profile == .automation {
            let path = configuration.automationProfile.appendingPathComponent("DevToolsActivePort")
            if !FileManager.default.fileExists(atPath: path.path) {
                launched = try configuration.launchAutomationProfile()
                let deadline = ContinuousClock.now.advanced(by: .seconds(15))
                while !FileManager.default.fileExists(atPath: path.path), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
        }
        let endpoint = try configuration.endpoint(profile: profile)
        let transport = CDPConnection(endpoint: endpoint)
        await transport.start()
        do {
            let version = try await transport.call("Browser.getVersion", timeout: .seconds(45))
            let info = BrowserConnection(id: UUID().uuidString, browser: version["product"].string ?? "Chrome",
                profile: profile, capabilities: ["tabs", "navigate", "history", "snapshot", "content", "click", "fill",
                    "select", "set_checked", "key", "scroll", "screenshot", "javascript_dialog"])
            self.connection = transport
            self.info = info
            return info
        } catch {
            await transport.close()
            throw BrowserFailure(.setupRequired, "Could not connect to Chrome. Approve its debugging prompt, or reopen the persistent profile. \(error)")
        }
    }

    public func disconnect() async throws {
        try begin()
        defer { busy = false }
        await connection?.close()
        connection = nil
        info = nil
        sessions.removeAll()
        observations.removeAll()
    }

    func command(_ method: String, _ params: [String: CDPValue] = [:], session: String? = nil) async throws -> CDPValue {
        guard let connection else { throw BrowserFailure(.notConnected, "Use browser_connect first.") }
        return try await connection.call(method, params, sessionID: session, timeout: configuration.commandTimeout)
    }

    /// Keeps renderer input active without selecting the browser tab or changing the system focus.
    /// The override belongs to this CDP session and is released when the connection detaches.
    func prepareInput(_ session: String) async throws {
        _ = try await command("Emulation.setFocusEmulationEnabled", ["enabled": .bool(true)], session: session)
    }

    public func tabs() async throws -> [BrowserTab] {
        try begin()
        defer { busy = false }
        return try await readTabs()
    }

    func readTabs() async throws -> [BrowserTab] {
        let result = try await command("Target.getTargets")
        guard let targets = result["targetInfos"].array else { throw malformed("Target.getTargets") }
        return targets.compactMap { target in
            guard target["type"].string == "page", let id = target["targetId"].string else { return nil }
            let url = target["url"].string ?? ""
            guard Self.isPageURL(url) else { return nil }
            return BrowserTab(id: id, title: target["title"].string ?? "", url: url)
        }
    }

    public func open(url: String) async throws -> BrowserTab {
        try begin()
        defer { busy = false }
        try Self.validateURL(url)
        let result = try await command("Target.createTarget", ["url": .string(url), "background": .bool(true)])
        guard let id = result["targetId"].string else { throw malformed("Target.createTarget") }
        return BrowserTab(id: id, title: "", url: url)
    }

    public func close(tab: String) async throws {
        try begin()
        defer { busy = false }
        _ = try await target(tab)
        observations.removeValue(forKey: tab)
        let result = try await command("Target.closeTarget", ["targetId": .string(tab)])
        guard result["success"].bool == true else { throw BrowserFailure(.unavailable, "Chrome did not close that tab.") }
        sessions.removeValue(forKey: tab)
    }

    func target(_ id: String) async throws -> BrowserTab {
        guard let target = try await readTabs().first(where: { $0.id == id }) else {
            observations.removeValue(forKey: id)
            sessions.removeValue(forKey: id)
            throw BrowserFailure(.unavailable, "That page tab no longer exists. Read browser_tabs again.")
        }
        return target
    }

    func attach(_ tab: String) async throws -> String {
        _ = try await target(tab)
        if let id = sessions[tab] { return id }
        let result = try await command("Target.attachToTarget", ["targetId": .string(tab), "flatten": .bool(true)])
        guard let id = result["sessionId"].string else { throw malformed("Target.attachToTarget") }
        _ = try await command("Page.enable", session: id)
        _ = try await command("Accessibility.enable", session: id)
        sessions[tab] = id
        return id
    }

    static func isPageURL(_ text: String) -> Bool {
        text == "about:blank" || URL(string: text).map { ["http", "https", "file"].contains($0.scheme?.lowercased() ?? "") } == true
    }

    static func validateURL(_ text: String) throws {
        guard isPageURL(text), let url = URL(string: text), url.user == nil, url.password == nil,
              text == "about:blank" || url.isFileURL || url.host != nil else {
            throw BrowserFailure(.invalidArgument, "Use an absolute http, https or file URL, or about:blank. Internal and script URLs are refused.")
        }
    }

    func malformed(_ method: String) -> BrowserFailure { BrowserFailure(.protocolError, "Incomplete Chrome response to \(method).") }
}
