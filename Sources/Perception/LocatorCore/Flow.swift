import Foundation

/// An ordered sequence of recorded element-clicks in one application — a replayable macro. Each step
/// references a `Descriptor` (by id) living in the descriptor store; the flow just records the order
/// and the owning app.
public struct Flow: Codable, Equatable, Sendable {
    public var name: String
    public var bundleID: String
    /// Descriptor ids, in execution order.
    public var stepIDs: [UUID]
    public var created: Date

    public init(name: String, bundleID: String, stepIDs: [UUID] = [], created: Date) {
        self.name = name
        self.bundleID = bundleID
        self.stepIDs = stepIDs
        self.created = created
    }
}
