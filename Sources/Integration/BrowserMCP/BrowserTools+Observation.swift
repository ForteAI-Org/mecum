import BrowserCore
import LocalMCP

extension BrowserTools {
    /// Appends one fresh reading without changing the outcome or replaying an effect if reading fails.
    func observedResult(
        _ receipt: JSONValue,
        tab: String,
        options: BrowserObservationOptions
    ) async -> JSONValue {
        var result = receipt.object ?? [:]
        do {
            try Task.checkCancellation()
            result["observation"] = snapshotValue(try await browser.snapshot(tab: tab, options: options))
        } catch {
            result["observationError"] = .string("Action was not repeated. Fresh reading unavailable: \(error)")
        }
        return .object(result)
    }

    func tabValue(_ tab: BrowserTab) -> JSONValue {
        .object(["id": .string(references.tab(tab.id)), "title": .string(tab.title), "url": .string(tab.url)])
    }

    func snapshotValue(_ snapshot: BrowserSnapshot) -> JSONValue {
        var value = Self.compact(snapshot).object ?? [:]
        value["id"] = .string(references.observe(snapshot.id, tab: snapshot.tab.id))
        value["tab"] = tabValue(snapshot.tab)
        return .object(value)
    }

    func observationOptions(_ value: JSONValue) -> BrowserObservationOptions {
        let limit: Int
        if case .number(let value) = value["limit"] { limit = Int(value) } else { limit = 120 }
        return BrowserObservationOptions(
            scope: value["scope"].string.flatMap(BrowserObservationOptions.Scope.init(rawValue:)) ?? .automatic,
            query: value["query"].string,
            limit: limit
        )
    }

    /// Omits adapter-only frame IDs and empty fields, retaining identity, ancestry and coverage limits.
    static func compact(_ snapshot: BrowserSnapshot) -> JSONValue {
        var value: [String: JSONValue] = [
            "id": .string(snapshot.id),
            "tab": .object(["id": .string(snapshot.tab.id), "title": .string(snapshot.tab.title), "url": .string(snapshot.tab.url)]),
            "nodes": .array(snapshot.nodes.map { node in
                var row: [String: JSONValue] = ["ref": .string(node.ref), "role": .string(node.role), "name": .string(node.name)]
                if let parent = node.parent { row["parent"] = .string(parent) }
                if let text = node.value { row["value"] = .string(text) }
                if !node.states.isEmpty { row["states"] = .object(node.states.mapValues(JSONValue.string)) }
                return .object(row)
            }),
            "limitations": .array(snapshot.limitations.map(JSONValue.string))
        ]
        if let scope = snapshot.scope { value["scope"] = .string(scope) }
        return .object(value)
    }
}
