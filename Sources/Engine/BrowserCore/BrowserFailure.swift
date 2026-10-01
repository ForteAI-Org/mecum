/// BrowserFailure preserves refusal versus possible partial effects. Neither implies permission to retry.
public struct BrowserFailure: Error, Sendable, CustomStringConvertible, Equatable {
    public enum Code: String, Sendable, Codable {
        case notConnected, setupRequired, busy, invalidArgument, staleReference, unavailable, transport, protocolError
    }
    public let code: Code
    public let message: String
    public let effectsPossible: Bool
    public var description: String { "\(code.rawValue): \(message)" }

    public init(_ code: Code, _ message: String, effectsPossible: Bool = false) {
        self.code = code
        self.message = message
        self.effectsPossible = effectsPossible
    }
}

/// BrowserDialog is the most recently observed JavaScript modal for an attached tab.
public struct BrowserDialog: Sendable, Codable, Equatable {
    public let type: String
    public let message: String
    public let defaultPrompt: String

    public init(type: String, message: String, defaultPrompt: String) {
        self.type = type
        self.message = message
        self.defaultPrompt = defaultPrompt
    }
}
