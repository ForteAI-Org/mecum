import Foundation

/// ProviderTurn names the exact conversation to resume. Nil means a new conversation.
/// The composition layer supplies paths; this value reads neither environment nor filesystem.
public struct ProviderTurn: Sendable {
    public let provider: ChatProvider
    public let model: String?
    public let sessionID: String?
    public let prompt: String
    public let instructions: String
    public let bridgeExecutable: String
    public let connectionFile: String
    public let workingDirectory: String
    /// The provider's reasoning effort, or nil for its default.
    public let effort: String?
    /// The child's whole environment, or nil to inherit this process's.
    public let environment: [String: String]?

    public init(provider: ChatProvider, model: String?, sessionID: String?, prompt: String,
                instructions: String, bridgeExecutable: String, connectionFile: String,
                workingDirectory: String, effort: String? = nil, environment: [String: String]? = nil) {
        self.provider = provider
        self.model = model
        self.sessionID = sessionID
        self.prompt = prompt
        self.instructions = instructions
        self.bridgeExecutable = bridgeExecutable
        self.connectionFile = connectionFile
        self.workingDirectory = workingDirectory
        self.effort = effort
        self.environment = environment
    }
}
