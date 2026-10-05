//
//  Support.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import AutomationRuntime
import CoreGraphics
import EngineCore
import Foundation
import Memory
import PerceptionCore
import SQLite3
import Testing

/// ExternalWriter is a connection of another process's kind on an archive, holding its write lock from
/// `BEGIN IMMEDIATE` until `release`. It stands in for another Mecum process writing, in the proofs
/// of ordinary contention.
final class ExternalWriter {
    private var handle: OpaquePointer?

    init(_ url: URL) throws {
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        handle = db
    }

    func lock() {
        #expect(sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
    }

    /// Takes the exclusive lock, which in a file not in WAL keeps readers out too.
    func lockExclusively() {
        #expect(sqlite3_exec(handle, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK)
    }

    /// Ends the transaction and the connection: the lock goes, for good.
    func release() {
        guard let handle else { return }
        sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
        sqlite3_close(handle)
        self.handle = nil
    }
}

/// Fixtures for the composition root's tests: a fresh directory per test, a window with elements the
/// brain anchors and a capture the memory stores as complete, and a context as the tools make one.
enum Fixtures {

    static let bundle = "test.runtime.app"
    static let app    = AppContextIdentity(bundleID: bundle, version: "1.0")

    /// A directory nothing else uses, not yet created: the service creates it.
    static func directory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mecum-runtime-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Knowledge", isDirectory: true)
    }

    /// A directory that cannot be created: its parent is a file.
    static func blockedDirectory() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("mecum-blocked-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: parent)
        return parent.appendingPathComponent("Knowledge", isDirectory: true)
    }

    static func element(_ label: String, x: Double, y: Double = 0.1) -> SceneElement {
        SceneElement(id: "control|\(label.lowercased())", kind: .control, label: label,
                     bounds: NormalizedRect(x: x, y: y, width: 0.1, height: 0.05), role: "AXButton")
    }

    static func scene(_ labels: [String], title: String = "Export Settings") -> SceneSnapshot {
        SceneSnapshot(bundleID: bundle, appName: "Test", windowTitle: title,
                      viewportPixelSize: ViewportPixelSize(width: 1000, height: 800),
                      elements: labels.enumerated().map { element($1, x: 0.1 + Double($0) * 0.2) })
    }

    static let complete = CaptureQuality(walkCompleted: true, windowFound: true, isGrantAvailable: true,
                                         windowRole: "AXWindow", nodesVisited: 12, elementsEmitted: 3)

    static func window(_ labels: [String], title: String = "Export Settings", quality: CaptureQuality = complete,
                       surface: CaptureSurface = .window) -> PerceivedWindow {
        PerceivedWindow(scene: scene(labels, title: title), frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                        capture: quality, surface: surface)
    }

    static func context(_ eventID: String = UUID().uuidString, session: String? = "5D0C2F2E-0000-4000-8000-000000000001")
        -> ActionContext {
        ActionContext(eventID: eventID, source: .app, streamID: "worker-1", traceID: "trace-1", sessionID: session)
    }

    /// Records the call the context names, planned, as the tools do before the session runs it.
    static func plan(_ request: AgentCallRequest, _ context: ActionContext, in memory: MemoryService) async throws {
        _ = try await memory.record(try AgentCallRecord(
            event: context.event(app: app, occurredAtMS: memory.clock.calendarMS()), request: request
        ))
    }
}
