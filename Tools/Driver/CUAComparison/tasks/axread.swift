// axread <pid> [--titles]: one JSON line with what a person could read in every window of a process, for the task
// checks of tasks.py: window titles, labelled values (checkboxes, fields, static texts) and, for text
// areas, the font of each run so a check can tell bold from plain (--titles: window titles only). Read-only, built to .build/axread.
import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func text(_ value: AnyObject?) -> String? {
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
}

let kept: Set<String> = ["AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea", "AXStaticText", "AXComboBox", "AXPopUpButton", "AXSlider"]

/// Runs of one text area: its text split where the font changes.
func runs(_ area: AXUIElement) -> [[String: String]] {
    guard let count = attribute(area, kAXNumberOfCharactersAttribute) as? Int, count > 0 else { return [] }
    var range = CFRange(location: 0, length: min(count, 20_000))
    guard let boxed = AXValueCreate(.cfRange, &range) else { return [] }
    var result: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(area, "AXAttributedStringForRange" as CFString, boxed, &result) == .success,
          let attributed = result as? NSAttributedString else { return [] }
    var out: [[String: String]] = []
    attributed.enumerateAttribute(NSAttributedString.Key("AXFont"), in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
        let font = (value as? [String: Any]).flatMap { ($0["AXFontName"] as? String) ?? ($0["AXFontFamily"] as? String) } ?? ""
        out.append(["text": attributed.attributedSubstring(from: range).string, "font": font])
    }
    return out
}

func walk(_ element: AXUIElement, depth: Int, into out: inout [[String: Any]], budget: inout Int) {
    guard depth < 40, budget > 0 else { return }
    budget -= 1
    let role = text(attribute(element, kAXRoleAttribute)) ?? ""
    if kept.contains(role) {
        var entry: [String: Any] = ["role": role]
        let label = [kAXTitleAttribute, kAXDescriptionAttribute, "AXLabel"].compactMap { text(attribute(element, $0)) }.first { !$0.isEmpty }
        if let label { entry["label"] = label }
        if let value = text(attribute(element, kAXValueAttribute)) { entry["value"] = String(value.prefix(20_000)) }
        if role == "AXTextArea" { entry["runs"] = runs(element) }
        if entry["label"] != nil || entry["value"] != nil { out.append(entry) }
    }
    for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        walk(child, depth: depth + 1, into: &out, budget: &budget)
    }
}

let pid = pid_t(CommandLine.arguments.dropFirst().first.flatMap { Int32($0) } ?? 0)
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 2)
// Chromium and Electron build their web tree only when asked.
AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
var titles: [String] = []
var elements: [[String: Any]] = []
var budget = 8000
let titlesOnly = CommandLine.arguments.contains("--titles")
for window in attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
    titles.append(text(attribute(window, kAXTitleAttribute)) ?? "")
    if !titlesOnly { walk(window, depth: 0, into: &elements, budget: &budget) }
}
let report: [String: Any] = ["titles": titles, "elements": elements]
print(String(decoding: try JSONSerialization.data(withJSONObject: report), as: UTF8.self))
