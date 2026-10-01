import Foundation

/// AutomationFailure describes a refused setup or unavailable session without claiming an action succeeded.
public struct AutomationFailure: LocalizedError, CustomStringConvertible, Sendable {
    public let description: String
    public var errorDescription: String? { description }
    public init(_ description: String) { self.description = description }
}
