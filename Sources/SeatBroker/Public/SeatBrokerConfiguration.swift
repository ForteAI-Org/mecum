import Foundation

public struct SeatBrokerConfiguration: Sendable {
    /// Act on a macOS build the seat driver's ledger has not validated. Self
    /// checks and permissions still apply; receipts are flagged unvalidated.
    public var allowUnvalidatedBuild: Bool
    /// Where perception would keep a store of its own. Nothing writes here
    /// since perception became the Perception layer's pipeline, which reads no
    /// environment and remembers nothing between calls; the field stays so the
    /// app that configures the runtime keeps compiling.
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
