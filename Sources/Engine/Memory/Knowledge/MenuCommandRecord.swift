//
//  MenuCommandRecord.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import Foundation

/// MenuCommandRecord is one menu command as the living memory keeps it: an identity the producer
/// chose (`menuCommandID`), the application it belongs to, and the fields a read-only enumeration
/// observed, `MenuCommand`'s, with its two sightings as canonical milliseconds (`BrainClock`).
///
/// The identity is the id, never the path and never the accessibility identifier: two commands
/// whose paths join to the same `MenuCommand.key` (`["A/B", "C"]` and `["A", "B/C"]`) are two
/// records, and an application may give one identifier to many items. `pathKey` is that joined key,
/// a search hint and nothing more. Texts are kept and compared byte for byte, an absent optional
/// apart from an empty text, the path in its order. Recording a command certifies no effect.
///
/// The type has no `==`: two records are compared with `isExactly(_:)`.
public struct MenuCommandRecord: Sendable {

    public let menuCommandID: String
    public let bundleID: String
    public let path: [String]
    public let topLevelTitle: String
    public let identifier: String?
    public let hasSubmenu: Bool
    public let enabled: Bool
    public let markChar: String?
    public let cmdChar: String?
    public let firstSeenMS: Int64
    public let lastSeenMS: Int64

    /// A record from its stored values, refused when no store should keep it: an empty id or
    /// bundle, no path, a sighting outside the clock's range, or a last sighting before the first.
    public init(
        menuCommandID: String,
        bundleID     : String,
        path         : [String],
        topLevelTitle: String,
        identifier   : String?,
        hasSubmenu   : Bool,
        enabled      : Bool,
        markChar     : String?,
        cmdChar      : String?,
        firstSeenMS  : Int64,
        lastSeenMS   : Int64
    ) throws {
        func refuse(_ invalidity: MenuCommandError.Invalidity) -> MenuCommandError { .invalidRecord(invalidity) }
        if menuCommandID.isEmpty { throw refuse(.emptyID) }
        if bundleID.isEmpty { throw refuse(.emptyBundleID) }
        if path.isEmpty { throw refuse(.emptyPath) }
        for instant in [firstSeenMS, lastSeenMS] where !BrainClock.range.contains(instant) {
            throw refuse(.clock(.millisecondsOutOfRange(instant)))
        }
        if lastSeenMS < firstSeenMS { throw refuse(.lastSeenBeforeFirst) }
        self.menuCommandID = menuCommandID
        self.bundleID      = bundleID
        self.path          = path
        self.topLevelTitle = topLevelTitle
        self.identifier    = identifier
        self.hasSubmenu    = hasSubmenu
        self.enabled       = enabled
        self.markChar      = markChar
        self.cmdChar       = cmdChar
        self.firstSeenMS   = firstSeenMS
        self.lastSeenMS    = lastSeenMS
    }

    /// The record of an enumerated command under the identity given: every field as it is, the
    /// two sightings quantized once to canonical milliseconds (nearest, ties away from zero); a date
    /// that is not finite or lies outside the clock's range is a typed refusal, never clamped.
    public init(menuCommandID: String, bundleID: String, command: MenuCommand) throws {
        func milliseconds(_ date: Date) throws -> Int64 {
            do { return try BrainClock.milliseconds(of: date) } catch let problem as BrainClock.Problem {
                throw MenuCommandError.invalidRecord(.clock(problem))
            }
        }
        try self.init(
            menuCommandID: menuCommandID, bundleID: bundleID, path: command.path, topLevelTitle: command.topLevelTitle,
            identifier: command.identifier, hasSubmenu: command.hasSubmenu, enabled: command.enabled,
            markChar: command.markChar, cmdChar: command.cmdChar,
            firstSeenMS: try milliseconds(command.firstSeen), lastSeenMS: try milliseconds(command.lastSeen)
        )
    }

    /// The command as the previous model reads it, every field kept, the sightings as their
    /// canonical `Date`s.
    public var command: MenuCommand {
        MenuCommand(
            path: path, topLevelTitle: topLevelTitle, identifier: identifier, hasSubmenu: hasSubmenu, enabled: enabled,
            markChar: markChar, cmdChar: cmdChar,
            firstSeen: Date(timeIntervalSince1970: Double(firstSeenMS) / 1000),
            lastSeen: Date(timeIntervalSince1970: Double(lastSeenMS) / 1000)
        )
    }

    /// The path joined as `MenuCommand.key` joins it: a search hint, not an identity.
    public var pathKey: String { path.joined(separator: "/") }

    /// Whether the other record is this one exactly: every text byte for byte, an absent optional
    /// apart from an empty text, the path in order, every flag and instant.
    public func isExactly(_ other: MenuCommandRecord) -> Bool {
        sameIdentity(as: other) && sameText(identifier, other.identifier) && hasSubmenu == other.hasSubmenu
            && enabled == other.enabled && sameText(markChar, other.markChar) && sameText(cmdChar, other.cmdChar)
            && topLevelTitle.utf8.elementsEqual(other.topLevelTitle.utf8) && lastSeenMS == other.lastSeenMS
    }

    /// Whether the other record names the same command, as an update must keep it: the id, the
    /// application, the path and the first sighting.
    public func sameIdentity(as other: MenuCommandRecord) -> Bool {
        menuCommandID.utf8.elementsEqual(other.menuCommandID.utf8) && bundleID.utf8.elementsEqual(other.bundleID.utf8)
            && path.count == other.path.count && zip(path, other.path).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
            && firstSeenMS == other.firstSeenMS
    }

    private func sameText(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
            case (nil, nil)       : true
            case (let a?, let b?) : a.utf8.elementsEqual(b.utf8)
            default               : false
        }
    }
}

/// MenuCommandError is a menu command the store refuses to write or to read.
public enum MenuCommandError: Error, Sendable, Equatable {

    /// A record no store should keep.
    case invalidRecord(Invalidity)

    /// An update whose expected record is not the stored one: another writer moved it first.
    case staleExpectation(menuCommandID: String)

    /// An update that would change what names the command: the id, the application, the path or
    /// the first sighting.
    case immutableField(menuCommandID: String, field: String)

    /// An update that would move the last sighting back.
    case lastSeenBackwards(menuCommandID: String)

    /// An update of a command the store does not hold.
    case missingCommand(menuCommandID: String)

    /// A stored command whose rows break the contract.
    case malformedRow(menuCommandID: String, malformation: Malformation)

    public enum Invalidity: Sendable, Equatable {
        case emptyID
        case emptyBundleID
        case emptyPath
        case lastSeenBeforeFirst
        case clock(BrainClock.Problem)
    }

    public enum Malformation: Sendable, Equatable {
        case noSegments
        case segmentsNotContiguous
        case pathKeyMismatch
        case millisecondsOutOfRange(Int64)
        case lastSeenBeforeFirst
    }
}
