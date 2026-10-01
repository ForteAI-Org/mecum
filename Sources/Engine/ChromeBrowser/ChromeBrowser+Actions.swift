import BrowserCore
import Foundation

extension ChromeBrowser {
    public func perform(_ action: BrowserAction, tab: String, snapshot: String?) async throws -> BrowserReceipt {
        try begin()
        defer { busy = false }
        try Self.validate(action)
        let session = try await attach(tab)
        guard await connection?.currentDialog(sessionID: session) == nil else {
            throw BrowserFailure(.unavailable, "A JavaScript dialog is open. Read browser_dialog first.")
        }
        try await prepareInput(session)
        var node: (String, NodeReference)?
        if let ref = action.reference { node = try await resolve(ref, tab: tab, snapshot: snapshot, session: session) }
        observations.removeValue(forKey: tab)
        do {
            return try await deliver(action, node: node, session: session)
        } catch {
            if await connection?.currentDialog(sessionID: session) != nil {
                return BrowserReceipt(.delivered, "A JavaScript dialog opened during input. Read browser_dialog and handle it before observing; do not repeat the action.")
            }
            // DOM focus, scrolling or a protocol send may already have happened. Never replay here.
            let failure = error as? BrowserFailure
            throw BrowserFailure(failure?.code ?? .transport, failure?.message ?? String(describing: error), effectsPossible: true)
        }
    }

    static func validate(_ action: BrowserAction) throws {
        switch action {
        case .click(_, let button, let count):
            guard ["left", "right"].contains(button), (1...2).contains(count) else {
                throw BrowserFailure(.invalidArgument, "Click requires left/right and count 1 or 2.")
            }
        case .fill(_, let text), .select(_, let text):
            guard text.utf8.count <= 32_768 else { throw BrowserFailure(.invalidArgument, "Text exceeds 32 KiB.") }
        case .scroll(_, let dx, let dy):
            guard dx.isFinite, dy.isFinite, abs(dx) <= 4000, abs(dy) <= 4000, dx != 0 || dy != 0 else {
                throw BrowserFailure(.invalidArgument, "Scroll requires finite nonzero offsets of at most 4000 CSS pixels.")
            }
        case .key(let key, let modifiers): _ = try keyParameters(key, modifiers: modifiers)
        case .navigate(let url): try validateURL(url)
        default: break
        }
    }

