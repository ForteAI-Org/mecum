import BrowserCore
@testable import ChromeBrowser
import Foundation
import Testing

struct ChromeConfigurationTests {
    @Test func endpointUsesOnlyLoopbackAndValidatedBrowserPath() throws {
        let endpoint = try ChromeConfiguration.endpoint(contents: "9222\n/devtools/browser/abc-123\n")
        #expect(endpoint.absoluteString == "ws://127.0.0.1:9222/devtools/browser/abc-123")
        for text in ["0\n/devtools/browser/abc", "99999\n/devtools/browser/abc", "9222\n//remote.test/path",
                     "9222\n/devtools/browser/abc?url=http://remote.test", "9222\n/devtools/page/abc", "9222\n/devtools/browser/"] {
            #expect(throws: BrowserFailure.self) { try ChromeConfiguration.endpoint(contents: text) }
        }
    }

    @Test func documentIdentityTracksNavigationButNotVolatileFrameMetadata() {
        let frame: CDPValue = .object(["frame": .object(["id": .string("frame"), "loaderId": .string("load"),
            "url": .string("https://example.test"), "securityOrigin": .string("https://example.test")])])
        let expected: CDPValue = .object(["frame": .object(["id": .string("frame"), "loaderId": .string("load"),
            "url": .string("https://example.test")]), "childFrames": .array([])])
        #expect(ChromeBrowser.documentIdentity(frame) == expected)
    }

    @Test func refusesInternalAndScriptNavigation() throws {
        for url in ["javascript:alert(1)", "chrome://settings", "https://user:secret@example.test", "data:text/html,hello", "relative"] {
            #expect(throws: BrowserFailure.self) { try ChromeBrowser.validateURL(url) }
        }
        try ChromeBrowser.validateURL("https://example.test/path")
        try ChromeBrowser.validateURL("about:blank")
    }

    @Test func invalidInputNeverReachesTransport() {
        #expect(throws: BrowserFailure.self) { try ChromeBrowser.validate(.scroll(ref: nil, dx: .nan, dy: 1)) }
        #expect(throws: BrowserFailure.self) { try ChromeBrowser.validate(.click(ref: "e1", button: "left", count: 10)) }
        #expect(throws: BrowserFailure.self) { try ChromeBrowser.validate(.key("w", modifiers: ["meta"])) }
    }
}
