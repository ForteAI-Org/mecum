import BrowserCore
import BrowserMCP
import LocalMCP
import Testing

@MainActor
struct BrowserObservationTests {
    @Test func actionReturnsFreshObservationWithoutAnotherModelCall() async throws {
        let browser = SyntheticBrowser()
        let tools = BrowserTools(browser: browser)
        let arguments = JSONValue.object(try await browserTestContext(tools))
        let result = try await tools.call("browser_click", arguments)["structuredContent"]
        #expect(result["status"].string == "verified")
        #expect(result["observation"]["nodes"].array?.first?["name"].string == "Done")
        #expect(await browser.actions == 1)
        #expect(await browser.snapshots == 2)
    }

    @Test func failedObservationPreservesSuccessfulActionAndNeverReplaysIt() async throws {
        let browser = SyntheticBrowser()
        let tools = BrowserTools(browser: browser)
        let arguments = JSONValue.object(try await browserTestContext(tools))
        await browser.failSnapshot(true)
        let result = try await tools.call("browser_click", arguments)["structuredContent"]
        #expect(result["status"].string == "verified")
        #expect(result["observation"] == .null)
        #expect(result["observationError"].string?.contains("Synthetic observation failure") == true)
        #expect(await browser.actions == 1)
    }

    @Test func failedActionIsNotRetriedOrTurnedIntoAnObservationSuccess() async throws {
        let browser = SyntheticBrowser()
        await browser.failAction(true)
        let tools = BrowserTools(browser: browser)
        let arguments = JSONValue.object(try await browserTestContext(tools))
        await #expect(throws: BrowserFailure.self) {
            _ = try await tools.call("browser_click", arguments)
        }
        #expect(await browser.actions == 1)
        #expect(await browser.snapshots == 1)
    }

    @Test func invalidObservationOptionsRejectBeforeAction() async throws {
        let browser = SyntheticBrowser()
        let tools = BrowserTools(browser: browser)
        let arguments = JSONValue.object(try await browserTestContext(tools))
        var values = arguments.object ?? [:]
        values["observation"] = .object(["limit": .number(0)])
        await #expect(throws: BrowserFailure.self) {
            _ = try await tools.call("browser_click", .object(values))
        }
        #expect(await browser.actions == 0)
    }
}
