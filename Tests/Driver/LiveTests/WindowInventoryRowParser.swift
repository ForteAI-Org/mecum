//
//  WindowInventoryRowParser.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import CoreGraphics
import Foundation

/// InventoryRowsResponse is what a window list reader answered, in the shape the
/// real one produces: the same array of dictionaries `CGWindowListCopyWindowInfo`
/// hands back, or the reason there is no array.
///
/// It carries `Any` values on purpose. The parser is tested against exactly the
/// structures the native reader produces, so an offline test cannot pass on a
/// tidier type than the one the probe will really meet.
enum InventoryRowsResponse {

    /// The elements of the answered array, each of which is *expected* to be a
    /// dictionary and none of which is assumed to be one. The elements are kept
    /// as `Any` so a single element of the wrong shape is counted as one
    /// malformed row instead of destroying the count, the discards and the
    /// fixture's own rows of the whole list.
    case rows([Any])

    /// The API answered `nil`.
    case absentList

    /// The answer could not be converted into rows. Never an empty list.
    case failed(String)

    /// The reading was not performed.
    case unavailable(String)
}

/// WindowInventoryRowParser turns one window list into a digest, keeping the
/// rows of the fixture's own windows and only counters for everything else.
///
/// It reads no API and holds no state: the caller passes the rows in, which is
/// what lets the whole of it be exercised offline against nil, empty, partial
/// and malformed lists. Membership is decided by the Window IDs the fixture
/// registered *and* the owning PID together, so a Window ID the server handed
/// out again does not walk into the fixture's rows.
///
/// A boolean is not a number here. `CFBoolean` bridges to `NSNumber`, so reading
/// a numeric field through `NSNumber` alone turns `true` into the layer 1,
/// `false` into the alpha 0 and a `Width` of `true` into one point of width:
/// data nobody observed, wearing the shape of a measurement. Every numeric field
/// therefore rejects a `CFBoolean` *before* any value is taken out of it, and the
/// test for it is the CoreFoundation type, not `value is Bool`, which also
/// answers true for numeric `NSNumber`s. A boolean is admitted in the on-screen
/// flag alone, which is the only field the list carries one for.
struct WindowInventoryRowParser {

    /// The Window IDs the fixture registered for its own `NSWindow` objects.
    let fixtureWindowIDs: Set<Int>

    /// The PID of the process the fixture lives in.
    let fixtureProcessID: Int

    static let windowNumberKey = kCGWindowNumber as String
    static let ownerPIDKey     = kCGWindowOwnerPID as String
    static let boundsKey       = kCGWindowBounds as String
    static let layerKey        = kCGWindowLayer as String
    static let alphaKey        = kCGWindowAlpha as String
    static let onScreenKey     = kCGWindowIsOnscreen as String

    /// One field of a row: absent, present and unusable, or present and usable.
    /// The three are kept apart because collapsing the first two is exactly how
    /// a missing attribute becomes a zero.
    private enum Field<Value> {

        case absent
        case invalid
        case value(Value)
    }

    func outcome(of response: InventoryRowsResponse) -> InventoryReadingOutcome {
        switch response {
        case .rows(let rows)      : return .received(digest(of: rows))
        case .absentList          : return .absentList("the window list API answered nil")
        case .failed(let detail)  : return .failed(detail)
        case .unavailable(let why): return .unavailable(why)
        }
    }