    private func deliver(_ action: BrowserAction, node: (String, NodeReference)?, session: String) async throws -> BrowserReceipt {
        switch action {
        case .click(_, let button, let count):
            guard let node else { throw malformed("click reference") }
            let point = try await clickPoint(node, session: session)
            for index in 1...count {
                _ = try await command("Input.dispatchMouseEvent", ["type": .string("mousePressed"),
                    "x": point["x"], "y": point["y"], "button": .string(button),
                    "clickCount": .number(Double(index))], session: session)
                _ = try await command("Input.dispatchMouseEvent", ["type": .string("mouseReleased"),
                    "x": point["x"], "y": point["y"], "button": .string(button),
                    "clickCount": .number(Double(index))], session: session)
            }
            return BrowserReceipt(.delivered, "Pointer input sent once to the observed element. Observe to verify its effect.")
        case .fill(_, let text):
            guard let node else { throw malformed("fill reference") }
            let prepared = try await onNode(node.0, function: BrowserScripts.prepareFill, session: session)
            guard prepared.bool == true else { throw BrowserFailure(.unavailable, "This is not an enabled editable text field.") }
            _ = try await command("Input.insertText", ["text": .string(text)], session: session)
            let verified = try await onNode(node.0, function: BrowserScripts.verifyFill, arguments: [.string(text)], session: session)
            return BrowserReceipt(verified.bool == true ? .verified : .unverified,
                verified.bool == true ? "Field value equals the requested text." : "Text was sent, but its final value was not verified. Observe before retrying.")
        case .select(_, let value):
            guard let node else { throw malformed("select reference") }
            let result = try await onNode(node.0, function: BrowserScripts.selectOption, arguments: [.string(value)], session: session)
            guard result["accepted"].bool == true else {
                throw BrowserFailure(.unavailable, "Expected an enabled HTML select and one exact option value or label. Custom menus use click and a fresh snapshot.")
            }
            return BrowserReceipt(result["verified"].bool == true ? .verified : .unverified,
                                  "Native select change dispatched; verified reports whether its value remained selected.")
        case .setChecked(_, let checked):
            guard let node else { throw malformed("toggle reference") }
            let current = try await onNode(node.0, function: BrowserScripts.readChecked, session: session)
            guard let state = current.bool else { throw BrowserFailure(.unavailable, "Expected an enabled native checkbox or radio.") }
            if state == checked { return BrowserReceipt(.verified, "Control already has the requested checked state.") }
            let point = try await clickPoint(node, session: session)
            for type in ["mousePressed", "mouseReleased"] {
                _ = try await command("Input.dispatchMouseEvent", ["type": .string(type), "x": point["x"], "y": point["y"],
                    "button": .string("left"), "clickCount": .number(1)], session: session)
            }
            let final = try await onNode(node.0, function: BrowserScripts.readChecked, session: session)
            return BrowserReceipt(final.bool == checked ? .verified : .unverified, "Checked state was read after one click.")
        case .key(let key, let modifiers):
            var params = try Self.keyParameters(key, modifiers: modifiers)
            params["type"] = .string("keyDown")
            _ = try await command("Input.dispatchKeyEvent", params, session: session)
            params["type"] = .string("keyUp")
            params.removeValue(forKey: "text")
            _ = try await command("Input.dispatchKeyEvent", params, session: session)
            return BrowserReceipt(.delivered, "Key delivered to this tab's focused control. Observe the result.")
        case .scroll(_, let dx, let dy):
            let point: CDPValue
            if let node { point = try await clickPoint(node, session: session) }
            else {
                let metrics = try await command("Page.getLayoutMetrics", session: session)
                let viewport = metrics["cssLayoutViewport"]
                guard let width = viewport["clientWidth"].number, let height = viewport["clientHeight"].number else {
                    throw malformed("Page.getLayoutMetrics")
                }
                point = .object(["x": .number(width / 2), "y": .number(height / 2)])
            }
            _ = try await command("Input.dispatchMouseEvent", ["type": .string("mouseWheel"),
                "x": point["x"], "y": point["y"], "deltaX": .number(dx), "deltaY": .number(dy)], session: session)
            return BrowserReceipt(.delivered, "Wheel input delivered in CSS pixels. Observe the new viewport.")
        case .navigate(let url):
            let result = try await command("Page.navigate", ["url": .string(url)], session: session)
            if let error = result["errorText"].string, !error.isEmpty { throw BrowserFailure(.unavailable, "Navigation failed: \(error)") }
            return BrowserReceipt(.delivered, "Navigation requested. A fresh snapshot must confirm the destination and content.")
        case .reload:
            _ = try await command("Page.reload", session: session)
            return BrowserReceipt(.delivered, "Reload requested. Observe after loading.")
        case .back, .forward:
            let history = try await command("Page.getNavigationHistory", session: session)
            guard let current = history["currentIndex"].number, let entries = history["entries"].array else {
                throw malformed("Page.getNavigationHistory")
            }
            let offset: Int
            if case .back = action { offset = -1 } else { offset = 1 }
            let index = Int(current) + offset
            guard entries.indices.contains(index) else { throw BrowserFailure(.unavailable, "No history entry in that direction.") }
            _ = try await command("Page.navigateToHistoryEntry", ["entryId": entries[index]["id"]], session: session)
            return BrowserReceipt(.delivered, "History navigation requested. Observe the resulting document.")
        }
    }

