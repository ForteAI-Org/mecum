//
//  ProbePageContractTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import Foundation
import SeatCore
import Testing

/// The page and its reader must agree before a browser is launched. A renamed
/// title marker otherwise makes every browser row disappear from the matrix.
@MainActor
struct ProbePageContractTests {

    @Test("the probe page publishes the marker used to discover its browser window")
    func probePageTitleMatchesDiscovery() throws {
        let page = try #require(Bundle.module.url(forResource: "probe-page", withExtension: "html"))
        let html = try String(contentsOf: page, encoding: .utf8)
        #expect(html.contains("<title>\(ChromeTarget.titleMark)"))
        #expect(html.contains("document.title=`\(ChromeTarget.titleMark)"))
    }

    @Test("the page publishes a code for every shortcut the matrix drives")
    func probePagePublishesEveryShortcutCode() throws {
        let page = try #require(Bundle.module.url(forResource: "probe-page", withExtension: "html"))
        let html = try String(contentsOf: page, encoding: .utf8)

        // A code the page never emits is a row that can only read `--` and fail
        // for the wrong reason, which is worse than no row at all.
        for code in ShortcutRow.allCases.map(\.code) {
            #expect(html.contains("return'\(code)'"), "the page emits no code \(code)")
        }
    }

    @Test("the title stays well under the length the window server elides")
    func probePageTitleFitsTheBudget() throws {
        let page = try #require(Bundle.module.url(forResource: "probe-page", withExtension: "html"))
        let html = try String(contentsOf: page, encoding: .utf8)
        let initial = try #require(
            html.split(separator: "<title>").last?.split(separator: "<").first
        )

        // A title of 60 characters came back from the window server as
        // `w=24…ag=0`, which reads as a missing counter rather than as the
        // truncation it is. The shortcut channel costs fifteen characters and
        // the counters of a matrix run stay small.
        #expect(initial.count <= 56, "the starting title is already \(initial.count) characters")
        let loaded = "AS c=999,9999,-9999,9999,8192,8192,16384,cZ,cZ,99,15,1"
        #expect(loaded.count <= 56)
        #expect(ChromeTarget.parseState(String(initial))["field"] == 0)
        #expect(ChromeTarget.parseState(loaded)["field"] == 16384)
        #expect(ChromeTarget.parseState(loaded)["lastModifiers"] == 15)
        #expect(ChromeTarget.parseState(loaded.replacingOccurrences(of: "16384", with: "16…84")).isEmpty)
        #expect(ChromeTarget.parseState("AS c=0,0,0").isEmpty)
    }

    @Test("the modifier mask the page publishes uses the kit's own bit order")
    func probePageModifierMaskMatchesModifiers() throws {
        let page = try #require(Bundle.module.url(forResource: "probe-page", withExtension: "html"))
        let html = try String(contentsOf: page, encoding: .utf8)

        // A page counting bits in its own order would make every isolation row
        // read a different modifier from the one that was posted, which is the
        // kind of disagreement that looks like a driver bug for a week.
        #expect(html.contains("e.metaKey?\(Modifiers.command.rawValue):0"))
        #expect(html.contains("e.shiftKey?\(Modifiers.shift.rawValue):0"))
        #expect(html.contains("e.altKey?\(Modifiers.option.rawValue):0"))
        #expect(html.contains("e.ctrlKey?\(Modifiers.control.rawValue):0"))
    }
}
