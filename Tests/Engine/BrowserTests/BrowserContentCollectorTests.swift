import BrowserCore
import Testing

struct BrowserContentCollectorTests {
    private func page(_ ids: [String], y: Double = 0, document: String = "doc") -> BrowserContentPage {
        BrowserContentPage(document: document, url: "https://example.invalid/feed", items: ids.map {
            BrowserContentItem(identity: $0, text: "Article " + $0, url: nil, truncated: false)
        }, scrollY: y, atEnd: false)
    }

    @Test func collectsAndDeduplicatesAcrossScrolls() async throws {
        let browser = SyntheticBrowser()
        await browser.setPages([page(["a", "b"]), page(["b", "c"], y: 800)])
        let result = try await BrowserContentCollector(browser: browser, pause: { _ in }).collect(tab: "tab", count: 3, maxScrolls: 2)
        #expect(result.stopReason == "countReached")
        #expect(result.items.map(\.identity) == ["a", "b", "c"])
        #expect(await browser.actions == 1)
    }

    @Test func failureKeepsCollectedTextAndDoesNotReplayScroll() async throws {
        let browser = SyntheticBrowser()
        await browser.setPages([page(["a"])])
        await browser.failAction(true)
        let result = try await BrowserContentCollector(browser: browser, pause: { _ in }).collect(tab: "tab", count: 2, maxScrolls: 3)
        #expect(result.stopReason == "error")
        #expect(result.items.count == 1)
        #expect(await browser.actions == 1)
    }

    @Test func navigationStopsWithoutCombiningDifferentPages() async throws {
        let browser = SyntheticBrowser()
        await browser.setPages([page(["a"]), page(["b"], document: "other")])
        let result = try await BrowserContentCollector(browser: browser, pause: { _ in }).collect(tab: "tab", count: 2, maxScrolls: 3)
        #expect(result.stopReason == "navigation")
        #expect(result.items.map(\.identity) == ["a"])
        #expect(await browser.actions == 1)
    }

    @Test func stalledPageUsesBoundedReadsAndOnlyOneScroll() async throws {
        let browser = SyntheticBrowser()
        await browser.setPages([page(["a"])])
        let result = try await BrowserContentCollector(browser: browser, pause: { _ in }).collect(tab: "tab", count: 2, maxScrolls: 20)
        #expect(result.stopReason == "noProgress")
        #expect(await browser.readings == 5)
        #expect(await browser.actions == 1)
    }

    @Test func unidentifiableArticlesNeverClaimTheRequestedDistinctCount() async throws {
        let browser = SyntheticBrowser()
        await browser.setPages([BrowserContentPage(document: "doc", url: "about:blank", items: [
            BrowserContentItem(identity: nil, text: "Text only", url: nil, truncated: true)
        ], scrollY: 0, atEnd: true)])
        let result = try await BrowserContentCollector(browser: browser, pause: { _ in }).collect(tab: "tab", count: 1, maxScrolls: 0)
        #expect(result.stopReason == "identityUncertain")
        #expect(result.limitations.count == 2)
        #expect(await browser.actions == 0)
    }

    @Test func poolForwardsContentUnderItsLease() async throws {
        let browser = SyntheticBrowser()
        await browser.setPages([page(["a"])])
        let client = BrowserSessionPool(makeBrowser: { browser }).client()
        await #expect(throws: BrowserFailure.self) { _ = try await client.readContent(tab: "tab") }
        _ = try await client.connect(profile: .automation)
        #expect(try await client.readContent(tab: "tab").items.count == 1)
        try await client.disconnect()
    }
    @Test func invalidBudgetsNeverReadOrScroll() async throws {
        let browser = SyntheticBrowser()
        for (count, scrolls) in [(0, 1), (51, 1), (1, -1), (1, 21)] {
            await #expect(throws: BrowserFailure.self) {
                _ = try await BrowserContentCollector(browser: browser).collect(tab: "tab", count: count, maxScrolls: scrolls)
            }
        }
        #expect(await browser.readings == 0)
        #expect(await browser.actions == 0)
    }

    @Test func cancellationAfterScrollPreservesTextAndDoesNotReplay() async throws {
        let browser = SyntheticBrowser()
        await browser.setPages([page(["a"])])
        let result = try await BrowserContentCollector(browser: browser, pause: { _ in throw CancellationError() })
            .collect(tab: "tab", count: 3, maxScrolls: 10)
        #expect(result.stopReason == "cancelled")
        #expect(result.items.map(\.identity) == ["a"])
        #expect(await browser.actions == 1)
    }

    @Test func textBudgetPreservesOnlyCompleteItemsWithinTheLimit() async throws {
        let browser = SyntheticBrowser()
        await browser.setPages([BrowserContentPage(document: "doc", url: "about:blank", items: (0..<20).map {
            BrowserContentItem(identity: String($0), text: String(repeating: "a", count: 6000), url: nil, truncated: false)
        }, scrollY: 0, atEnd: false)])
        let result = try await BrowserContentCollector(browser: browser, pause: { _ in })
            .collect(tab: "tab", count: 20, maxScrolls: 10)
        #expect(result.stopReason == "textLimit")
        #expect(result.items.count == 10)
        #expect(await browser.actions == 0)
    }

}
