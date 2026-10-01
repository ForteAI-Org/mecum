import BrowserCore
import ChromeBrowser
import Foundation
import ModelTransports
import Testing
@testable import Mecum

/// Exercises the app's real provider, MCP bridge and Chrome against an owned synthetic form.
@MainActor
@Suite("Browser journey through a signed-in provider", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MECUM_BROWSER_PROVIDER_LIVE_TESTS"] == "1"))
struct WorkerBrowserProviderLiveTests {
    @Test(.timeLimit(.minutes(5)))
    func providerCompletesTheFormAndTheBrowserConfirmsEveryRequestedValue() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["MECUM_BROWSER_APP_FIXTURE"])
        try #require(directory.hasPrefix("/private/tmp/"))
        let base = URL(fileURLWithPath: directory)
        let page = base.appendingPathComponent("journey.html")
        let bridge = try #require(ProcessInfo.processInfo.environment["MECUM_TEST_BRIDGE"])
        let browser = ChromeBrowser(configuration: ChromeConfiguration(
            executable: base.appendingPathComponent("chrome-headless"),
            currentProfile: base.appendingPathComponent("unused-current"),
            automationProfile: base.appendingPathComponent("provider-profile-\(UUID().uuidString)")))
        let host = WorkerAgentHost(workingDirectory: base.appendingPathComponent("provider-worker"),
            bridgeExecutable: URL(fileURLWithPath: bridge), session: { DesktopUnavailableSession() }, browser: browser)
        var records: [String] = []
        let began = ContinuousClock.now
        do {
            try await host.run(prompt: """
                This is an authorized synthetic browser integration test. Use only Mecum browser_* tools.
                Connect profile automation and open \(page.absoluteString).
                On this invented journey form choose Southhaven (SHV) as destination, one way (Solo andata),
                tomorrow evening and 3 adults. Click Search synthetic trips once and read the confirmation.
                Leave the tab open and connected for the test harness to inspect. Do not use other apps,
                the shell, files or websites. Use the returned observations and exact short IDs.
                """, selection: .init(provider: .codex, model: "gpt-5.6-luna", effort: .low), sessionID: nil,
                role: "Use only the supplied Mecum browser tools on the synthetic automation profile.") { event in
                    if case .tool(let text) = event { records.append(text) }
                }
            let tabs = try await browser.tabs().filter { $0.url == page.absoluteString }
            try #require(tabs.count == 1)
            let tab = try #require(tabs.first)
            let result = try await browser.snapshot(tab: tab.id, options: .init(scope: .page, limit: 400))
            #expect(result.nodes.contains { $0.name == "Trip confirmed: Northport to Southhaven, one way, tomorrow evening, 3 adults." })
            #expect(result.nodes.contains { $0.name == "Search submissions: 1" })
            #expect(records.contains { $0.hasPrefix("← browser_click") && $0.contains("delivered") })
            let errors = records.filter { $0.contains(" error:") }
            // Preflight refusals can be recovered by the model; transport and protocol failures cannot pass.
            let refusals = ["invalidArgument:", "staleReference:",
                "unavailable: Expected an enabled HTML select"]
            #expect(errors.allSatisfy { error in refusals.contains { error.contains($0) } },
                    "Unexpected tool failures: \(errors)")
            if !errors.isEmpty { print("Recovered preflight refusals:", errors) }
            print("Synthetic provider journey:", ContinuousClock.now - began,
                  "calls:", records.filter { $0.hasPrefix("→ ") }.count)
            try await browser.close(tab: tab.id)
            try await host.close()
        } catch {
            print("Synthetic provider journey failed; tool records:", records)
            try? await host.close()
            throw error
        }
    }
}
