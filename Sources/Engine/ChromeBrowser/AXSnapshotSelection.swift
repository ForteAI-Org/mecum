import BrowserCore
import Foundation

/// AXSnapshotSelection preserves AX ancestry while narrowing the model's reading before truncation.
/// Equal text is removed only beneath its owning named control, heading or article, never globally.
struct AXSnapshotSelection {
    struct Entry {
        let key: String
        let frame: String
        let row: CDPValue
        var role: String { row["role"]["value"].string ?? "" }
        var name: String { row["name"]["value"].string ?? "" }
    }

    let entries: [Entry]
    let parents: [String: String]
    let byKey: [String: Entry]

    init(frames: [(String, [CDPValue])]) {
        var entries: [Entry] = []
        var parents: [String: String] = [:]
        for (frame, rows) in frames {
            for row in rows {
                guard let id = row["nodeId"].string else { continue }
                let key = frame + ":" + id
                entries.append(Entry(key: key, frame: frame, row: row))
                for child in row["childIds"].array ?? [] {
                    if let childID = child.string { parents[frame + ":" + childID] = key }
                }
            }
        }
        self.entries = entries
        self.parents = parents
        self.byKey = Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func select(_ options: BrowserObservationOptions) throws -> (entries: [Entry], scope: String, limitations: [String]) {
        guard (1...400).contains(options.limit), (options.query?.utf8.count ?? 0) <= 256 else {
            throw BrowserFailure(.invalidArgument, "Observation requires limit 1...400 and a query of at most 256 bytes.")
        }
        var candidates = entries.filter { $0.row["ignored"].bool != true }
        var scope = "page"
        var limitations: [String] = []
        let dialogs = candidates.filter { ["dialog", "alertdialog"].contains($0.role) }
        let modal = dialogs.filter { entry in
            (entry.row["properties"].array ?? []).contains { $0["name"].string == "modal" && $0["value"]["value"].bool == true }
        }
        let preferred = modal.isEmpty ? dialogs : modal
        if options.scope == .dialog || options.scope == .automatic && preferred.count == 1 {
            guard preferred.count == 1, let dialog = preferred.first else {
                throw BrowserFailure(.unavailable, "Expected one unambiguous dialog. Read scope page to inspect the available dialogs.")
            }
            candidates = candidates.filter { isWithin($0.key, roots: [dialog.key]) }
            scope = "dialog"
            limitations.append("Focused on one dialog; other page content and embedded frame documents are omitted. Use scope page to expand.")
        } else if options.scope == .automatic && preferred.count > 1 {
            limitations.append("Multiple dialogs are exposed; none was chosen automatically.")
        }
        if options.scope == .content {
            let articles = Set(candidates.filter { $0.role == "article" }.map(\.key))
            if !articles.isEmpty {
                candidates = candidates.filter {
                    entry in
                    if articles.contains(entry.key) { return true }
                    guard ["link", "heading", "StaticText", "paragraph"].contains(entry.role),
                          isWithin(entry.key, roots: articles) else { return false }
                    return !ancestry(of: entry.key).contains { key in
                        guard let owner = byKey[key] else { return false }
                        return ChromeBrowser.actionableRoles.contains(owner.role) && owner.role != "link"
                    }
                }
            } else {
                let main = Set(candidates.filter { $0.role == "main" }.map(\.key))
                candidates = candidates.filter {
                    (main.isEmpty || isWithin($0.key, roots: main)) &&
                    ["StaticText", "heading", "paragraph", "link"].contains($0.role)
                }
            }
            scope = "content"
            limitations.append("Content view omits unrelated controls. Use scope page for interaction outside these references.")
        }
        if let query = options.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            let hits = Set(candidates.filter { $0.role != "RootWebArea" && $0.name.localizedCaseInsensitiveContains(query) }.map(\.key))
            let ancestors = Set(hits.flatMap { ancestry(of: $0) })
            candidates = candidates.filter { ancestors.contains($0.key) || isWithin($0.key, roots: hits) }
            limitations.append("Filtered by label query; nonmatching page content is omitted.")
        }
        let candidateKeys = Set(candidates.map(\.key))
        candidates = candidates.filter { entry in
            guard entry.row["backendDOMNodeId"].number != nil,
                  !["InlineTextBox", "none", "generic", "RootWebArea"].contains(entry.role),
                  !entry.name.isEmpty || entry.role == "article" || ChromeBrowser.actionableRoles.contains(entry.role) else { return false }
            guard entry.role == "StaticText" else { return true }
            // Input value text is not a separate target or an autocomplete option.
            if ancestry(of: entry.key).contains(where: { key in
                guard let owner = byKey[key] else { return false }
                return ["textbox", "searchbox", "combobox"].contains(owner.role)
            }) { return false }
            return !ancestry(of: entry.key).contains { key in
                guard candidateKeys.contains(key), let owner = byKey[key],
                      owner.row["backendDOMNodeId"].number != nil, !entry.name.isEmpty else { return false }
                return (ChromeBrowser.actionableRoles.contains(owner.role) || ["heading", "article"].contains(owner.role)) &&
                    owner.name.count <= 512 && owner.name.contains(entry.name)
            }
        }
        if candidates.count > options.limit {
            limitations.append("Truncated at \(options.limit) of \(candidates.count) matching nodes. Narrow scope/query or increase limit to at most 400.")
        }
        let chosen = Array(candidates.prefix(options.limit))
        if chosen.contains(where: { $0.name.count > 512 }) {
            limitations.append("Some labels are shortened to 512 characters; their text is incomplete.")
        }
        return (chosen, scope, limitations)
    }

    func ancestry(of key: String) -> [String] {
        var path: [String] = []
        var seen: Set<String> = [key]
        var current = key
        while let parent = parents[current], seen.insert(parent).inserted {
            path.append(parent)
            current = parent
        }
        return path
    }

    private func isWithin(_ key: String, roots: Set<String>) -> Bool {
        roots.contains(key) || ancestry(of: key).contains { roots.contains($0) }
    }
}
