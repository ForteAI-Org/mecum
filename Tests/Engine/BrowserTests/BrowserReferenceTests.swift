import BrowserCore
import BrowserMCP
import LocalMCP
import Testing

@MainActor
struct BrowserReferenceTests {
    @Test func shortReferencesAreStableAndNeverExposeAdapterIDs() async throws {
        let tools = BrowserTools(browser: SyntheticBrowser())
        let connection = try await tools.call("browser_connect", .object(["profile": .string("automation")]))["structuredContent"]
        let id = try #require(connection["id"].string)
        #expect(id.hasPrefix("c") && id.count <= 16)
        #expect(id != "synthetic-connection")
        let opened = try await tools.call("browser_open", .object(["connection": .string(id), "url": .string("about:blank")]))["structuredContent"]
        #expect(opened["id"].string == "t1")
        #expect(opened["observation"]["tab"]["id"] == opened["id"])
        #expect(opened["observation"]["id"].string == "s1")
        let tabs = try await tools.call("browser_tabs", .object(["connection": .string(id)]))["structuredContent"]
        #expect(tabs["tabs"].array?.first?["id"] == opened["id"])
        let repeated = try await tools.call("browser_connect", .object(["profile": .string("automation")]))["structuredContent"]
        #expect(repeated["id"] == connection["id"])
    }

    @Test func staleOrMistypedReferencesCannotDispatchAnAction() async throws {
        let browser = SyntheticBrowser()
        let tools = BrowserTools(browser: browser)
        let connection = try await tools.call("browser_connect", .object(["profile": .string("automation")]))["structuredContent"]["id"]
        let opened = try await tools.call("browser_open", .object(["connection": connection, "url": .string("about:blank")]))["structuredContent"]
        let args: [String: JSONValue] = ["connection": connection, "tab": opened["id"], "snapshot": opened["observation"]["id"], "ref": .string("e1")]
        for (key, bad) in [("connection", "c-mistyped"), ("tab", "t999"), ("snapshot", "s999")] {
            var request = args; request[key] = .string(bad)
            await #expect(throws: BrowserFailure.self) { _ = try await tools.call("browser_click", .object(request)) }
        }
        #expect(await browser.actions == 0)
        _ = try await tools.call("browser_click", .object(args))
        await #expect(throws: BrowserFailure.self) { _ = try await tools.call("browser_click", .object(args)) }
        #expect(await browser.actions == 1)
        _ = try await tools.call("browser_disconnect", .object(["connection": connection]))
        let next = try await tools.call("browser_connect", .object(["profile": .string("automation")]))["structuredContent"]["id"]
        #expect(next != connection)
        var stale = args; stale["connection"] = next
        await #expect(throws: BrowserFailure.self) { _ = try await tools.call("browser_click", .object(stale)) }
        #expect(await browser.actions == 1)
    }
    @Test func observationsCannotCrossTabsAndClosedTabsAreNotReused() async throws {
        let browser = SyntheticBrowser()
        let tools = BrowserTools(browser: browser)
        let first = try await browserTestContext(tools)
        let opened = try await tools.call("browser_open", .object([
            "connection": first["connection"] ?? .null, "url": .string("about:blank")]))["structuredContent"]
        var cross = first; cross["tab"] = opened["id"]
        await #expect(throws: BrowserFailure.self) { _ = try await tools.call("browser_click", .object(cross)) }
        #expect(await browser.actions == 0)
        _ = try await tools.call("browser_close", .object(["connection": first["connection"] ?? .null, "tab": first["tab"] ?? .null]))
        let third = try await tools.call("browser_open", .object([
            "connection": first["connection"] ?? .null, "url": .string("about:blank")]))["structuredContent"]
        #expect(third["id"] != first["tab"])
        await #expect(throws: BrowserFailure.self) { _ = try await tools.call("browser_click", .object(first)) }
        #expect(await browser.actions == 0)
    }

    @Test func failedReadingAndFailedActionBothInvalidateOldReferences() async throws {
        let browser = SyntheticBrowser()
        let tools = BrowserTools(browser: browser)
        let first = try await browserTestContext(tools)
        await browser.failSnapshot(true)
        _ = try? await tools.call("browser_snapshot", .object(["connection": first["connection"] ?? .null, "tab": first["tab"] ?? .null]))
        await #expect(throws: BrowserFailure.self) { _ = try await tools.call("browser_click", .object(first)) }
        #expect(await browser.actions == 0)
        await browser.failSnapshot(false)
        let reading = try await tools.call("browser_snapshot", .object(["connection": first["connection"] ?? .null, "tab": first["tab"] ?? .null]))["structuredContent"]
        var fresh = first; fresh["snapshot"] = reading["id"]
        await browser.failAction(true)
        await #expect(throws: BrowserFailure.self) { _ = try await tools.call("browser_click", .object(fresh)) }
        await #expect(throws: BrowserFailure.self) { _ = try await tools.call("browser_click", .object(fresh)) }
        #expect(await browser.actions == 1)
    }

}
