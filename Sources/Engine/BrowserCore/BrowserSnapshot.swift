/// BrowserSnapshot owns references from one observation. A later snapshot or action invalidates them.
/// `limitations` reports omitted frames or nodes; the snapshot must not be treated as complete then.
public struct BrowserSnapshot: Sendable, Codable, Equatable {
    public let id: String
    public let tab: BrowserTab
    public let nodes: [BrowserNode]
    public let limitations: [String]
    public let scope: String?

    public init(id: String, tab: BrowserTab, nodes: [BrowserNode], limitations: [String], scope: String? = nil) {
        self.id = id
        self.tab = tab
        self.nodes = nodes
        self.limitations = limitations
        self.scope = scope
    }
}

/// BrowserNode exposes semantic page content and opaque references, not screen coordinates or selectors.
public struct BrowserNode: Sendable, Codable, Equatable {
    public let ref: String
    public let frame: String
    public let role: String
    public let name: String
    public let value: String?
    public let states: [String: String]
    public let parent: String?

    public init(ref: String, frame: String, role: String, name: String, value: String?, states: [String: String], parent: String? = nil) {
        self.ref = ref
        self.frame = frame
        self.role = role
        self.name = name
        self.value = value
        self.states = states
        self.parent = parent
    }
}
