import BrowserCore
import Foundation

extension ChromeBrowser {
    /// Reads bounded article text from the main document. Frames and media without text are omitted.
    public func readContent(tab: String) async throws -> BrowserContentPage {
        try begin()
        defer { busy = false }
        let session = try await attach(tab)
        let before = try await document(session)
        guard await connection?.currentDialog(sessionID: session) == nil else {
            throw BrowserFailure(.unavailable, "A JavaScript dialog blocks article reading.")
        }
        let response = try await command("Runtime.evaluate", ["expression": .string(Self.articleScript),
            "returnByValue": .bool(true), "awaitPromise": .bool(false)], session: session)
        guard response["exceptionDetails"] == .null,
              let rows = response["result"]["value"]["items"].array else { throw malformed("article reading") }
        guard try await document(session) == before else {
            throw BrowserFailure(.staleReference, "The document navigated during article reading.")
        }
        let value = response["result"]["value"]
        var limits = ["Main-document article text only; images, videos and embedded frame content are not interpreted."]
        if value["truncated"].bool == true { limits.append("Only the first 100 rendered articles were inspected.") }
        return BrowserContentPage(
            document: (before["frame"]["id"].string ?? "") + ":" + (before["frame"]["loaderId"].string ?? ""),
            url: value["url"].string ?? "",
            items: rows.compactMap { row in
                guard let text = row["text"].string else { return nil }
                return BrowserContentItem(identity: row["identity"].string, text: text,
                                          url: row["url"].string, truncated: row["truncated"].bool == true)
            },
            scrollY: value["scrollY"].number ?? 0, atEnd: value["atEnd"].bool == true, limitations: limits
        )
    }

    /// Scrolls the main document with renderer focus emulation, without selecting the browser tab.
    /// This sends no wheel event; collectors must read the resulting document and stop on no progress.
    public func advanceContent(tab: String, by pixels: Double) async throws -> BrowserReceipt {
        try begin()
        defer { busy = false }
        guard pixels.isFinite, pixels != 0, abs(pixels) <= 4000 else {
            throw BrowserFailure(.invalidArgument, "Document scroll requires a finite nonzero offset of at most 4000 CSS pixels.")
        }
        let session = try await attach(tab)
        guard await connection?.currentDialog(sessionID: session) == nil else {
            throw BrowserFailure(.unavailable, "A JavaScript dialog blocks document scrolling.")
        }
        try await prepareInput(session)
        observations.removeValue(forKey: tab)
        do {
            let response = try await command("Runtime.evaluate", [
                "expression": .string("(() => { const root = document.scrollingElement; if (!root) return false; root.scrollBy({top: \(pixels), behavior: 'instant'}); return true; })()"),
                "returnByValue": .bool(true), "awaitPromise": .bool(false)
            ], session: session)
            guard response["exceptionDetails"] == .null, response["result"]["value"].bool == true else {
                throw BrowserFailure(.unavailable, "The main document could not be scrolled.", effectsPossible: true)
            }
            return BrowserReceipt(.delivered, "Main-document scroll requested without a wheel event. Read article content to verify progress.")
        } catch {
            let failure = error as? BrowserFailure
            throw BrowserFailure(failure?.code ?? .transport, String(describing: error), effectsPossible: true)
        }
    }

    private static let articleScript = #"""
    (() => {
      const roots = [...document.querySelectorAll('article,[role="article"]')].filter(a =>
        !a.parentElement?.closest('article,[role="article"]') && a.getClientRects().length &&
        getComputedStyle(a).visibility !== 'hidden' && !a.closest('[hidden],[aria-hidden="true"]'));
      const items = roots.slice(0, 100).map(a => {
        const link = a.querySelector('a[rel~="bookmark"][href],a[href]:has(time)');
        const href = link && /^https?:/.test(link.href) ? link.href : null;
        const identity = href ? 'url:' + href : a.id ? 'id:' + a.id : null;
        const text = a.innerText.trim();
        return {identity, url:href, text:text.slice(0,6000), truncated:text.length>6000};
      });
      const root = document.scrollingElement;
      return {items, url:location.href, scrollY:root?.scrollTop || 0,
        atEnd:!!root && root.scrollTop+root.clientHeight>=root.scrollHeight-2, truncated:roots.length>100};
    })()
    """#
}
