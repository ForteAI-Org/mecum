import BrowserCore
import ChatCore
import ChromeBrowser
import Foundation
import ModelTransports
import Testing
@testable import Mecum

@MainActor
@Suite("Worker with real synthetic Chrome", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MECUM_BROWSER_APP_LIVE_TESTS"] == "1"))
struct WorkerBrowserLiveTests {
    @Test(arguments: ["button", "text", "collect"])
    func appWorkerReadsClicksVerifiesAndReleasesARealChromePage(scenario: String) async throws {
        guard let directory = ProcessInfo.processInfo.environment["MECUM_BROWSER_APP_FIXTURE"],
              directory.hasPrefix("/private/tmp/") else {
            throw NSError(domain: "BrowserProbe", code: 3, userInfo: [NSLocalizedDescriptionKey: "A synthetic fixture directory under /private/tmp is required"])
        }
        let base = URL(fileURLWithPath: directory)
        let browser = ChromeBrowser(configuration: ChromeConfiguration(
            executable: base.appendingPathComponent("chrome-headless"),
            currentProfile: base.appendingPathComponent("unused-current"),
            automationProfile: base.appendingPathComponent("profile")
        ))
        let collect = scenario == "collect"
        let transport = BrowserProbeTransport(page: base.appendingPathComponent("fixture.html"), articleCount: collect ? 5 : nil,
            targetRole: scenario == "text" ? "StaticText" : "button", targetName: scenario == "text" ? "Solo andata" : "Run",
            resultRole: scenario == "text" ? "StaticText" : "button", resultName: scenario == "text" ? "One way selected" : "Done")
        let worker = WorkerAgentHost(workingDirectory: base.appendingPathComponent("worker"),
            bridgeExecutable: URL(filePath: "/unused"), session: { DesktopUnavailableSession() },
            browser: browser, transports: { _ in transport })
        var records: [String] = []
        var reply = ""
        try await worker.run(prompt: "Use only the synthetic fixture.",
            selection: .init(provider: .ollama, model: "local-test-substitute", effort: .medium),
            sessionID: nil, role: nil) { event in
                if case .tool(let text) = event { records.append(text) }
                if case .provider(.assistant(let text)) = event { reply += text }
            }
        #expect(reply == "Synthetic Chrome interaction verified.")
        if collect {
            #expect(records.contains { $0.hasPrefix("← browser_collect") && $0.contains("countReached") })
        } else {
            #expect(records.contains { $0.hasPrefix("← browser_click") && $0.contains("delivered") })
        }
        #expect(records.filter { $0.hasPrefix("← browser_snapshot") }.count <= 1)
        #expect(records.contains { $0.hasPrefix("← browser_disconnect") })
        #expect(!records.contains { $0.hasPrefix("→ open_session") || $0.hasPrefix("→ status") })
        try await worker.close()
    }
}
