//
//  WebBrowsers.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/09/2026.
//

import AppKit

/// WebBrowsers answers which applications are web browsers and which one is the person's: a
/// browser is any application Launch Services registers to open https, and the person's default
/// is the one it opens https with. Both are read from Launch Services on every call, so a default
/// the person changes is seen at once; nothing is opened.
public enum WebBrowsers {

    /// Only the scheme is looked up: no page is loaded.
    private static let web = URL(string: "https://example.com")

    /// The bundle identifiers of every application registered to open https.
    public static func bundleIDs() -> Set<String> {
        guard let web else { return [] }
        return Set(NSWorkspace.shared.urlsForApplications(toOpen: web).compactMap { Bundle(url: $0)?.bundleIdentifier })
    }

    /// The bundle identifier of the application that opens https by default, or nil when none does.
    public static func defaultBundleID() -> String? {
        web.flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }.flatMap { Bundle(url: $0)?.bundleIdentifier }
    }
}
