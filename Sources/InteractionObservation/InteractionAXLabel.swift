import Foundation

/// InteractionAXLabel selects a bounded native name without reading editable or secure values.
/// The live adapter supplies facts lazily; tests exercise the same selection and descendant rules.
enum InteractionAXLabel {
    struct Facts {
        var role: String?
        var title: String?
        var description: String?
        var displayValue: String?
        var filename: String?
    }

    static func allowsDisplayValue(role: String?, subrole: String?, valueIsSettable: Bool?) -> Bool {
        guard subrole != "AXSecureTextField" else { return false }
        return role == "AXStaticText" || (role == "AXTextField" && valueIsSettable == false)
    }

    static func resolve<Node>(
        _ node: Node,
        facts: (Node) -> Facts,
        children: (Node) -> [Node]
    ) -> (label: String, source: String)? {
        func direct(_ value: Facts) -> (label: String, source: String)? {
            for (raw, source) in [(value.title, "title"), (value.description, "description"),
                                  (value.filename, "filename"), (value.displayValue, "display_value")] {
                guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty, text != "missing value",
                      !["cell", "row", "text"].contains(text.lowercased()) else { continue }
                return (String(text.prefix(160)), source)
            }
            return nil
        }
        let root = facts(node)
        if let result = direct(root) { return result }
        guard ["AXCell", "AXRow", "AXGroup"].contains(root.role ?? "") else { return nil }
        var names: [(label: String, source: String)] = []
        var remaining = 12
        func visit(_ node: Node, depth: Int) {
            guard remaining > 0 else { return }
            remaining -= 1
            let value = facts(node)
            if let result = direct(value) { names.append(result); return }
            if depth < 2, ["AXCell", "AXRow", "AXGroup"].contains(value.role ?? "") {
                for child in children(node).prefix(remaining) { visit(child, depth: depth + 1) }
            }
        }
        for child in children(node).prefix(remaining) { visit(child, depth: 1) }
        guard Set(names.map(\.label)).count == 1, let result = names.first else { return nil }
        return (result.label, "descendant_" + result.source)
    }
}