    func digest(of rows: [Any]) -> InventoryRowsDigest {

        var fixtureRows: [FixtureWindowRow]            = []
        var discards   : [InventoryDiscardReason: Int] = [:]
        var gaps       : [InventoryDiscardReason: Int] = [:]
        var foreign                                    = 0

        for element in rows {
            // An element that is not an addressable dictionary is one malformed
            // row. The rest of the list keeps being parsed and counted.
            guard let row = element as? [String: Any], !row.isEmpty else {
                discards[.malformedRow, default: 0] += 1
                continue
            }

            let windowIDField = identifierField(row[Self.windowNumberKey])
            let processField  = identifierField(row[Self.ownerPIDKey])

            if case .invalid = windowIDField {
                discards[.invalidValue, default: 0] += 1
                continue
            }
            if case .invalid = processField {
                discards[.invalidValue, default: 0] += 1
                continue
            }
            guard case .value(let windowID) = windowIDField,
                  case .value(let processID) = processField
            else {
                discards[.missingIdentity, default: 0] += 1
                continue
            }

            guard fixtureWindowIDs.contains(windowID) else {
                // Redaction: a window the probe does not own contributes a
                // count and nothing else, whoever it belongs to.
                if processID == fixtureProcessID { discards[.unattributableRow, default: 0] += 1 }
                else                             { foreign += 1 }
                continue
            }
            guard processID == fixtureProcessID else {
                discards[.identityMismatch, default: 0] += 1
                continue
            }

            guard let parsed = fixtureRow(row, windowID: windowID, processID: processID, gaps: &gaps)
            else {
                discards[.invalidValue, default: 0] += 1
                continue
            }
            fixtureRows.append(parsed)
        }

        return InventoryRowsDigest(
            rowCount       : rows.count,
            fixtureRows    : fixtureRows,
            foreignRowCount: foreign,
            discards       : InventoryDiscardTally.tallies(discards),
            gaps           : InventoryDiscardTally.tallies(gaps)
        )
    }

    /// One row of a fixture window, or nil when a value it did carry is unusable.
    /// A value that is absent leaves its field absent and adds a gap; a value
    /// that is present and wrong rejects the row instead of being repaired.
    private func fixtureRow(
        _ row    : [String: Any],
        windowID : Int,
        processID: Int,
        gaps     : inout [InventoryDiscardReason: Int]
    ) -> FixtureWindowRow? {

        var missing: [String] = []

        var bounds: WindowBoundsRecord?
        switch boundsField(row[Self.boundsKey]) {
        case .value(let record): bounds = record
        case .absent           : missing.append(FixtureWindowRow.boundsAttribute)
        case .invalid          : return nil
        }

        var layer: Int?
        switch layerField(row[Self.layerKey]) {
        case .value(let number): layer = number
        case .absent           : missing.append(FixtureWindowRow.layerAttribute)
        case .invalid          : return nil
        }

        var alpha: Double?
        switch alphaField(row[Self.alphaKey]) {
        case .value(let number): alpha = number
        case .absent           : missing.append(FixtureWindowRow.alphaAttribute)
        case .invalid          : return nil
        }

        var isOnScreen: Bool?
        switch booleanField(row[Self.onScreenKey]) {
        case .value(let flag): isOnScreen = flag
        case .absent         : missing.append(FixtureWindowRow.onScreenAttribute)
        case .invalid        : return nil
        }

        if !missing.isEmpty { gaps[.missingAttribute, default: 0] += missing.count }

        return FixtureWindowRow(
            observed        : ObservedWindowIdentity(windowID: windowID, processID: processID),
            bounds          : bounds,
            layer           : layer,
            alpha           : alpha,
            isOnScreen      : isOnScreen,
            missingAttributes: missing
        )
    }

    // MARK: Booleans are not numbers

    /// The `Bool` a value carries when, and only when, it is a `CFBoolean`.
    ///
    /// The test is `CFGetTypeID` against `CFBooleanGetTypeID()`, because that is
    /// the type a `Bool` and a `kCFBooleanTrue` in a CoreGraphics row both have,
    /// and because `value is Bool` is *also* true for numeric `NSNumber`s
    /// bridged out of a plist-like dictionary. Answering nil here means the
    /// value is not a boolean, whatever else it may be.
    private static func booleanValue(_ value: Any) -> Bool? {
        let object = value as AnyObject
        guard CFGetTypeID(object) == CFBooleanGetTypeID(),
              let number = object as? NSNumber
        else { return nil }
        return number.boolValue
    }

