//
//  MenuKnowledgeTests.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import Foundation
@testable import Memory
import Testing

@Suite("Menu knowledge")
struct MenuKnowledgeTests {

    private let t0 = Fixtures.t0, t1 = Fixtures.t1

    private func command(_ path: [String], id: String? = nil, submenu: Bool = false, now: Date) -> MenuCommand {
        MenuCommand(path: path, topLevelTitle: path.first ?? "", identifier: id, hasSubmenu: submenu,
                    firstSeen: now, lastSeen: now)
    }

    private func knowledge(_ paths: [[String]]) -> AppKnowledge {
        var app = AppKnowledge(bundleID: "com.avid.ProTools")
        app.observeMenus(paths.map { command($0, now: t0) }, now: t0)
        return app
    }

    @Test("match score is digit and phrase sensitive")
    func matchScore() {
        let quantize = command(["Edit", "Quantize"], now: t0)
        #expect(quantize.matchScore(query: "Quantize") == 3)
        #expect(command(["Edit", "Quantize to Grid…"], now: t0).matchScore(query: "Quantize") == 2)
        #expect(quantize.matchScore(query: "Quantize to Grid…") == 2)
        #expect(command(["Setup", "Playback Engine…"], now: t0).matchScore(query: "Quantize") == 0)
    }

    @Test("observing menus merges by key and preserves the first sighting")
    func observeMenus() throws {
        var app = AppKnowledge(bundleID: "com.x")
        app.observeMenus([command(["Setup", "Playback Engine…"], id: "pe", now: t0), command(["File", "Open…"], now: t0)], now: t0)
        #expect(app.menuCommands.count == 2)
        app.observeMenus([command(["Setup", "Playback Engine…"], id: "pe", now: t1), command(["Edit", "Undo"], now: t1)], now: t1)
        #expect(app.menuCommands.count == 3)
        let engine = try #require(app.menuCommands.first { $0.identifier == "pe" })
        #expect(engine.firstSeen == t0)
        #expect(engine.lastSeen == t1)
    }

    @Test("commands key on their path, never on a shared identifier")
    func sharedIdentifier() {
        var app = AppKnowledge(bundleID: "com.x")
        app.observeMenus([
            command(["Setup", "Playback Engine…"], id: "shared", now: t0),
            command(["Track", "New…"], id: "shared", now: t0),
            command(["Event", "Quantize"], id: "shared", now: t0),
        ], now: t0)
        #expect(app.menuCommands.count == 3)
    }

    @Test("the best command is unique-accept")
    func uniqueAccept() {
        var app = AppKnowledge(bundleID: "com.x")
        app.observeMenus([command(["Setup", "Playback Engine…"], now: t0), command(["File", "Open…"], now: t0)], now: t0)
        #expect(app.bestMenuCommand(for: "Playback Engine")?.path == ["Setup", "Playback Engine…"])
        #expect(app.bestMenuCommand(for: "nonexistent command") == nil)
        app.observeMenus([command(["Window", "Playback Engine Status", "Playback Engine"], now: t0)], now: t0)
        #expect(app.bestMenuCommand(for: "Playback Engine") == nil)
    }

    @Test("submenu parents are never returned and a swarm of children refuses")
    func parentsAndSwarms() {
        var app = AppKnowledge(bundleID: "com.x")
        app.observeMenus([
            command(["File", "Export"], submenu: true, now: t0),
            command(["File", "Export", "AAF..."], now: t0),
            command(["File", "Export", "Media..."], now: t0),
            command(["File", "Export", "Markers..."], now: t0),
        ], now: t0)
        #expect(app.bestMenuCommand(for: "export") == nil)
        #expect(app.bestMenuCommand(for: "export media")?.path == ["File", "Export", "Media..."])
    }

    @Test("a gesture description names no command, but is still worth suggesting")
    func coverageGate() {
        let app = knowledge([["Options", "Click"], ["Options", "Loop Playback"], ["Track", "New…"], ["File", "Open Session…"]])
        #expect(app.bestMenuCommand(for: "Option + Click Solo") == nil)
        #expect(app.menuSuggestion(for: "Option + Click Solo")?.path == ["Options", "Click"])
    }

    @Test("genuine queries still resolve through the coverage gate")
    func genuineQueries() {
        let app = knowledge([["Options", "Click"], ["Track", "New…"], ["File", "Export", "AAF…"],
                             ["Setup", "I/O…"], ["Filter", "Blur", "Gaussian Blur…"]])
        #expect(app.bestMenuCommand(for: "new track")?.path == ["Track", "New…"])
        #expect(app.bestMenuCommand(for: "gaussian blur")?.path == ["Filter", "Blur", "Gaussian Blur…"])
        #expect(app.bestMenuCommand(for: "setup")?.path == ["Setup", "I/O…"])
        #expect(app.bestMenuCommand(for: "click")?.path == ["Options", "Click"])
    }

    @Test("tokens scattered across a path do not execute")
    func scattered() {
        let app = knowledge([["Options", "Click"], ["Track", "New…"]])
        #expect(app.bestMenuCommand(for: "solo the click track please") == nil)
    }
}
