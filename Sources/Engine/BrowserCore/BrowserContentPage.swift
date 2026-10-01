import Foundation

/// BrowserContentItem is readable article text, without actionable DOM references.
/// A stable identity is an observed permalink or HTML id; nil means distinctness cannot be proved.
public struct BrowserContentItem: Sendable, Codable, Equatable {
    public let identity: String?
    public let text: String
    public let url: String?
    public let truncated: Bool

    public init(identity: String?, text: String, url: String?, truncated: Bool) {
        self.identity = identity
        self.text = text
        self.url = url
        self.truncated = truncated
    }
}

/// BrowserContentPage is one document's currently rendered articles and scroll position.
/// The adapter bounds text size and reports omissions. It never follows links or submits forms.
public struct BrowserContentPage: Sendable {
    public let document: String
    public let url: String
    public let items: [BrowserContentItem]
    public let scrollY: Double
    public let atEnd: Bool
    public let limitations: [String]

    public init(document: String, url: String, items: [BrowserContentItem], scrollY: Double,
                atEnd: Bool, limitations: [String] = []) {
        self.document = document
        self.url = url
        self.items = items
        self.scrollY = scrollY
        self.atEnd = atEnd
        self.limitations = limitations
    }
}
