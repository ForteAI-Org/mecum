import BrowserCore
import LocalMCP

extension BrowserTools {
    public static var definitions: [JSONValue] {
        let text: JSONValue = .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(32768)])
        let content: JSONValue = .object(["type": .string("string"), "maxLength": .number(32768)])
        let boolean: JSONValue = .object(["type": .string("boolean")])
        let offset: JSONValue = .object(["type": .string("number"), "minimum": .number(-4000), "maximum": .number(4000)])
        let connected: [String: JSONValue] = ["connection": text]
        let tab = connected.merging(["tab": text], uniquingKeysWith: { $1 })
        let node = tab.merging(["snapshot": text, "ref": text], uniquingKeysWith: { $1 })
        func choice(_ values: [String]) -> JSONValue {
            .object(["type": .string("string"), "enum": .array(values.map(JSONValue.string))])
        }
        let reading: [String: JSONValue] = [
            "scope": choice(["auto", "page", "dialog", "content"]),
            "query": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(256)]),
            "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(400)])
        ]
        let observation: JSONValue = .object(["type": .string("object"), "properties": .object(reading),
            "additionalProperties": .bool(false)])
        func tool(_ name: String, _ description: String, _ properties: [String: JSONValue],
                  _ required: [String], readOnly: Bool = false) -> JSONValue {
            let observes = ["open", "click", "fill", "select", "set_checked", "key", "scroll", "navigate", "back", "forward", "reload", "handle_dialog"].contains(name)
            var fields = properties
            if observes { fields["observation"] = observation }
            let guidance = observes ? " Returns a fresh observation; use its id/refs without another snapshot. Optional observation scope/query/limit narrows it." : ""
            return .object(["name": .string("browser_" + name), "description": .string(description + guidance),
                "inputSchema": .object(["type": .string("object"), "properties": .object(fields),
                    "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)]),
                "annotations": .object(["readOnlyHint": .bool(readOnly)])])
        }
        return [
            tool("status", "Read this host's browser connection metadata and next step. Does not probe Chrome.", [:], [], readOnly: true),
            tool("connect", "Connect to Chrome current session (requires browser consent), or a separate persistent automation profile. Never copies cookies.",
                 ["profile": choice(["current", "automation"])], ["profile"]),
            tool("disconnect", "Release debugging; leave browser and persistent data intact.", connected, ["connection"]),
            tool("tabs", "List inspectable page tabs. Choose the explicit tab ID; never guess the active tab.", connected, ["connection"], readOnly: true),
            tool("open", "Open a new background tab at an absolute http/https/file URL or about:blank.",
                 connected.merging(["url": text], uniquingKeysWith: { $1 }), ["connection", "url"]),
            tool("close", "Close exactly the requested tab. It may contain unsaved work.", tab, ["connection", "tab"]),
            tool("snapshot", "Read a compact semantic view. auto prefers one dialog; page expands, content reads articles/links. query filters labels, limit defaults to 120 (max 400). A new reading replaces all prior refs.", tab.merging(reading, uniquingKeysWith: { $1 }), ["connection", "tab"], readOnly: true),
            tool("collect", "Collect up to count rendered articles, directly scrolling the main document within maxScrolls. Stops on navigation, no progress or error; preserves partial text. countReached counts observed permalinks/ids, not complete content. No images or embedded frames. No clicking or submission.",
                 tab.merging(["count": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(50)]),
                              "maxScrolls": .object(["type": .string("integer"), "minimum": .number(0), "maximum": .number(20)])], uniquingKeysWith: { $1 }),
                 ["connection", "tab", "count"]),
            tool("click", "Click a reference once (or twice when count=2). Delivery is not task success; inspect the returned observation.",
                 node.merging(["button": choice(["left", "right"]), "count": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(2)])], uniquingKeysWith: { $1 }),
                 ["connection", "tab", "snapshot", "ref"]),
            tool("fill", "Replace an editable field's entire text and verify equality. Empty text clears. Values are not echoed.",
                 node.merging(["text": content], uniquingKeysWith: { $1 }), ["connection", "tab", "snapshot", "ref", "text"]),
            tool("select", "Choose one native HTML select option by exact value or label, refusing ambiguity. Custom menus need click and snapshot.",
                 node.merging(["value": content], uniquingKeysWith: { $1 }), ["connection", "tab", "snapshot", "ref", "value"]),
            tool("set_checked", "Set a native checkbox/radio to an explicit checked state and verify it.",
                 node.merging(["checked": boolean], uniquingKeysWith: { $1 }), ["connection", "tab", "snapshot", "ref", "checked"]),
            tool("key", "Send Enter, Tab, Escape, Backspace, Delete, ArrowLeft/Up/Right/Down, Home, End, PageUp/Down, Space, or an ASCII letter/digit. Named keys are case-insensitive; return/esc/up/down/left/right aliases are accepted. Inspect the returned observation.",
                 tab.merging(["key": text, "modifiers": .object(["type": .string("array"), "maxItems": .number(4), "uniqueItems": .bool(true), "items": choice(["alt", "ctrl", "meta", "shift"])])], uniquingKeysWith: { $1 }),
                 ["connection", "tab", "key"]),
            tool("scroll", "Scroll by dx/dy CSS pixels. Optional ref requires snapshot; otherwise scroll at viewport center.",
                 node.merging(["dx": offset, "dy": offset], uniquingKeysWith: { $1 }), ["connection", "tab"]),
            tool("navigate", "Navigate this tab once. Inspect the returned observation to confirm the document.",
                 tab.merging(["url": text], uniquingKeysWith: { $1 }), ["connection", "tab", "url"]),
            tool("back", "Navigate to the preceding history entry, then inspect the returned observation.", tab, ["connection", "tab"]),
            tool("forward", "Navigate to the next history entry, then inspect the returned observation.", tab, ["connection", "tab"]),
            tool("reload", "Reload this tab, then inspect the returned observation.", tab, ["connection", "tab"]),
            tool("screenshot", "Capture this tab's viewport as PNG, without macOS screen recording or Seat.", tab, ["connection", "tab"], readOnly: true),
            tool("dialog", "Read the JavaScript dialog observed since attachment to this tab.", tab, ["connection", "tab"], readOnly: true),
            tool("handle_dialog", "Accept/dismiss the observed JavaScript dialog; optional text answers a prompt.",
                 tab.merging(["accept": boolean, "text": content], uniquingKeysWith: { $1 }), ["connection", "tab", "accept"])
        ]
    }

    static func validate(_ name: String, _ value: JSONValue) throws {
        guard let definition = definitions.first(where: { $0["name"].string == name }) else {
            throw BrowserFailure(.invalidArgument, "Unknown browser tool.")
        }
        try validateValue(value, schema: definition["inputSchema"], path: name)
        if name == "browser_scroll", value["ref"] != .null, value["snapshot"].string == nil {
            throw BrowserFailure(.invalidArgument, "Scrolling a reference requires its snapshot ID.")
        }
    }

    private static func validateValue(_ value: JSONValue, schema: JSONValue, path: String) throws {
        func invalid() -> BrowserFailure { BrowserFailure(.invalidArgument, "Invalid argument at \(path).") }
        if let options = schema["enum"].array, !options.contains(value) { throw invalid() }
        switch schema["type"].string {
        case "object":
            guard let object = value.object, let properties = schema["properties"].object,
                  Set(object.keys).isSubset(of: Set(properties.keys)) else { throw invalid() }
            for required in schema["required"].array ?? [] {
                guard let key = required.string, object[key] != nil else { throw invalid() }
            }
            for (key, child) in object { try validateValue(child, schema: properties[key] ?? .null, path: path + "." + key) }
        case "string":
            guard let text = value.string else { throw invalid() }
            if case .number(let minimum) = schema["minLength"], text.count < Int(minimum) { throw invalid() }
            if case .number(let maximum) = schema["maxLength"], text.utf8.count > Int(maximum) { throw invalid() }
        case "number", "integer":
            guard case .number(let number) = value, number.isFinite else { throw invalid() }
            if schema["type"].string == "integer", number.rounded() != number { throw invalid() }
            if case .number(let minimum) = schema["minimum"], number < minimum { throw invalid() }
            if case .number(let maximum) = schema["maximum"], number > maximum { throw invalid() }
        case "boolean": guard value.bool != nil else { throw invalid() }
        case "array":
            guard let array = value.array else { throw invalid() }
            if case .number(let maximum) = schema["maxItems"], array.count > Int(maximum) { throw invalid() }
            for (index, item) in array.enumerated() {
                if schema["uniqueItems"].bool == true, array.prefix(index).contains(item) { throw invalid() }
                try validateValue(item, schema: schema["items"], path: path + "[]")
            }
        default: throw invalid()
        }
    }
}
