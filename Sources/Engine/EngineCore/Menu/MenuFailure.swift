/// MenuFailure refuses a native menu request before AXPress has been called.
public struct MenuFailure: Error, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}
