//
//  SceneToken.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

/// SceneToken is a deterministic, process-stable hash of a scene's content and control states.
///
/// A model echoes it back when it acts, and the actuator compares it against the live scene: the
/// same screen yields the same token, any element or state change yields a different one. It is
/// FNV-1a over a sorted rendering, never Swift's randomized `hashValue`, so two processes and two
/// launches agree.
public struct SceneToken: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Computes the token of a scene from the facts an action depends on.
    public init(bundleID: String, windowTitle: String, elements: [SceneElement]) {
        let body = elements
            .map { "\($0.id)|\($0.state?.rawValue ?? "")" }
            .sorted()
            .joined(separator: ";")
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(bundleID)\n\(windowTitle)\n\(body)".utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        self.rawValue = String(hash, radix: 16)
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
