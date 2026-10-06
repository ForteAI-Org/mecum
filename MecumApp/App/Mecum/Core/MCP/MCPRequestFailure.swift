/// MCPRequestFailure describes a refusal before dispatch; it never reports a successful effect.
struct MCPRequestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
