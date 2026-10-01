import Foundation
import LocalMCP

/// BrowserResultText presents every observed reference and coverage limit without repeating JSON keys.
/// Structured results remain unchanged. Strings are JSON-escaped so page text cannot introduce rows.
enum BrowserResultText {
    static func render(_ value: JSONValue) -> String {
        guard let object = value.object else { return encoded(value) }
        if value["nodes"].array != nil { return snapshot(value) }
        guard value["observation"].object != nil else { return encoded(value) }
        var receipt = object
        receipt.removeValue(forKey: "observation")
        return encoded(.object(receipt)) + "\nobservation:\n" + snapshot(value["observation"])
    }

    private static func snapshot(_ value: JSONValue) -> String {
        var metadata = value.object ?? [:]
        metadata.removeValue(forKey: "nodes")
        var lines = [encoded(.object(metadata))]
        for node in value["nodes"].array ?? [] {
            var row = "[" + (node["ref"].string ?? "?") + "] "
                + (node["role"].string ?? "unknown") + " " + encoded(node["name"])
            if let parent = node["parent"].string { row += " parent=" + parent }
            if node["value"] != .null { row += " value=" + encoded(node["value"]) }
            if node["states"].object?.isEmpty == false { row += " " + encoded(node["states"]) }
            lines.append(row)
        }
        return lines.joined(separator: "\n")
    }

    private static func encoded(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do { return String(decoding: try encoder.encode(value), as: UTF8.self) }
        catch { return "Encoding failed: \(error)" }
    }
}
