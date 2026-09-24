//
//  WindowContext.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import PerceptionCore

/// WindowContext is where a living-memory record happened: one application, by its bundle
/// identifier, and one window, by its title's letter family (the same family `BrainMemory` scopes
/// the brain by), so "I/O Setup" and "I/O Setup 2" are one window and another window is not.
///
/// A context names the application, never a run of it. The runtime's process fallback
/// (`pid.<digits>`) and a title without letters cannot be attributed and build no context.
public struct WindowContext: Sendable, Hashable, Codable {

    public let bundleID: String

    /// The window title's letters, lowercased, as `LabelText.letters` reads them.
    public let windowFamily: String

    /// The context of a window, or nil when the bundle is empty or a process fallback, or the title
    /// has no letters.
    public init?(bundleID: String, windowTitle: String) {
        guard !bundleID.isEmpty, !Self.isProcessFallback(bundleID) else { return nil }
        let family = LabelText.letters(windowTitle)
        guard !family.isEmpty else { return nil }
        self.bundleID     = bundleID
        self.windowFamily = family
    }

    /// Whether the identifier is the runtime's stand-in for an application without a bundle
    /// identifier, `pid.` followed by the process number.
    public static func isProcessFallback(_ bundleID: String) -> Bool {
        guard bundleID.hasPrefix("pid.") else { return false }
        let number = bundleID.dropFirst(4)
        return !number.isEmpty && number.allSatisfy(\.isNumber)
    }
}
