import Foundation

public struct SeatBrokerConfiguration: Sendable {
    /// Act on a macOS build the seat driver's ledger has not validated. Self
    /// checks and permissions still apply; receipts are flagged unvalidated.
    public var allowUnvalidatedBuild: Bool
    /// Where perception keeps its icon, knowledge and memory stores.
    public var perceptionStoreDirectory: URL
    /// Where run records and their final frames are kept.
    public var recordingDirectory: URL

    public init(allowUnvalidatedBuild: Bool = false, perceptionStoreDirectory: URL? = nil,
                recordingDirectory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentLab", isDirectory: true)
        self.allowUnvalidatedBuild = allowUnvalidatedBuild
        self.perceptionStoreDirectory = perceptionStoreDirectory
            ?? support.appendingPathComponent("Perception", isDirectory: true)
        self.recordingDirectory = recordingDirectory
            ?? support.appendingPathComponent("Runs", isDirectory: true)
    }
}
