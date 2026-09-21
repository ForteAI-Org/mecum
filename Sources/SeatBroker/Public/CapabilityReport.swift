/// One facility of the seat driver and whether the runtime may use it now.
/// `detail` names the missing grant or the failed self-check when not ready.
public struct CapabilityEntry: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let ready: Bool
    public let detail: String
}

public struct CapabilityReport: Sendable, Hashable {
    public let entries: [CapabilityEntry]
    public var allReady: Bool { entries.allSatisfy(\.ready) }
}
