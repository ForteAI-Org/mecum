import Foundation

/// MenuCatalog is a bounded, read-only snapshot of an application's native menu bar.
/// Unknown availability is nil. A partial catalog never proves that an omitted command is absent.
public struct MenuCatalog: Sendable, Equatable, Codable {
    public let items: [Item]
    public let isComplete: Bool
    public let issues: [String]

    public struct Item: Sendable, Equatable, Codable {
        public let path: [String]
        public let isEnabled: Bool?
        public let hasSubmenu: Bool
        public let mark: String?
        public let shortcut: String?

        public init(path: [String], isEnabled: Bool?, hasSubmenu: Bool = false,
                    mark: String? = nil, shortcut: String? = nil) {
            self.path = path
            self.isEnabled = isEnabled
            self.hasSubmenu = hasSubmenu
            self.mark = mark
            self.shortcut = shortcut
        }
    }

    public init(items: [Item], isComplete: Bool, issues: [String] = []) {
        self.items = items
        self.isComplete = isComplete
        self.issues = issues
    }

    /// Normalizes typography only. Punctuation such as I/O and numeric suffixes retain meaning.
    public static func key(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "…", with: "...").lowercased()
    }

    public func matching(path: [String]) -> [Item] {
        items.filter { $0.path.map(Self.key) == path.map(Self.key) }
    }
}
