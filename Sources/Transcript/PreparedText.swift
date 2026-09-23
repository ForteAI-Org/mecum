//
//  PreparedText.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit

/// PreparedText is a row's text after the content pipeline: the characters
/// and the role of each run, with no font or colour object in it.
///
/// A value rather than an attributed string because it crosses from the
/// preparation pass to the main actor, and `NSFont` is not `Sendable`. Turning
/// it into an attributed string only applies attributes, so the parsing it
/// came from happens once, off the main thread.
public struct PreparedText: Sendable, Hashable {

    /// What a run of characters is, which decides its font and colour.
    public enum Role: Sendable, Hashable {
        case body
        case bodyOnAccent
        case caption
        case captionStrong
        case monospaced
        case alert
    }

    public struct Run: Sendable, Hashable {
        public let range: NSRange
        public let role : Role
    }

    public private(set) var string: String = ""
    public private(set) var runs  : [Run]  = []

    public init() {}

    public init(_ string: String, role: Role) {
        append(string, role: role)
    }

    /// Adds `string` as one run of `role`.
    public mutating func append(_ string: String, role: Role) {
        let start = (self.string as NSString).length
        self.string += string
        runs.append(Run(range: NSRange(location: start, length: (string as NSString).length), role: role))
    }

    /// The attributed form at `style`. Safe on any thread: it creates its
    /// fonts and colours and shares none.
    public func attributed(_ style: TranscriptStyle) -> NSAttributedString {
        let result = NSMutableAttributedString(string: string)
        for run in runs {
            result.addAttributes(Self.attributes(run.role, style), range: run.range)
        }
        return result
    }

    private static func attributes(_ role: Role, _ style: TranscriptStyle) -> [NSAttributedString.Key: Any] {
        switch role {
        case .body:
            [.font: NSFont.systemFont(ofSize: style.bodyPointSize), .foregroundColor: NSColor.labelColor]
        case .bodyOnAccent:
            [.font: NSFont.systemFont(ofSize: style.bodyPointSize), .foregroundColor: NSColor.white]
        case .caption:
            [.font: NSFont.systemFont(ofSize: style.captionPointSize), .foregroundColor: NSColor.secondaryLabelColor]
        case .captionStrong:
            [.font: NSFont.boldSystemFont(ofSize: style.captionPointSize),
             .foregroundColor: NSColor.secondaryLabelColor]
        case .monospaced:
            [.font: NSFont.monospacedSystemFont(ofSize: style.monospacedPointSize, weight: .regular),
             .foregroundColor: NSColor.secondaryLabelColor]
        case .alert:
            [.font: NSFont.systemFont(ofSize: style.bodyPointSize), .foregroundColor: NSColor.systemRed]
        }
    }
}
