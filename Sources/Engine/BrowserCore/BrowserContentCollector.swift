import Foundation

/// BrowserContentCollection preserves collected text even when a later scroll or reading fails.
/// countReached counts observed article identities; it does not establish complete content or semantic uniqueness.
public struct BrowserContentCollection: Sendable, Codable {
    public let items: [BrowserContentItem]
    public let scrolls: Int
    public let stopReason: String
    public let limitations: [String]
}

/// BrowserContentCollector performs bounded reading and scrolling without consulting a model per step.
/// It owns no browser, never replays a failed input and stops on navigation, cancellation or uncertainty.
public struct BrowserContentCollector: Sendable {
    private let browser: any BrowserControlling
    private let pause: @Sendable (Duration) async throws -> Void

    public init(browser: any BrowserControlling,
                pause: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.browser = browser
        self.pause = pause
    }

    /// Collects up to 50 articles and 64 KiB of text, with at most 20 scrolls of 800 CSS pixels.
    /// Each scroll may poll its result three times; those reads never repeat the scroll itself.
    public func collect(tab: String, count: Int, maxScrolls: Int) async throws -> BrowserContentCollection {
        guard (1...50).contains(count), (0...20).contains(maxScrolls) else {
            throw BrowserFailure(.invalidArgument, "count must be 1...50 and maxScrolls 0...20.")
        }
        var items: [BrowserContentItem] = []
        var seen = Set<String>()
        var limitations: [String] = []
        var scrolls = 0
        var document: String?
        var url: String?
        var previous: BrowserContentPage?
        var bytes = 0
        func finish(_ reason: String) -> BrowserContentCollection {
            BrowserContentCollection(items: items, scrolls: scrolls, stopReason: reason,
                                     limitations: Array(Set(limitations)).sorted())
        }
        do {
            while true {
                try Task.checkCancellation()
                var page = try await browser.readContent(tab: tab)
                if let previous {
                    for attempt in 1...3 where page.scrollY == previous.scrollY && page.items == previous.items {
                        try await pause(.milliseconds(150 * attempt))
                        page = try await browser.readContent(tab: tab)
                        if page.document != previous.document || page.url != previous.url { break }
                    }
                }
                if let document, page.document != document || page.url != url {
                    limitations.append("The document or URL changed. Collected text belongs to the preceding page.")
                    return finish("navigation")
                }
                document = page.document
                url = page.url
                limitations += page.limitations
                for item in page.items {
                    guard !item.text.isEmpty else { continue }
                    let key = item.identity.map { "id:" + $0 } ?? "text:" + item.text
                    guard seen.insert(key).inserted else { continue }
                    guard bytes + item.text.utf8.count <= 65_536 else {
                        limitations.append("Stopped at 64 KiB of collected text.")
                        return finish("textLimit")
                    }
                    items.append(item)
                    bytes += item.text.utf8.count
                    if item.truncated { limitations.append("Some article text is incomplete.") }
                    if item.identity == nil {
                        limitations.append("Some articles have no permalink or HTML id; text matching cannot prove distinctness.")
                    }
                    if items.count == count {
                        return finish(items.allSatisfy { $0.identity != nil } ? "countReached" : "identityUncertain")
                    }
                }
                if let previous, page.scrollY == previous.scrollY && page.items == previous.items {
                    limitations.append("No more progress was observed. This does not establish feed completeness; inactive tabs may defer loading.")
                    return finish(page.atEnd ? "endOfPage" : "noProgress")
                }
                guard scrolls < maxScrolls else { return finish("scrollLimit") }
                guard !page.items.isEmpty else { return finish("noArticles") }
                previous = page
                try Task.checkCancellation()
                scrolls += 1
                let receipt = try await browser.advanceContent(tab: tab, by: 800)
                guard receipt.status != .unverified else {
                    limitations.append(receipt.detail)
                    return finish("unverifiedScroll")
                }
                try await pause(.milliseconds(150))
            }
        } catch {
            limitations.append("Stopped without replaying input: \(error)")
            return finish(error is CancellationError ? "cancelled" : "error")
        }
    }
}
