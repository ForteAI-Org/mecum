//
//  WindowSnapshots.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import ModelTransports
import SeatBroker
import SwiftUI
import TeamShell
import Workspace

/// WindowSnapshots draws the team window's content offscreen into PNGs for a
/// person to look at, when the app is launched with MECUM_SNAPSHOTS=1, then
/// quits. The files go to MECUM_SNAPSHOT_DIR, or under the temporary directory.
///
/// The real `TeamShellView` is hosted in a window that is never ordered on
/// screen and drawn with `cacheDisplay`, so it needs no Screen Recording grant
/// and Stage Manager has nothing to hide. The team is synthetic, in a store of
/// its own under the temporary directory; the person's workspace is not opened.
@MainActor
enum WindowSnapshots {

    static var isRequested: Bool { ProcessInfo.processInfo.environment["MECUM_SNAPSHOTS"] == "1" }

    /// Writes every snapshot, prints each path, and ends the process: 0 when
    /// all were written, 1 with the reason on standard error otherwise.
    static func writeAndQuit() async {
        let store = URL.temporaryDirectory.appending(path: "MecumWindowSnapshots-\(UUID().uuidString)",
                                                     directoryHint: .isDirectory)
        var status: Int32 = 0
        do {
            let team = try await syntheticTeam(in: store)
            let output = try directory()
            let cases: [(name: String, width: Double, dark: Bool, inspector: Bool)] = [
                ("1200-light", 1200, false, true), ("1200-dark", 1200, true, true),
                ("820-light", 820, false, true), ("820-dark", 820, true, true),
                ("820-light-inspector-closed", 820, false, false),
            ]
            for shot in cases {
                let hidesSidebar = shot.inspector && ShellMetrics.openingHidesSidebar(window: shot.width)
                let root = Root(team: team, isInspectorRequested: shot.inspector,
                                columns: hidesSidebar ? .detailOnly : .all)
                try await write(root, width: shot.width, dark: shot.dark,
                                to: output.appending(path: "window-\(shot.name).png"))
            }
            // The split's sidebar is glass and draws blank offscreen, so its rows are drawn alone too.
            for (name, dark) in [("light", false), ("dark", true)] {
                try await write(TeamSidebarView(team: team), width: ShellMetrics.sidebar.ideal, dark: dark,
                                to: output.appending(path: "sidebar-\(name).png"))
            }
            let badges = try await badgedTeam(in: store.appending(path: "Badges", directoryHint: .isDirectory))
            for (name, dark) in [("light", false), ("dark", true)] {
                try await write(TeamSidebarView(team: badges), width: ShellMetrics.sidebar.ideal, dark: dark,
                                to: output.appending(path: "sidebar-badges-\(name).png"))
            }
        } catch {
            FileHandle.standardError.write(Data("snapshots failed: \(error)\n".utf8))
            status = 1
        }
        // A leftover temporary store is reclaimed by the system; it must not change the exit status.
        do { try FileManager.default.removeItem(at: store) } catch {}
        exit(status)
    }