    /// The `NSNumber` of a numeric field, refusing a `CFBoolean` before any
    /// value is extracted from it. `true` is not the layer 1, `false` is not the
    /// alpha 0 and a `Width` of `true` is not one point of width.
    private static func numericValue(_ value: Any) -> NSNumber? {
        guard booleanValue(value) == nil else { return nil }
        return value as? NSNumber
    }

    // MARK: Fields

    /// A Window ID or a PID: a whole number above zero. Zero and negatives are
    /// rejected rather than carried, since neither names a window or a process
    /// this probe may attribute anything to.
    private func identifierField(_ value: Any?) -> Field<Int> {
        switch wholeNumberField(value) {
        case .value(let number): return number > 0 ? .value(number) : .invalid
        case .absent           : return .absent
        case .invalid          : return .invalid
        }
    }

    private func layerField(_ value: Any?) -> Field<Int> {
        wholeNumberField(value)
    }

    /// A whole number, as a Window ID, a PID and a layer all are. A fractional
    /// value is rejected rather than truncated: 901.5 is not window 901, and
    /// letting `intValue` decide would attribute a row nobody measured to a
    /// window of the fixture. A boolean is not a whole number here, however
    /// willingly `NSNumber` would hand one over as 1 or 0.
    private func wholeNumberField(_ value: Any?) -> Field<Int> {
        guard let value else { return .absent }
        guard let number = Self.numericValue(value) else { return .invalid }
        let approximate = number.doubleValue
        guard approximate.isFinite,
              approximate >= Double(Int32.min), approximate <= Double(Int32.max),
              approximate == approximate.rounded(.towardZero)
        else { return .invalid }
        return .value(Int(approximate))
    }

    /// Alpha as the list carries it: a finite number in zero through one. A
    /// value outside that range is a value the probe does not understand, and
    /// clamping it would invent a transparency nobody measured. A boolean is
    /// rejected here too: `false` is not a fully transparent window.
    private func alphaField(_ value: Any?) -> Field<Double> {
        guard let value else { return .absent }
        guard let number = Self.numericValue(value) else { return .invalid }
        let alpha = number.doubleValue
        guard alpha.isFinite, alpha >= 0, alpha <= 1 else { return .invalid }
        return .value(alpha)
    }

    /// A flag as the list carries it: a `CFBoolean`, or a number that is exactly
    /// zero or one. Anything else is a value this probe does not understand, and
    /// `boolValue` would read an infinity or a 2 as a confident `true` about a
    /// window nobody observed that way. This is the only field of the row where a
    /// boolean is admitted at all.
    private func booleanField(_ value: Any?) -> Field<Bool> {
        guard let value else { return .absent }
        if let flag = Self.booleanValue(value) { return .value(flag) }
        guard let number = value as? NSNumber else { return .invalid }
        let approximate = number.doubleValue
        guard approximate.isFinite else { return .invalid }
        switch approximate {
        case 0 : return .value(false)
        case 1 : return .value(true)
        default: return .invalid
        }
    }

    /// The bounds rectangle, whose four measures are numbers and never booleans:
    /// a `Width` of `true` would otherwise become a window one point wide.
    private func boundsField(_ value: Any?) -> Field<WindowBoundsRecord> {
        guard let value else { return .absent }
        guard let dictionary = value as? [String: Any] else { return .invalid }

        var numbers: [String: Double] = [:]
        for key in ["X", "Y", "Width", "Height"] {
            guard let raw = dictionary[key] else { return .invalid }
            guard let number = Self.numericValue(raw) else { return .invalid }
            let measure = number.doubleValue
            guard measure.isFinite else { return .invalid }
            numbers[key] = measure
        }
        guard let x = numbers["X"], let y = numbers["Y"],
              let width = numbers["Width"], let height = numbers["Height"],
              width >= 0, height >= 0
        else { return .invalid }

        return .value(WindowBoundsRecord(x: x, y: y, width: width, height: height))
    }
}
