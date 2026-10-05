//
//  SceneFixtures.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

import CoreGraphics
import EngineCore
import Foundation
import Memory
import Perception
import PerceptionCore
import SQLiteMemory

/// SceneFixtures builds the fake windows of the structure-v3 fixtures (F1 to F15) and takes them
/// through the real producer: `AccessibilityAugmentation.harvest` on the fake tree, the pure
/// `ScenePipeline.assemble` for an empty pixel scene, `ScenePipeline.augmented` for the merge, and
/// `CaptureSurface.classified` for the surface a provider would state. Nothing is cleaned by hand:
/// what reaches the store is what the producer emitted.
///
/// Every event and sample carries an explicit identity, source and application context: the
/// fixtures stand in for a producer that does not exist yet, they do not pretend one is wired.
enum SceneFixtures {

    static let frame   = CGRect(x: 100, y: 100, width: 1000, height: 800)
    static let app     = AppContextIdentity(bundleID: "test.fixture.structure", version: "1.0", locale: "it")
    static let reader  = FakeReader()
    static let t0: Int64 = 1_700_000_000_000

    // MARK: Tree builders

    static func window(_ title: String, subrole: String? = "AXStandardWindow", _ children: [FakeNode]) -> FakeNode {
        FakeNode("AXWindow", subrole: subrole, title: title, frame: frame).adding(children)
    }

    static func dialog(_ title: String, _ children: [FakeNode]) -> FakeNode {
        window(title, subrole: "AXDialog", children)
    }

    static func button(_ title: String, y: CGFloat, x: CGFloat = 700) -> FakeNode {
        FakeNode("AXButton", title: title, frame: CGRect(x: x, y: y, width: 100, height: 24))
    }

    static func checkbox(_ title: String, on: Bool, y: CGFloat) -> FakeNode {
        FakeNode("AXCheckBox", title: title, numericValue: on ? 1 : 0, frame: CGRect(x: 700, y: y, width: 120, height: 20))
    }

    static func textField(value: String, y: CGFloat, title: String? = nil) -> FakeNode {
        FakeNode("AXTextField", title: title, value: value, frame: CGRect(x: 700, y: y, width: 200, height: 22))
    }

    static func staticText(_ text: String, y: CGFloat) -> FakeNode {
        FakeNode("AXStaticText", value: text, frame: CGRect(x: 150, y: y, width: 200, height: 18))
    }

    static func group(_ title: String, y: CGFloat, height: CGFloat = 200, _ children: [FakeNode]) -> FakeNode {
        FakeNode("AXGroup", title: title, frame: CGRect(x: 120, y: y, width: 900, height: height)).adding(children)
    }

    /// A table named `name` (or untitled) whose rows are named by their content, each with a
    /// "Reply" button when asked: the repeated instances a collection hides from a signature. The
    /// producer names a row by the longest text in its subtree, so a row whose name is shorter than
    /// "Reply" is named after its button and keeps no button of its own; that is the producer's
    /// rule, and it touches nothing above the collection.
    static func table(_ name: String?, rows: [String], y: CGFloat = 200, withReply: Bool = true) -> FakeNode {
        let table = FakeNode("AXTable", title: name, frame: CGRect(x: 120, y: y, width: 500, height: 400))
        for (index, row) in rows.enumerated() {
            let rowY = y + 10 + CGFloat(index) * 30
            let node = FakeNode("AXRow", value: row, frame: CGRect(x: 125, y: rowY, width: 490, height: 26))
            if withReply {
                node.adding(FakeNode("AXCell", frame: CGRect(x: 500, y: rowY, width: 100, height: 26)).adding(
                    FakeNode("AXButton", title: "Reply", frame: CGRect(x: 510, y: rowY + 2, width: 80, height: 20))
                ))
            }
            table.adding(node)
        }
        return table
    }

    // MARK: Producer

