import BrowserCore
import Testing
@testable import ChromeBrowser

struct ChromeKeyboardTests {
    @Test(arguments: ["arrowdown", "ArrowDown", "down", "DOWN"])
    func namedKeysUseOneCanonicalBrowserKey(_ spelling: String) throws {
        let result = try ChromeBrowser.keyParameters(spelling, modifiers: [])
        #expect(result["key"]?.string == "ArrowDown")
        #expect(result["windowsVirtualKeyCode"]?.number == 40)
        #expect(result["text"] == nil)
    }

    @Test func keyAliasesPreserveInputAndShortcutRestrictions() throws {
        #expect(try ChromeBrowser.keyParameters("return", modifiers: [])["text"]?.string == "\r")
        #expect(try ChromeBrowser.keyParameters("esc", modifiers: [])["key"]?.string == "Escape")
        #expect(throws: BrowserFailure.self) { try ChromeBrowser.keyParameters("W", modifiers: ["meta"]) }
        #expect(throws: BrowserFailure.self) { try ChromeBrowser.keyParameters("invented", modifiers: []) }
        #expect(throws: BrowserFailure.self) { try ChromeBrowser.keyParameters("Enter", modifiers: ["shift", "shift"]) }
    }
}
