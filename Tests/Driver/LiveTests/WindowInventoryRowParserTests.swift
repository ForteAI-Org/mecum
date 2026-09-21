//
//  WindowInventoryRowParserTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import Foundation
import Testing

/// The parser of the window inventory probe, offline, against the very rows the
/// native reader produces.
///
/// No AppKit call, no `CGWindowListCopyWindowInfo` and no window anywhere in
/// this suite: every list is handed in. The cases are the ones a Live run cannot
/// be asked to produce on demand, and they are the ones that decide whether the
/// probe keeps a distinction or quietly loses it.
@MainActor
struct WindowInventoryRowParserTests {

    static let fixturePID  = 4242
    static let fixtureID   = 901
    static let otherID     = 902

    static var parser: WindowInventoryRowParser {
        WindowInventoryRowParser(
            fixtureWindowIDs: [fixtureID, otherID],
            fixtureProcessID: fixturePID
        )
    }

    /// A complete row of a fixture window, which the individual cases then break
    /// one field at a time.
    /// Every field is `Any?` because the point of most cases below is a value of
    /// the wrong type, the wrong range or the wrong shape in a field the probe
    /// reads.
    static func row(
        windowID : Any? = fixtureID,
        processID: Any? = fixturePID,
        bounds   : Any? = ["X": 12.0, "Y": 34.0, "Width": 320.0, "Height": 200.0] as [String: Double],
        layer    : Any? = 0,
        alpha    : Any? = 1.0,
        onScreen : Any? = true
    ) -> [String: Any] {
        var row: [String: Any] = [:]
        if let windowID  { row[WindowInventoryRowParser.windowNumberKey] = windowID }
        if let processID { row[WindowInventoryRowParser.ownerPIDKey]     = processID }
        if let bounds    { row[WindowInventoryRowParser.boundsKey]       = bounds }
        if let layer     { row[WindowInventoryRowParser.layerKey]        = layer }
        if let alpha     { row[WindowInventoryRowParser.alphaKey]        = alpha }
        if let onScreen  { row[WindowInventoryRowParser.onScreenKey]     = onScreen }
        return row
    }

    /// The bounds rectangle with one of its four measures replaced, so a case
    /// can put a boolean or a wrong type in exactly one of them.
    static func bounds(_ key: String, _ value: Any) -> [String: Any] {
        var rectangle: [String: Any] = ["X": 0.0, "Y": 0.0, "Width": 320.0, "Height": 200.0]
        rectangle[key] = value
        return rectangle
    }

    /// The elements are `Any`, exactly as the native reader hands them on, so a
    /// case here can hold an element that is not a dictionary at all.
    static func digest(_ rows: [Any]) -> InventoryRowsDigest {
        parser.digest(of: rows)
    }

    static func count(_ digest: InventoryRowsDigest, _ reason: InventoryDiscardReason) -> Int {
        digest.discards.first { $0.reason == reason }?.count ?? 0
    }

    // MARK: nil, empty and failed are three different answers

