import BrowserCore
import Foundation

actor RecordedBrowser: BrowserControlling {
    var actionCount = 0
    var disconnections = 0

    func connect(profile: BrowserProfile) async throws -> BrowserConnection {
        BrowserConnection(id: "test-connection", browser: "Synthetic", profile: profile, capabilities: [])
    }
    func disconnect() async throws { disconnections += 1 }
    func tabs() async throws -> [BrowserTab] { [] }
    func open(url: String) async throws -> BrowserTab { BrowserTab(id: "tab", title: "Synthetic", url: url) }
    func close(tab: String) async throws {}
    func snapshot(tab: String, options: BrowserObservationOptions) async throws -> BrowserSnapshot {
        BrowserSnapshot(id: "snapshot", tab: BrowserTab(id: tab, title: "Synthetic", url: "about:blank"), nodes: [], limitations: [])
    }
    func perform(_ action: BrowserAction, tab: String, snapshot: String?) async throws -> BrowserReceipt {
        actionCount += 1
        throw BrowserFailure(.transport, "Synthetic timeout after dispatch", effectsPossible: true)
    }
    func screenshot(tab: String) async throws -> Data { Data() }
    func dialog(tab: String) async throws -> BrowserDialog? { nil }
    func handleDialog(tab: String, accept: Bool, text: String?) async throws -> BrowserReceipt { BrowserReceipt(.delivered, "synthetic") }
}
