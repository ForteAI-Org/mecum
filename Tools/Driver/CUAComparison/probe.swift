// probe <pid>: one JSON line about the desktop around a target process, read independently of
// either driver: the frontmost process, the physical cursor, the target's windows, and a digest of
// the AX values in its focused window, which changes when an action's effect lands.
import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

/// The values a person would see change: texts, field contents, selections and toggle states.
func values(_ element: AXUIElement, depth: Int, into out: inout [String], budget: inout Int) {
    guard depth < 40, budget > 0 else { return }
    budget -= 1
    if let value = attribute(element, kAXValueAttribute) {
        if let text = value as? String { out.append(String(text.prefix(200))) }
        else if let number = value as? NSNumber { out.append(number.stringValue) }
    }
    if let selected = attribute(element, kAXSelectedAttribute) as? Bool, selected { out.append("selected") }
    for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        values(child, depth: depth + 1, into: &out, budget: &budget)
    }
}

/// FNV-1a: String.hashValue is seeded per process, so it cannot compare two readings.
func fnv1a(_ text: String) -> UInt64 {
    text.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
}

let pid = pid_t(CommandLine.arguments.dropFirst().first.flatMap { Int32($0) } ?? 0)
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 1)
var texts: [String] = []
var budget = 4000
if let window = attribute(app, kAXFocusedWindowAttribute) ?? attribute(app, kAXMainWindowAttribute) {
    values(window as! AXUIElement, depth: 0, into: &texts, budget: &budget)
}
var focusedValue: String?
if let focused = attribute(app, kAXFocusedUIElementAttribute) {
    focusedValue = (attribute(focused as! AXUIElement, kAXValueAttribute) as? String).map { String($0.prefix(200)) }
}
let rows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
let windows: [[String: Any]] = rows.compactMap { row in
    guard (row[kCGWindowOwnerPID as String] as? Int32) == pid, (row[kCGWindowLayer as String] as? Int) == 0,
          let bounds = row[kCGWindowBounds as String] as? [String: Double] else { return nil }
    return ["id": row[kCGWindowNumber as String] as? Int ?? 0, "onscreen": row[kCGWindowIsOnscreen as String] as? Bool ?? false,
            "x": bounds["X"] ?? 0, "y": bounds["Y"] ?? 0, "w": bounds["Width"] ?? 0, "h": bounds["Height"] ?? 0]
}
let front = rows.first { ($0[kCGWindowLayer as String] as? Int) == 0 }
let cursor = CGEvent(source: nil)?.location ?? .zero
let report: [String: Any] = [
    "frontmost": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
    "frontWindowOwner": front?[kCGWindowOwnerPID as String] as? Int32 ?? 0,
    "cursor": [cursor.x, cursor.y],
    "windows": windows,
    "digest": String(fnv1a(texts.joined(separator: "\u{1f}")), radix: 16),
    "valueCount": texts.count,
    "focusedValue": focusedValue ?? NSNull()
]
print(String(decoding: try JSONSerialization.data(withJSONObject: report), as: UTF8.self))