    private func clickPoint(_ node: (String, NodeReference), session: String) async throws -> CDPValue {
        let point = try await onNode(node.0, function: BrowserScripts.clickPoint, session: session)
        guard var x = point["x"].number, var y = point["y"].number else {
            throw BrowserFailure(.unavailable, "Element is hidden, disabled, detached or covered by another element.")
        }
        let tree = try await document(session)
        let root = tree["frame"]["id"].string
        var frame = node.1.frame
        while frame != root {
            guard let parent = Self.parentFrame(of: frame, tree: tree) else {
                throw BrowserFailure(.staleReference, "Frame ancestry changed. Observe again.")
            }
            let owner = try await command("DOM.getFrameOwner", ["frameId": .string(frame)], session: session)
            let remote = try await command("DOM.resolveNode", ["backendNodeId": owner["backendNodeId"], "objectGroup": .string("mecum-browser")], session: session)
            guard let object = remote["object"]["objectId"].string else { throw malformed("frame owner") }
            let outer = try await onNode(object, function: BrowserScripts.framePoint,
                                        arguments: [.number(x), .number(y)], session: session)
            guard let outerX = outer["x"].number, let outerY = outer["y"].number else {
                throw BrowserFailure(.unavailable, "Frame is covered, transformed or outside its parent viewport.")
            }
            x = outerX
            y = outerY
            frame = parent
        }
        return .object(["x": .number(x), "y": .number(y)])
    }

    static func parentFrame(of id: String, tree: CDPValue) -> String? {
        for child in tree["childFrames"].array ?? [] {
            if child["frame"]["id"].string == id { return tree["frame"]["id"].string }
            if let parent = parentFrame(of: id, tree: child) { return parent }
        }
        return nil
    }

    static func keyParameters(_ key: String, modifiers: [String]) throws -> [String: CDPValue] {
        let named: [String: Int] = ["Enter": 13, "Tab": 9, "Escape": 27, "Backspace": 8, "Delete": 46,
            "ArrowLeft": 37, "ArrowUp": 38, "ArrowRight": 39, "ArrowDown": 40, "Home": 36, "End": 35,
            "PageUp": 33, "PageDown": 34, "Space": 32]
        let aliases = ["return": "Enter", "esc": "Escape", "left": "ArrowLeft", "right": "ArrowRight",
                       "up": "ArrowUp", "down": "ArrowDown", "spacebar": "Space", " ": "Space"]
        let key = aliases[key.lowercased()] ?? named.keys.first { $0.lowercased() == key.lowercased() } ?? key
        let masks = ["alt": 1, "ctrl": 2, "meta": 4, "shift": 8]
        guard Set(modifiers).count == modifiers.count, modifiers.allSatisfy({ masks[$0] != nil }),
              named[key] != nil || (key.count == 1 && key.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }) else {
            throw BrowserFailure(.invalidArgument, "Use Enter, Tab, Escape, Backspace, Delete, ArrowLeft/Up/Right/Down, Home, End, PageUp/Down, Space, or one ASCII letter/digit. Modifiers are alt/ctrl/meta/shift.")
        }
        guard !modifiers.contains("meta") && !modifiers.contains("ctrl") || !["w", "q", "n", "t", "l"].contains(key.lowercased()) else {
            throw BrowserFailure(.invalidArgument, "Browser/window shortcuts are refused; use explicit tab operations.")
        }
        let code = named[key] ?? Int(key.uppercased().unicodeScalars.first?.value ?? 0)
        var params: [String: CDPValue] = ["key": .string(key == "Space" ? " " : key),
            "windowsVirtualKeyCode": .number(Double(code)), "nativeVirtualKeyCode": .number(Double(code)),
            "modifiers": .number(Double(modifiers.reduce(0) { $0 | (masks[$1] ?? 0) }))]
        if modifiers.allSatisfy({ $0 == "shift" }), key.count == 1 || key == "Space" || key == "Enter" {
            params["text"] = .string(key == "Enter" ? "\r" : key == "Space" ? " " : key)
        }
        return params
    }
}