    /// Takes a fake window through the producer and states the surface as a provider would.
    static func perceive(
        _ root     : FakeNode,
        title      : String? = nil,
        limits     : AccessibilityAugmentation.Limits = AccessibilityAugmentation.Limits(),
        popupOpen  : Bool = false
    ) -> PerceivedWindow {
        let harvest = AccessibilityAugmentation.harvest(under: root, windowFrame: frame, reader: reader, limits: limits)
        let pixels  = ScenePipeline.assemble(
            runs     : [],
            segments : [],
            imageSize: CGSize(width: frame.width, height: frame.height),
            window   : ScenePipeline.Window(bundleID: app.bundleID, appName: "Fixture", title: title ?? root.title ?? "")
        )
        let capture = ScenePipeline.augmented(pixels, with: harvest)
        let surface = popupOpen
            ? CaptureSurface.popupUnion
            : CaptureSurface.classified(role: capture.quality.windowRole, subrole: capture.quality.windowSubrole)
        return PerceivedWindow(scene: capture.scene, frame: frame, capture: capture.quality, surface: surface)
    }

    /// A window built from recognized text alone: no accessibility read, quality unknown.
    static func pixelsOnly(_ texts: [String], title: String = "Pixels") -> PerceivedWindow {
        let runs = texts.enumerated().map { index, text in
            RecognizedText(text: text, pixelBox: CGRect(x: 100, y: 100 + index * 40, width: 200, height: 20))
        }
        let scene = ScenePipeline.assemble(
            runs     : runs,
            segments : [],
            imageSize: CGSize(width: frame.width, height: frame.height),
            window   : ScenePipeline.Window(bundleID: app.bundleID, appName: "Fixture", title: title)
        )
        return PerceivedWindow(scene: scene, frame: frame)
    }

    // MARK: Memory records

    static func event(_ id: String, app: AppContextIdentity? = SceneFixtures.app, at ms: Int64 = t0) -> MemoryEventRecord {
        MemoryEventRecord(
            eventID : id, source: .cli, streamID: "fixtures", sourceKey: id, kind: .observation,
            app     : app, occurredAtMS: ms
        )
    }

    static func sample(_ id: String, phase: CapturePhase = .current, ordinal: Int = 0, of window: PerceivedWindow) -> CaptureSample {
        CaptureSample(key: CaptureSampleKey(eventID: id, phase: phase, ordinal: ordinal), of: window)
    }

    /// A fresh store with its two repositories and deterministic scene ids.
    struct Memory {
        let url: URL
        let store: SQLiteMemoryStore
        let captures: SQLiteCaptureRepository
        let scenes: SQLiteSceneRepository
        let ids: SceneIDs
    }

    static func open(at url: URL? = nil, ids: SceneIDs = SceneIDs()) async throws -> Memory {
        let url   = try url ?? temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        return Memory(
            url     : url,
            store   : store,
            captures: SQLiteCaptureRepository(store: store),
            scenes  : SQLiteSceneRepository(store: store, makeSceneID: { ids.next() }),
            ids     : ids
        )
    }

    /// Records the event and the sample of a window, then associates it.
    static func observe(
        _ memory: Memory,
        _ id    : String,
        _ window: PerceivedWindow,
        phase   : CapturePhase = .current,
        at ms   : Int64 = t0
    ) async throws -> SceneAssociationOutcome {
        _ = try await memory.captures.record(event(id, at: ms))
        _ = try await memory.captures.record(sample(id, phase: phase, of: window))
        return try await memory.scenes.associate(CaptureSampleKey(eventID: id, phase: phase), at: ms)
    }
}

/// SceneIDs hands out deterministic scene identifiers, so two runs of a fixture name the same scene.
final class SceneIDs: @unchecked Sendable {

    private let lock = NSLock()
    private var count = 0

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return "scene-\(count)"
    }
}

/// A deadline that passes after a number of questions: the walk asks before every node, so this
/// stops it part way through a tree that is otherwise complete.
final class CountedDeadline: @unchecked Sendable {

    private let lock = NSLock()
    private var asked = 0
    private let after: Int

    init(after: Int) { self.after = after }

    var isPast: @Sendable () -> Bool {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            asked += 1
            return asked > after
        }
    }
}
