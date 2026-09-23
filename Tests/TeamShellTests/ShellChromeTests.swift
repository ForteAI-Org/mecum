//
//  ShellChromeTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation
import Testing
import TeamShell
import Workspace

/// The window's chrome for the selected worker, read from workers made in a real store.
@Suite("The header, the window title and the toolbar")
struct ShellChromeTests {

    private static func withWorker(_ body: (WorkerSnapshot) throws -> Void) async throws {
        let directory = URL.temporaryDirectory.appending(path: "ShellChromeTests-\(UUID().uuidString)",
                                                         directoryHint: .isDirectory)
        // A leftover temporary directory must not fail the test it cleans up after.
        defer { do { try FileManager.default.removeItem(at: directory) } catch {} }
        let store  = try WorkspaceStore.opening(in: directory)
        let worker = try await store.createWorker(name: "Atlas", appearance: WorkerAppearance(seed: 7, palette: "tide"))
        try body(worker)
    }

    @Test("The header shows the selected worker, and there is none without a selection")
    func theHeaderFollowsTheSelection() async throws {
        #expect(ShellChrome.header(for: nil) == nil)
        try await Self.withWorker { worker in
            let header = try #require(ShellChrome.header(for: worker))
            #expect(header.workerID   == worker.id)
            #expect(header.name       == "Atlas")
            #expect(header.appearance == WorkerAppearance(seed: 7, palette: "tide"))
            #expect(header.accessibilityHint == "Shows Atlas's details")
        }
    }

    @Test("The window title is the selected worker's name, and the app's without one")
    func theWindowTitleFollowsTheWorker() async throws {
        #expect(ShellChrome.windowTitle(for: nil) == "Mecum")
        try await Self.withWorker { worker in
            #expect(ShellChrome.windowTitle(for: worker) == "Atlas")
        }
    }

    @Test("The toolbar holds only the sidebar and inspector toggles")
    func theToolbarHoldsOnlyTheToggles() {
        #expect(ShellChrome.toolbar == [.sidebarToggle, .inspectorToggle])
        #expect(Set(ShellChrome.toolbar) == Set(ShellChrome.ToolbarControl.allCases))
    }
}
