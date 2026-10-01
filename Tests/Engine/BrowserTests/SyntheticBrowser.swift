import BrowserCore
import Foundation

actor SyntheticBrowser: BrowserControlling {
    var connections = 0
    var disconnections = 0
    var actions = 0
    var snapshots = 0
    var openedTabs: [BrowserTab] = []
    var openedCount = 0
    var pages: [BrowserContentPage] = []
    var readings = 0
    func setPages(_ values: [BrowserContentPage]) { pages = values }
    func readContent(tab: String) async throws -> BrowserContentPage {
        guard !pages.isEmpty else { throw BrowserFailure(.unavailable, "No synthetic content") }
        let index = min(readings, pages.count - 1)
        readings += 1
        return pages[index]
    }
    func advanceContent(tab: String, by pixels: Double) async throws -> BrowserReceipt {
        try await perform(.scroll(ref: nil, dx: 0, dy: pixels), tab: tab, snapshot: nil)
    }
    var shouldFailSnapshot = false
    func failSnapshot(_ value: Bool) { shouldFailSnapshot = value }
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
    func tabs() async throws -> [BrowserTab] { openedTabs }
    func open(url: String) async throws -> BrowserTab {
        openedCount += 1
        let tab = BrowserTab(id: "native-tab-\(openedCount)", title: "Synthetic page", url: url)
        openedTabs.append(tab)
        return tab
    }
    func close(tab: String) async throws { openedTabs.removeAll { $0.id == tab } }
    func snapshot(tab: String, options: BrowserObservationOptions) async throws -> BrowserSnapshot {
        snapshots += 1
        if shouldFailSnapshot { throw BrowserFailure(.unavailable, "Synthetic observation failure") }
        return BrowserSnapshot(id: "snapshot", tab: BrowserTab(id: tab, title: "Synthetic page", url: "about:blank"),
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
