import BrowserCore
import BrowserMCP
import Foundation
import LocalMCP
import Testing

@MainActor
struct BrowserToolsTests {
    @Test func rejectsInvalidValuesBeforeAnyEffect() async throws {
        let browser = RecordedBrowser()
        let tools = BrowserTools(browser: browser)
        let common = try await browserTestContext(tools)
        for extra: [String: JSONValue] in [["count": .number(1.5)], ["button": .string("middle")],
            ["count": .number(999999)], ["unknown": .bool(true)]] {
            await #expect(throws: BrowserFailure.self) {
                _ = try await tools.call("browser_click", .object(common.merging(extra, uniquingKeysWith: { $1 })))
            }
        }
        await #expect(throws: BrowserFailure.self) {
            _ = try await tools.call("browser_fill", .object(common.merging(["text": .number(4)], uniquingKeysWith: { $1 })))
        }
        #expect(await browser.actionCount == 0)
    }

    @Test func scopesCallsToCurrentConnectionAndClearsItOnDisconnect() async throws {
        let browser = RecordedBrowser()
        let tools = BrowserTools(browser: browser)
        await #expect(throws: BrowserFailure.self) { _ = try await tools.call("browser_tabs", .object(["connection": .string("old")])) }
        let arguments = try await browserTestContext(tools)
        await #expect(throws: BrowserFailure.self) { _ = try await tools.call("browser_tabs", .object(["connection": .string("old")])) }
        _ = try await tools.call("browser_disconnect", .object(["connection": arguments["connection"] ?? .null]))
        await #expect(throws: BrowserFailure.self) { _ = try await tools.call("browser_tabs", .object(["connection": arguments["connection"] ?? .null])) }
        #expect(await browser.disconnections == 1)
    }

    @Test func failedDeliveryIsNeverReplayedAndKeepsEffectsPossible() async throws {
        let browser = RecordedBrowser()
        let tools = BrowserTools(browser: browser)
        let arguments = try await browserTestContext(tools)
        do {
            _ = try await tools.call("browser_click", .object(arguments))
            Issue.record("Expected a transport failure")
        } catch let error as BrowserFailure { #expect(error.effectsPossible) }
        #expect(await browser.actionCount == 1)
    }

    @Test func emptyTextIsAValidClearRequest() async throws {
        let browser = RecordedBrowser()
        let tools = BrowserTools(browser: browser)
        let arguments = try await browserTestContext(tools)
        do {
            _ = try await tools.call("browser_fill", .object(arguments.merging(["text": .string("")], uniquingKeysWith: { $1 })))
        } catch let error as BrowserFailure { #expect(error.code == .transport) }
        #expect(await browser.actionCount == 1)
    }
}
