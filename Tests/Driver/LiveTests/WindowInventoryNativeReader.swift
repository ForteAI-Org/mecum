//
//  WindowInventoryNativeReader.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import CoreGraphics
import Foundation

/// InventoryRowsReading is the one place this probe touches a window list.
///
/// It exists so the run, the parser and the report can be exercised offline
/// against controlled answers while the Live suite plugs in the native reader
/// without changing a line of the logic under test. A conforming reader answers
/// what it got, including `nil` and a failed conversion, and never smooths an
/// error into an empty list.
@MainActor
protocol InventoryRowsReading {

    /// The API the rows come from, recorded as provenance in every reading.
    var apiName: String { get }

    /// The window the list is taken relative to, recorded for the same reason.
    var relativeToWindowID: UInt32 { get }

    func optionBits(for scope: InventoryReadingScope) -> UInt32

    func rows(scope: InventoryReadingScope) -> InventoryRowsResponse
}

/// WindowInventoryNativeReader calls `CGWindowListCopyWindowInfo` and hands the
/// answer on untouched.
///
/// Two facts about that call belong to every reading it produces. The list is
/// assembled from window server metadata for the whole session before any
/// filtering, so an `all` reading carries information about windows of other
/// applications, which is why the parser redacts everything the fixture does not
/// own. And `optionAll` includes surfaces that were never shown, so presence in
/// that list is not visibility and absence from `optionOnScreenOnly` is not a
/// closure.
///
/// The call is synchronous. A blocked call is not interrupted by any deadline
/// this probe keeps, and the report says so rather than implying a timeout it
/// cannot enforce.
@MainActor
struct WindowInventoryNativeReader: InventoryRowsReading {

    let apiName            = "CGWindowListCopyWindowInfo"
    let relativeToWindowID = kCGNullWindowID

    func optionBits(for scope: InventoryReadingScope) -> UInt32 {
        Self.options(for: scope).rawValue
    }

    func rows(scope: InventoryReadingScope) -> InventoryRowsResponse {
        guard let answer = CGWindowListCopyWindowInfo(Self.options(for: scope), kCGNullWindowID)
        else { return Self.response(for: nil) }
        return Self.response(for: answer as NSArray)
    }

    /// The answer of the API turned into a response, element by element.
    ///
    /// The elements are handed on as they arrived: an array holding one usable
    /// row and one element of another shape stays a list of two, so the parser
    /// counts one malformed row and still keeps the row of the fixture. Casting
    /// the whole answer to an array of dictionaries would have thrown away the
    /// count, the reasons and the usable rows of such a list at once.
    ///
    /// It is a separate function so an offline test can drive the very
    /// conversion the Live reading uses without calling the API.
    static func response(for answer: NSArray?) -> InventoryRowsResponse {
        guard let answer else { return .absentList }
        return .rows(Array(answer))
    }

    private static func options(for scope: InventoryReadingScope) -> CGWindowListOption {
        switch scope {
        case .all         : return [.optionAll, .excludeDesktopElements]
        case .onScreenOnly: return [.optionOnScreenOnly, .excludeDesktopElements]
        }
    }
}
