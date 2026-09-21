import XCTest
import CoreGraphics
@testable import LocatorCore

final class BehaviorLogTests: XCTestCase {
    /// `append` DUAL-WRITES: the SQLite interaction ledger is primary, the ndjson is the shareable copy.
    /// Only the ndjson honoured the injected directory, so every run of this test put five `com.x` /
    /// `btn4` / `ts = 0` rows into the operator's live memory — 1,175 of them by the time it was measured.
    /// Both halves now land in the store this test owns.
    func testAppendAndRecentTail() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let memory = LocatorMemory(directory: dir.appendingPathComponent("memory", isDirectory: true))
        let store = BehaviorStore(directory: dir, memory: memory)
        for i in 0..<5 {
            store.append(BehaviorEvent(ts: Date(timeIntervalSince1970: Double(i)), kind: "click",
                                       bundleID: "com.x", app: "X", label: "btn\(i)", pos: [0.1, 0.2]))
        }
        let last3 = store.recent(3)
        XCTAssertEqual(last3.count, 3)
        XCTAssertEqual(last3.map { $0.label }, ["btn2", "btn3", "btn4"])   // chronological tail
        XCTAssertTrue(last3[0].line().contains("click \"btn2\" in X"))
        // the primary write went to the INJECTED ledger, all five of them
        XCTAssertEqual(memory.recentTimeline(limit: 20).filter { $0.contains("btn") }.count, 5)
    }

    func testWorkflowPersistence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BehaviorStore(directory: dir)
        try store.addWorkflow(Workflow(name: "Export to TikTok", app: "com.adobe", summary: "render + publish",
                                       steps: ["click Export", "toggle TikTok on", "click Send"], created: Date(timeIntervalSince1970: 0)))
        let ws = store.loadWorkflows()
        XCTAssertEqual(ws.count, 1)
        XCTAssertEqual(ws.first?.name, "Export to TikTok")
        XCTAssertEqual(ws.first?.steps.count, 3)
    }

    func testSceneElementAtPicksSmallestContaining() {
        let scene = SceneSnapshot(bundleID: "com.x", app: "X", windowTitle: "", viewportPx: [1000, 1000], elements: [
            SceneElement(id: "panel", kind: "text", label: "panel", pos: [0.0, 0.0, 0.6, 1.0]),
            SceneElement(id: "btn", kind: "icon", label: "export", pos: [0.1, 0.5, 0.1, 0.05]),
        ], commands: [])
        XCTAssertEqual(scene.elementAt(CGPoint(x: 0.12, y: 0.52))?.label, "export")   // smallest containing
        XCTAssertEqual(scene.elementAt(CGPoint(x: 0.3, y: 0.1))?.label, "panel")
        XCTAssertNil(scene.elementAt(CGPoint(x: 0.9, y: 0.9)))                         // over nothing
    }
}