    @Test("a nil list, an empty list and a failed conversion stay three answers")
    func absentEmptyAndFailedAreDistinct() {
        let parser = Self.parser

        #expect(parser.outcome(of: .rows([])) == .received(
            InventoryRowsDigest(
                rowCount       : 0,
                fixtureRows    : [],
                foreignRowCount: 0,
                discards       : [],
                gaps           : []
            )
        ))

        guard case .absentList = parser.outcome(of: .absentList) else {
            Issue.record("a nil list must not be reported as a list")
            return
        }
        guard case .failed(let detail) = parser.outcome(of: .failed("bridging failed")) else {
            Issue.record("a conversion failure must not become an empty list")
            return
        }
        #expect(detail == "bridging failed")

        guard case .unavailable = parser.outcome(of: .unavailable("not performed")) else {
            Issue.record("a reading that never happened must not be reported as received")
            return
        }
    }

    // MARK: the fixture's own rows

    @Test("a complete row of a fixture window keeps its identifier, bounds, layer, alpha and flag")
    func completeFixtureRowIsKeptWhole() throws {
        let digest = Self.digest([Self.row()])
        #expect(digest.rowCount == 1)
        #expect(digest.foreignRowCount == 0)
        #expect(digest.discards.isEmpty)
        #expect(digest.gaps.isEmpty)

        let row = try #require(digest.fixtureRows.first)
        #expect(row.observed == ObservedWindowIdentity(windowID: Self.fixtureID,
                                                       processID: Self.fixturePID))
        #expect(row.bounds == WindowBoundsRecord(x: 12, y: 34, width: 320, height: 200))
        #expect(row.layer == 0)
        #expect(row.alpha == 1.0)
        #expect(row.isOnScreen == true)
        #expect(row.missingAttributes.isEmpty)
    }

    @Test("an absent attribute stays absent instead of becoming zero or false")
    func missingAttributesAreNotDefaulted() throws {
        let digest = Self.digest([Self.row(bounds: nil, layer: nil, alpha: nil, onScreen: nil)])
        let row    = try #require(digest.fixtureRows.first)

        #expect(row.bounds == nil)
        #expect(row.layer == nil)
        #expect(row.alpha == nil)
        #expect(row.isOnScreen == nil)
        #expect(row.missingAttributes.count == 4)
        #expect(digest.gaps == [InventoryDiscardTally(reason: .missingAttribute, count: 4)])
        #expect(digest.discards.isEmpty, "a gap is not a rejection")
    }

    @Test("a non finite number, a wrong type and an out of range value reject the row")
    func invalidValuesAreRejected() {
        let notFiniteAlpha = Self.digest([Self.row(alpha: Double.nan)])
        #expect(notFiniteAlpha.fixtureRows.isEmpty)
        #expect(Self.count(notFiniteAlpha, .invalidValue) == 1)

        let outOfRangeAlpha = Self.digest([Self.row(alpha: 2.0)])
        #expect(outOfRangeAlpha.fixtureRows.isEmpty)
        #expect(Self.count(outOfRangeAlpha, .invalidValue) == 1)

        let wrongTypeLayer = Self.digest([Self.row(layer: "front")])
        #expect(wrongTypeLayer.fixtureRows.isEmpty)
        #expect(Self.count(wrongTypeLayer, .invalidValue) == 1)

        let infiniteBounds = Self.digest([
            Self.row(bounds: ["X": 0.0, "Y": 0.0,
                              "Width": Double.infinity, "Height": 10.0] as [String: Double])
        ])
        #expect(infiniteBounds.fixtureRows.isEmpty)
        #expect(Self.count(infiniteBounds, .invalidValue) == 1)

        let negativeSize = Self.digest([
            Self.row(bounds: ["X": 0.0, "Y": 0.0,
                              "Width": -4.0, "Height": 10.0] as [String: Double])
        ])
        #expect(negativeSize.fixtureRows.isEmpty)
        #expect(Self.count(negativeSize, .invalidValue) == 1)

        let partialBounds = Self.digest([
            Self.row(bounds: ["X": 0.0, "Y": 0.0] as [String: Double])
        ])
        #expect(partialBounds.fixtureRows.isEmpty)
        #expect(Self.count(partialBounds, .invalidValue) == 1)

        let zeroWindowID = Self.digest([Self.row(windowID: 0)])
        #expect(zeroWindowID.fixtureRows.isEmpty)
        #expect(Self.count(zeroWindowID, .invalidValue) == 1)
    }

    // MARK: a Boolean is not a number

    /// The regression of `reject-invalid-numeric-coercions`, field by field.
    ///
    /// `CFBoolean` bridges to `NSNumber`, so a numeric field read through
    /// `NSNumber` alone answers 1 for `true` and 0 for `false`: the counterexamples
    /// are exactly `layer: true` becoming the layer 1, `alpha: false` becoming a
    /// fully transparent window and a `Width` of `true` becoming a window one
    /// point wide. None of those was measured by anybody, so each of them must
    /// reject its row before a value is taken out of it.
    @Test("a Boolean in a numeric field rejects the row instead of becoming 1 or 0")
    func booleansAreNeverCoercedIntoNumbers() {
        for flag in [true, false] {
            let comment = Comment(rawValue: "a \(flag) was coerced into a number")

            let windowID = Self.digest([Self.row(windowID: flag)])
            #expect(windowID.fixtureRows.isEmpty, comment)
            #expect(Self.count(windowID, .invalidValue) == 1, comment)

            let processID = Self.digest([Self.row(processID: flag)])
            #expect(processID.fixtureRows.isEmpty, comment)
            #expect(Self.count(processID, .invalidValue) == 1, comment)

            let layer = Self.digest([Self.row(layer: flag)])
            #expect(layer.fixtureRows.isEmpty, comment)
            #expect(Self.count(layer, .invalidValue) == 1, comment)

            let alpha = Self.digest([Self.row(alpha: flag)])
            #expect(alpha.fixtureRows.isEmpty, comment)
            #expect(Self.count(alpha, .invalidValue) == 1, comment)

            for key in ["X", "Y", "Width", "Height"] {
                let bounds = Self.digest([Self.row(bounds: Self.bounds(key, flag))])
                #expect(bounds.fixtureRows.isEmpty,
                        Comment(rawValue: "a \(flag) became the \(key) of a rectangle"))
                #expect(Self.count(bounds, .invalidValue) == 1,
                        Comment(rawValue: "a \(flag) in \(key) was not rejected"))
            }

            // The same value as it arrives from a CoreFoundation dictionary,
            // where a flag is an `NSNumber` that is a `CFBoolean`.
            let boxedLayer = Self.digest([Self.row(layer: NSNumber(value: flag))])
            #expect(boxedLayer.fixtureRows.isEmpty, comment)
            #expect(Self.count(boxedLayer, .invalidValue) == 1, comment)
        }
    }

    @Test("integral zero and one stay valid numbers in the fields that admit them")
    func integralNumbersAreStillAccepted() throws {
        for number in [0, 1] {
            let layer = Self.digest([Self.row(layer: number)])
            #expect(layer.fixtureRows.first?.layer == number,
                    Comment(rawValue: "the layer \(number) was rejected"))

            let alpha = Self.digest([Self.row(alpha: NSNumber(value: number))])
            #expect(alpha.fixtureRows.first?.alpha == Double(number),
                    Comment(rawValue: "the alpha \(number) was rejected"))

            let bounds = try #require(
                Self.digest([Self.row(bounds: Self.bounds("Width", number))]).fixtureRows.first
            )
            #expect(bounds.bounds?.width == Double(number))
        }

        // A Window ID and a PID of 1 are numbers as well, in a fixture whose
        // own identifiers happen to be those.
        let small  = WindowInventoryRowParser(fixtureWindowIDs: [1], fixtureProcessID: 1)
        let digest = small.digest(of: [Self.row(windowID: 1, processID: 1)])
        #expect(digest.fixtureRows.count == 1)
        #expect(digest.fixtureRows.first?.observed
            == ObservedWindowIdentity(windowID: 1, processID: 1))

        // And a Boolean in those same two fields is still refused.
        let booleanID = small.digest(of: [Self.row(windowID: true, processID: 1)])
        #expect(booleanID.fixtureRows.isEmpty, "true must not be read as window 1")
    }

    @Test("the on-screen flag is the only field where a Boolean is admitted")
    func theFlagFieldStillTakesABoolean() {
        #expect(Self.digest([Self.row(onScreen: true)]).fixtureRows.first?.isOnScreen == true)
        #expect(Self.digest([Self.row(onScreen: false)]).fixtureRows.first?.isOnScreen == false)
        #expect(Self.digest([Self.row(onScreen: NSNumber(value: true))])
            .fixtureRows.first?.isOnScreen == true)
    }

    @Test("a row without a Window ID or a PID is unattributable and never guessed")
    func missingIdentityIsCounted() {
        let withoutWindowID = Self.digest([Self.row(windowID: nil)])
        #expect(withoutWindowID.fixtureRows.isEmpty)
        #expect(Self.count(withoutWindowID, .missingIdentity) == 1)

        let withoutPID = Self.digest([Self.row(processID: nil)])
        #expect(withoutPID.fixtureRows.isEmpty)
        #expect(Self.count(withoutPID, .missingIdentity) == 1)
    }

    @Test("a fractional Window ID or PID is rejected instead of being truncated onto a window")
    func fractionalIdentifiersAreRejected() {
        let fractionalID = Self.digest([Self.row(windowID: 901.5)])
        #expect(fractionalID.fixtureRows.isEmpty, "901.5 is not window 901")
        #expect(Self.count(fractionalID, .invalidValue) == 1)

        let fractionalPID = Self.digest([Self.row(processID: 4242.5)])
        #expect(fractionalPID.fixtureRows.isEmpty, "4242.5 is not process 4242")
        #expect(Self.count(fractionalPID, .invalidValue) == 1)

        let fractionalLayer = Self.digest([Self.row(layer: 0.5)])
        #expect(fractionalLayer.fixtureRows.isEmpty)
        #expect(Self.count(fractionalLayer, .invalidValue) == 1)

        let notFiniteID = Self.digest([Self.row(windowID: Double.infinity)])
        #expect(notFiniteID.fixtureRows.isEmpty)
        #expect(Self.count(notFiniteID, .invalidValue) == 1)
    }

    @Test("a flag that is neither a boolean nor exactly zero or one is rejected, not read as true")
    func invalidFlagsAreRejected() {
        let outOfRange = Self.digest([Self.row(onScreen: 2)])
        #expect(outOfRange.fixtureRows.isEmpty)
        #expect(Self.count(outOfRange, .invalidValue) == 1)

        let notFinite = Self.digest([Self.row(onScreen: NSNumber(value: Double.infinity))])
        #expect(notFinite.fixtureRows.isEmpty)
        #expect(Self.count(notFinite, .invalidValue) == 1)

        let wrongType = Self.digest([Self.row(onScreen: "yes")])
        #expect(wrongType.fixtureRows.isEmpty)
        #expect(Self.count(wrongType, .invalidValue) == 1)

        // Zero and one are how the list carries a flag, and they stay usable.
        let zero = Self.digest([Self.row(onScreen: 0)])
        #expect(zero.fixtureRows.first?.isOnScreen == false)
        let one = Self.digest([Self.row(onScreen: 1)])
        #expect(one.fixtureRows.first?.isOnScreen == true)
    }

    // MARK: the shape the native reader hands on

    @Test("an element that is not a usable dictionary is counted as malformed")
    func malformedRowsAreCounted() {
        let digest = Self.digest([[String: Any](), [String: Any](), Self.row()])
        #expect(digest.rowCount == 3)
        #expect(digest.fixtureRows.count == 1)
        #expect(Self.count(digest, .malformedRow) == 2)
    }

    @Test("a mixed list from the native conversion keeps its count and its usable rows")
    func aMixedListIsNotLostWholesale() throws {
        // The very array shape the API can answer: one row of the fixture and
        // two elements that are not dictionaries at all.
        let answer: NSArray = [Self.row(), "not a dictionary", 7]

        guard case .rows(let elements) = WindowInventoryNativeReader.response(for: answer) else {
            Issue.record("a list with one bad element must not become a failed conversion")
            return
        }
        #expect(elements.count == 3)

        let digest = Self.digest(elements)
        #expect(digest.rowCount == 3, "one bad element must not erase the count of the list")
        #expect(digest.fixtureRows.count == 1, "one bad element must not erase a usable row")
        #expect(Self.count(digest, .malformedRow) == 2)

        guard case .absentList = WindowInventoryNativeReader.response(for: nil) else {
            Issue.record("a nil answer must stay a nil answer")
            return
        }
    }

    // MARK: redaction, reuse and attribution

    @Test("a window of another process is counted and nothing of it is kept")
    func foreignRowsAreRedacted() {
        let foreign = Self.row(windowID: 77, processID: 5150)
        let titled: [String: Any] = foreign.merging(
            ["kCGWindowName": "somebody's private document", "kCGWindowOwnerName": "Mail"],
            uniquingKeysWith: { first, _ in first }
        )
        let digest = Self.digest([titled, Self.row()])

        #expect(digest.foreignRowCount == 1)
        #expect(digest.fixtureRows.count == 1)
        #expect(digest.fixtureRows.allSatisfy { $0.observed.windowID == Self.fixtureID })

        // Nothing but counters survives for a window the probe does not own.
        let encoded = try? JSONEncoder().encode(digest)
        let text    = String(decoding: encoded ?? Data(), as: UTF8.self)
        #expect(!text.contains("private document"))
        #expect(!text.contains("Mail"))
        #expect(!text.contains("77"))
    }

    @Test("a row of this process that no token registered is counted, not attributed")
    func unattributableRowsAreCounted() {
        let digest = Self.digest([Self.row(windowID: 4096, processID: Self.fixturePID)])
        #expect(digest.fixtureRows.isEmpty)
        #expect(digest.foreignRowCount == 0)
        #expect(Self.count(digest, .unattributableRow) == 1)
    }

    @Test("a registered Window ID owned by another PID is a reuse and not the fixture's window")
    func reusedWindowIDDoesNotBecomeTheFixtureWindow() {
        let digest = Self.digest([Self.row(windowID: Self.fixtureID, processID: 5150)])
        #expect(digest.fixtureRows.isEmpty, "a reused Window ID must not prove continuity")
        #expect(Self.count(digest, .identityMismatch) == 1)
        #expect(digest.foreignRowCount == 0)
    }

    @Test("a partial list keeps its counts, so quantity is never lost in the reasons")
    func quantitiesSurviveAPartialList() {
        let digest = Self.digest([
            Self.row(),
            Self.row(windowID: Self.otherID, onScreen: nil),
            Self.row(windowID: 77, processID: 5150),
            Self.row(windowID: nil),
            [String: Any](),
            Self.row(alpha: Double.infinity),
        ])

        #expect(digest.rowCount == 6)
        #expect(digest.fixtureRows.count == 2)
        #expect(digest.foreignRowCount == 1)
        #expect(digest.rejectedRowCount == 3)
        #expect(Self.count(digest, .missingIdentity) == 1)
        #expect(Self.count(digest, .malformedRow) == 1)
        #expect(Self.count(digest, .invalidValue) == 1)
        #expect(digest.gaps == [InventoryDiscardTally(reason: .missingAttribute, count: 1)])
    }
}
