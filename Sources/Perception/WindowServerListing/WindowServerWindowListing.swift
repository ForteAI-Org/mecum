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
        try rows(ownedBy: processID, options: [.optionOnScreenOnly, .excludeDesktopElements])
    }

    public func allWindows(ownedBy processID: pid_t) throws -> [WindowRow]? {
        try rows(ownedBy: processID, options: .optionAll)
    }

    private func rows(ownedBy processID: pid_t, options: CGWindowListOption) throws -> [WindowRow] {
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else {
            throw WindowListingFailure.windowServerUnavailable
        }
        var rows: [WindowRow] = []
        for info in list {
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t else {
                throw WindowListingFailure.windowServerUnavailable
            }
            guard owner == processID else { continue }
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let number = info[kCGWindowNumber as String] as? Int, number > 0 else {
                throw WindowListingFailure.windowServerUnavailable
            }
            var frame = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &frame) else {
                throw WindowListingFailure.windowServerUnavailable
            }
            rows.append(WindowRow(
                layer : layer,
                frame : frame,
                title : info[kCGWindowName as String] as? String,
                number: number
            ))
        }
        return rows
    }
}

/// WindowListingFailure is the one way the window server can refuse a list.
public enum WindowListingFailure: Error, Sendable, Equatable {
    case windowServerUnavailable
}
