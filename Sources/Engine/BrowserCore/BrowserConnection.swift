/// BrowserConnection describes the connected browser and its explicitly supported capabilities.
public struct BrowserConnection: Sendable, Codable, Equatable {
    public let id: String
    public let browser: String
    public let profile: BrowserProfile
    public let capabilities: [String]

    public init(id: String, browser: String, profile: BrowserProfile, capabilities: [String]) {
        self.id = id
        self.browser = browser
        self.profile = profile
        self.capabilities = capabilities
    }
}

/// BrowserTab is an explicit target, never an inferred active or first tab.
public struct BrowserTab: Sendable, Codable, Equatable {
    public let id: String
    public let title: String
    public let url: String

    public init(id: String, title: String, url: String) {
        self.id = id
        self.title = title
        self.url = url
    }
}
