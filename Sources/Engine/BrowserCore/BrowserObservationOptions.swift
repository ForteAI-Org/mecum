/// BrowserObservationOptions bounds a semantic reading without changing input delivery.
/// Filtering precedes the node limit; omitted content must be reported in snapshot limitations.
public struct BrowserObservationOptions: Sendable, Equatable {
    /// Scope chooses the whole page, one dialog, or readable article/main content.
    /// Automatic prefers one unambiguous dialog and otherwise reads the page.
    public enum Scope: String, Sendable {
        case automatic = "auto"
        case page, dialog, content
    }

    public let scope: Scope
    public let query: String?
    public let limit: Int

    /// Configures a reading. Adapters must reject limits outside 1...400 and queries over 256 bytes.
    public init(scope: Scope = .automatic, query: String? = nil, limit: Int = 120) {
        self.scope = scope
        self.query = query
        self.limit = limit
    }
}
