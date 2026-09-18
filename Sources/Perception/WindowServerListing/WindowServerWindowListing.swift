//
//  WindowServerWindowListing.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics
import Foundation
import PerceptionCore

/// WindowServerWindowListing fills `WindowListing` with the window server's on-screen list.
///
/// Titles are readable only with the Screen Recording grant; without it every title is nil, and
/// the classifier's untitled clause then declines to fire on its own.
public struct WindowServerWindowListing: WindowListing {

    public init() {}

    public func windows(ownedBy processID: pid_t) throws -> [WindowRow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else {
            throw WindowListingFailure.windowServerUnavailable
        }
        var rows: [WindowRow] = []
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == processID,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any] else { continue }
            var frame = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &frame) else { continue }
            rows.append(WindowRow(
                layer : layer,
                frame : frame,
                title : info[kCGWindowName as String] as? String,
                number: (info[kCGWindowNumber as String] as? Int) ?? 0
            ))
        }
        return rows
    }
}

/// WindowListingFailure is the one way the window server can refuse a list.
public enum WindowListingFailure: Error, Sendable, Equatable {
    case windowServerUnavailable
}
