//
//  MenuCommandRecordTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import Foundation
@testable import Memory
import Testing

/// A menu command as the living memory keeps it: an explicit identity, the observed fields as they
/// are, the sightings as canonical milliseconds, an exact comparison, and the old model's key kept
/// apart from the identity it never was.
@Suite("A stored menu command: identity, fields, sightings")
struct MenuCommandRecordTests {

    private func command(_ path: [String], identifier: String? = "_NS:42", first: Double = 1_700_000_000, last: Double = 1_700_000_100) -> MenuCommand {
        MenuCommand(path: path, topLevelTitle: path.first ?? "", identifier: identifier, hasSubmenu: false, enabled: true,
                    markChar: nil, cmdChar: "S", firstSeen: Date(timeIntervalSince1970: first), lastSeen: Date(timeIntervalSince1970: last))
    }

    @Test("an enumerated command keeps every field, its sightings quantized once to the nearest millisecond (BrainClock's rule, its ties proven in BrainClockTests), and reads back as the old model reads it")
    func fromTheEnumeration() throws {
        let enumerated = command(["File", "Save As…"], first: 1_700_000_000.0004, last: 1_700_000_000.0016)
        let record = try MenuCommandRecord(menuCommandID: "m1", bundleID: "test.app", command: enumerated)
        #expect(record.firstSeenMS == 1_700_000_000_000 && record.lastSeenMS == 1_700_000_000_002)
        let back = record.command
        #expect(back.path == enumerated.path && back.topLevelTitle == "File" && back.identifier == "_NS:42" && back.cmdChar == "S")
        #expect(back.markChar == nil && back.enabled && !back.hasSubmenu)
        let first = try BrainClock.canonical(enumerated.firstSeen), last = try BrainClock.canonical(enumerated.lastSeen)
        #expect(back.firstSeen == first && back.lastSeen == last)
        #expect(record.pathKey == enumerated.key)
    }

    @Test("a record no store should keep is refused with its reason: no id, no bundle, no path, a date that is not finite or out of range, a last sighting before the first")
    func refusals() {
        func refused(_ invalidity: MenuCommandError.Invalidity, _ make: () throws -> MenuCommandRecord) {
            #expect(throws: MenuCommandError.invalidRecord(invalidity)) { _ = try make() }
        }
        refused(.emptyID) { try MenuCommandRecord(menuCommandID: "", bundleID: "b", command: command(["A"])) }
        refused(.emptyBundleID) { try MenuCommandRecord(menuCommandID: "m", bundleID: "", command: command(["A"])) }
        refused(.emptyPath) { try MenuCommandRecord(menuCommandID: "m", bundleID: "b", command: command([])) }
        refused(.clock(.notFinite)) { try MenuCommandRecord(menuCommandID: "m", bundleID: "b", command: command(["A"], first: .nan)) }
        refused(.clock(.dateOutOfRange(seconds: 1e16))) { try MenuCommandRecord(menuCommandID: "m", bundleID: "b", command: command(["A"], last: 1e16)) }
        refused(.lastSeenBeforeFirst) { try MenuCommandRecord(menuCommandID: "m", bundleID: "b", command: command(["A"], first: 10, last: 9)) }
        refused(.clock(.millisecondsOutOfRange(1 << 51))) {
            try MenuCommandRecord(menuCommandID: "m", bundleID: "b", path: ["A"], topLevelTitle: "A", identifier: nil, hasSubmenu: false,
                                  enabled: true, markChar: nil, cmdChar: nil, firstSeenMS: 0, lastSeenMS: 1 << 51)
        }
    }

    @Test("the comparison is exact: bytes not Unicode equivalence, absent apart from empty, the path's order, every flag and instant")
    func exactComparison() throws {
        func record(_ path: [String] = ["Edit", "Café"], title: String = "Edit", identifier: String? = nil, submenu: Bool = false,
                    enabled: Bool = true, mark: String? = nil, shortcut: String? = "C", last: Int64 = 20) throws -> MenuCommandRecord {
            try MenuCommandRecord(menuCommandID: "m", bundleID: "b", path: path, topLevelTitle: title, identifier: identifier,
                                  hasSubmenu: submenu, enabled: enabled, markChar: mark, cmdChar: shortcut, firstSeenMS: 10, lastSeenMS: last)
        }
        let base = try record()
        #expect(base.isExactly(try record(["Edit", "Caf" + "é"])))
        let variants: [(String, MenuCommandRecord)] = [
            ("decomposed segment", try record(["Edit", "Cafe\u{301}"])), ("order", try record(["Café", "Edit"])),
            ("NUL", try record(["Edit", "Café\u{0}"])), ("title", try record(title: "Edit ")), ("identifier empty", try record(identifier: "")),
            ("submenu", try record(submenu: true)), ("disabled", try record(enabled: false)), ("mark empty", try record(mark: "")),
            ("no shortcut", try record(shortcut: nil)), ("last", try record(last: 21)),
        ]
        #expect("Cafe\u{301}" == "Café", "Swift's String equality would hide the first")
        for (name, variant) in variants { #expect(!base.isExactly(variant) && !variant.isExactly(base), Comment(rawValue: name)) }
    }

    @Test("the old key joins with '/': two distinct paths share it and the old merge keeps one; the stored identity is the id, so both are kept")
    func keyIsNotIdentity() throws {
        let slashInFirst = command(["A/B", "C"]), slashInSecond = command(["A", "B/C"])
        #expect(slashInFirst.key == slashInSecond.key && slashInFirst.path != slashInSecond.path)
        var knowledge = AppKnowledge(bundleID: "test.app")
        knowledge.observeMenus([slashInFirst, slashInSecond], now: Date(timeIntervalSince1970: 1_700_000_200))
        #expect(knowledge.menuCommands.count == 1, "the previous model's merge, left as it is")
        let one = try MenuCommandRecord(menuCommandID: "m1", bundleID: "test.app", command: slashInFirst)
        let two = try MenuCommandRecord(menuCommandID: "m2", bundleID: "test.app", command: slashInSecond)
        #expect(one.pathKey == two.pathKey && !one.isExactly(two) && !one.sameIdentity(as: two))
    }
}