    private static func directory() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let directory   = environment["MECUM_SNAPSHOT_DIR"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? URL.temporaryDirectory.appending(path: "MecumWindowSnapshots", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: The team

    /// Three workers and Atlas's conversation: an earlier exchange, then one
    /// finished turn whose profile was changed afterwards, so the inspector has
    /// to show the turn's model and not the profile's.
    static func syntheticTeam(in directory: URL) async throws -> TeamModel {
        let store = try WorkspaceStore.opening(in: directory)
        let iris  = try await store.createWorker(name: "Iris", role: "Research lead",
                                                 appearance: WorkerAppearance(seed: 11, palette: "dusk"))
        let atlas = try await store.createWorker(name: "Atlas", role: "Release engineer",
                                                 appearance: WorkerAppearance(seed: 7, palette: "tide"))
        try await store.createWorker(name: "Nova", role: "Editor",
                                     appearance: WorkerAppearance(seed: 23, palette: "ember"))
        try await store.configure(worker: iris.id, selection: ModelSelection(
            provider: .claudeCode, model: "claude-opus-5", effort: .high))
        try await store.configure(worker: atlas.id, selection: ModelSelection(
            provider: .codex, model: "gpt-5.6-luna", effort: .high))

        let conversation = try await store.createConversation(kind: .direct, participants: [atlas.id])
        let origin = Date(timeIntervalSinceReferenceDate: 780_000_000)
        // An earlier exchange long enough that, opened at its end, older messages pass under the header.
        for index in 0..<8 {
            let asked = origin.addingTimeInterval(Double(index - 8) * 300)
            try await store.appendMessage(to: conversation.id, text: "Is step \(index + 1) of the release done?",
                                          at: asked, delivery: .completed)
            try await store.appendMessage(
                to: conversation.id, author: atlas.id,
                text: "Step \(index + 1) is done. The notes are in the release folder, "
                    + "and nothing is blocking the next one.",
                at: asked.addingTimeInterval(30), delivery: .completed)
        }
        let ask = try await store.appendMessage(
            to: conversation.id, text: "Can you check this morning's build and tell me what failed?",
            at: origin, delivery: .completed)
        let turn = try await store.startExecution(worker: atlas.id, conversation: conversation.id,
                                                  at: origin.addingTimeInterval(1))
        let workspaceID = UUID()
        func record(_ type: EventType, at seconds: Double, text: String? = nil) async throws {
            try await store.append(NewEvent(
                workspaceID: workspaceID, subjectID: turn.id, conversationID: conversation.id,
                workerID: atlas.id, timestamp: origin.addingTimeInterval(seconds), type: type,
                payload: text.map { Data($0.utf8) }, correlationID: ask.id))
        }
        try await record(.executionStarted, at: 1)
        try await record(.toolActivity, at: 2, text: "→ read_log {\"job\":\"nightly\"}")
        try await record(.toolActivity, at: 3, text: "← read_log 2 bundles failed")
        try await store.appendMessage(
            to: conversation.id, author: atlas.id,
            text: """
                The build finished at 07:42. Two bundles failed: the capture suite timed out once on \
                the virtual display, and the layout suite failed on a width assertion. The capture \
                timeout looks flaky; the width assertion is real and reproduces locally.
                """,
            at: origin.addingTimeInterval(20), delivery: .completed)
        try await record(.executionCompleted, at: 21)
        try await store.appendMessage(to: conversation.id, text: "Rerun the capture suite first.",
                                      at: origin.addingTimeInterval(90), delivery: .savedLocally)
        try await store.configure(worker: atlas.id, selection: ModelSelection(
            provider: .codex, model: "gpt-5.4-mini", effort: .low))

        let team = TeamModel(store: store, connections: ModelSettingsStore(), broker: SeatBroker())
        await team.load()
        team.selection = atlas.id
        await team.openSelectedConversation()
        return team
    }

    /// Four workers for the sidebar badge (§4.3): three unread replies, 120,
    /// a failed turn not yet seen, and one with nothing new. None is selected,
    /// so no conversation is on screen to mark read.
    static func badgedTeam(in directory: URL) async throws -> TeamModel {
        let store = try WorkspaceStore.opening(in: directory)
        let selection = ModelSelection(provider: .claudeCode, model: "claude-opus-5", effort: .high)
        let workspaceID = UUID()
        let people: [(name: String, role: String, seed: Int64, palette: String, replies: Int, fails: Bool)] = [
            ("Atlas", "Release engineer", 7, "tide", 3, false),
            ("Nova", "Editor", 23, "ember", 120, false),
            ("Iris", "Research lead", 11, "dusk", 0, true),
            ("Milo", "Designer", 31, "dawn", 0, false),
        ]
        for person in people {
            let worker = try await store.createWorker(name: person.name, role: person.role,
                                                      appearance: WorkerAppearance(seed: person.seed,
                                                                                   palette: person.palette))
            try await store.configure(worker: worker.id, selection: selection)
            let conversation = try await store.createConversation(kind: .direct, participants: [worker.id])
            for index in 0..<person.replies {
                try await store.appendMessage(to: conversation.id, author: worker.id, text: "Reply \(index)",
                                              delivery: .completed)
            }
            if person.fails {
                try await store.append(NewEvent(workspaceID: workspaceID, subjectID: UUID(),
                                                conversationID: conversation.id, workerID: worker.id,
                                                type: .executionFailed, payload: Data("timed out".utf8)))
            }
        }
        let team = TeamModel(store: store, connections: ModelSettingsStore(), broker: SeatBroker())
        await team.load()
        return team
    }

    // MARK: Drawing

    /// Hosts `content` at `width`, lets its tasks and the transcript settle,
    /// then draws the window's frame view, which holds the toolbar too.
    private static func write(_ content: some View, width: Double, dark: Bool, to file: URL) async throws {
        // Offscreen, SwiftUI resolves its colours in the app's appearance rather than the window's.
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: content
            .defaultAppStorage(UserDefaults(suiteName: "dev.forte.Mecum.snapshots") ?? .standard))
        hosting.sceneBridgingOptions = [.toolbars, .title]

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 720),
            styleMask  : [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing    : .buffered,
            defer      : false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.setContentSize(NSSize(width: width, height: 720))

        // SwiftUI lays out over several passes and the transcript loads off the main actor.
        for _ in 0..<20 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        let frame = window.contentView?.superview ?? hosting
        frame.layoutSubtreeIfNeeded()
        guard let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else {
            throw SnapshotFailure("no bitmap for \(file.lastPathComponent)")
        }
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotFailure("no PNG for \(file.lastPathComponent)")
        }
        try png.write(to: file)
        window.close()
        print("snapshot: \(file.path)")
    }

    private struct SnapshotFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// The window's memory as plain state, standing in for the scene storage
    /// `TeamWindowView` keeps.
    struct Root: View {
        let team: TeamModel
        @State var isInspectorRequested: Bool
        let columns: NavigationSplitViewVisibility

        var body: some View {
            TeamShellView(team: team, isInspectorRequested: $isInspectorRequested, columns: columns)
        }
    }
}
