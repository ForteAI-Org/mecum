/// BrowserAction describes a bounded page operation. Node actions require the current snapshot ID.
/// Custom widgets use click/key rather than pretending to support native HTML select/fill semantics.
public enum BrowserAction: Sendable {
    case click(ref: String, button: String, count: Int)
    case fill(ref: String, text: String)
    case select(ref: String, value: String)
    case setChecked(ref: String, checked: Bool)
    case key(String, modifiers: [String])
    case scroll(ref: String?, dx: Double, dy: Double)
    case navigate(String)
    case back, forward, reload

    public var reference: String? {
        switch self {
        case .click(let ref, _, _), .fill(let ref, _), .select(let ref, _), .setChecked(let ref, _): ref
        case .scroll(let ref, _, _): ref
        default: nil
        }
    }
}

/// BrowserReceipt separates input delivery from verified state. Delivered does not establish task completion.
public struct BrowserReceipt: Sendable, Codable, Equatable {
    public enum Status: String, Sendable, Codable {
        case verified, delivered, unverified
    }
    public let status: Status
    public let detail: String

    public init(_ status: Status, _ detail: String) {
        self.status = status
        self.detail = detail
    }
}
