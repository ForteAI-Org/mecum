import BrowserCore
import Foundation

actor SyntheticBrowser: BrowserControlling {
    var connections = 0
    var disconnections = 0
    var actions = 0
    var shouldFailConnection = false
    var shouldFailAction = false
    var shouldFailDisconnect = false

    func failConnection(_ value: Bool) { shouldFailConnection = value }
    func failAction(_ value: Bool) { shouldFailAction = value }
    func failDisconnect(_ value: Bool) { shouldFailDisconnect = value }
    func connect(profile: BrowserProfile) async throws -> BrowserConnection {
        connections += 1
        if shouldFailConnection { throw BrowserFailure(.setupRequired, "Synthetic setup required") }
        return BrowserConnection(id: "synthetic-connection", browser: "Synthetic Chrome", profile: profile, capabilities: ["snapshot", "click"])
    }
    func disconnect() async throws {
        if shouldFailDisconnect { throw BrowserFailure(.transport, "Synthetic cleanup failure") }
        disconnections += 1
    }
    func tabs() async throws -> [BrowserTab] { [BrowserTab(id: "tab", title: "Synthetic page", url: "about:blank")] }
    func open(url: String) async throws -> BrowserTab { BrowserTab(id: "tab", title: "Synthetic page", url: url) }
    func close(tab: String) async throws {}
    func snapshot(tab: String, options: BrowserObservationOptions) async throws -> BrowserSnapshot {
        BrowserSnapshot(id: "snapshot", tab: BrowserTab(id: tab, title: "Synthetic page", url: "about:blank"),
            nodes: [BrowserNode(ref: "e1", frame: "main", role: "button", name: actions == 0 ? "Run" : "Done", value: nil, states: [:])], limitations: [])
    }
    func perform(_ action: BrowserAction, tab: String, snapshot: String?) async throws -> BrowserReceipt {
        actions += 1
        if shouldFailAction { throw BrowserFailure(.transport, "Synthetic delivery failure", effectsPossible: true) }
        return BrowserReceipt(.verified, "Synthetic effect verified")
    }
    func screenshot(tab: String) async throws -> Data { Data() }
    func dialog(tab: String) async throws -> BrowserDialog? { nil }
    func handleDialog(tab: String, accept: Bool, text: String?) async throws -> BrowserReceipt { BrowserReceipt(.delivered, "Synthetic dialog") }
}
