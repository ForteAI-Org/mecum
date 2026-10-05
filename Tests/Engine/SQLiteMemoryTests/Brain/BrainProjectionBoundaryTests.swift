//
//  BrainProjectionBoundaryTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

import CoreGraphics
import EngineCore
import Foundation
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// Where the brain's projection meets the rest of the file: memberships another hand wrote, the
/// references Routes and calls hold to a retired anchor, the structural scenes of the first S2
/// increment beside the application's scope, and the limits this increment declares: a clock
/// outside the representable range, a number the file cannot keep, and a second identical
/// mutation, which is applied again because no event identifies it yet.
@Suite("The brain's projection beside the rest of the living memory")
struct BrainProjectionBoundaryTests {

    private typealias F = BrainFixtures

    private func det(_ kind: ElementKind, _ label: String, x: Double, y: Double,
                     w: Double = 0.03, h: Double = 0.017, state: ControlState? = nil) -> BrainDetection {
        F.det(kind, label, x: x, y: y, w: w, h: h, state: state)
    }

    @Test("F7 through the store: a scene the accessibility tree never read teaches anchors and creates no structural scene, no sample and no scope")
    func pixelOnlySceneCreatesNoStructure() async throws {
        let memory = try await F.open()
        let pixels = SceneFixtures.pixelsOnly(["Inbox", "Compose", "Settings"], title: "Mail")
        #expect(pixels.capture == .unknown && pixels.surface == .unknown)
        let scene = SceneSnapshot(
            bundleID: F.bundle, appName: "Fixture", windowTitle: "Mail",
            viewportPixelSize: pixels.scene.viewportPixelSize,
            elements: pixels.scene.elements + [
                F.element("icon|gear", "(unlabeled)", x: 0.9, y: 0.05, kind: .icon, unlabeled: true),
                F.element("icon|bell", "(unlabeled)", x: 0.85, y: 0.05, kind: .icon, unlabeled: true),
                F.element("control|go", "Go", x: 0.5, y: 0.5),
            ]
        )
        let stats = try await memory.brain.observe(scene, now: F.t0)
        #expect(stats.created == 3)
        #expect(try await memory.integers("SELECT count(*) FROM brain_scenes") == [0])
        #expect(try await memory.integers("SELECT count(*) FROM memory_event_observations") == [0])
        #expect(try await memory.integers("SELECT count(*) FROM memory_events") == [0])
        #expect(try await memory.load()?.objects.map(\.window) == ["mail", "mail", "mail"])
        await memory.store.close()
    }

    @Test("a clock outside the representable range is a typed refusal through the repository, and nothing is written")
    func clockOutOfRange() async throws {
        let memory = try await F.open()
        await #expect(throws: BrainProjectionError.clock(.dateOutOfRange(seconds: 1e16))) {
            _ = try await memory.brain.ingest(F.scene(["A", "B", "C"]), into: F.bundle, now: Date(timeIntervalSince1970: 1e16), window: nil)
        }
        await #expect(throws: BrainProjectionError.clock(.notFinite)) {
            _ = try await memory.brain.setName("x", anchorKey: "k", in: F.bundle, now: Date(timeIntervalSince1970: .nan))
        }
        #expect(try await memory.integers("SELECT count(*) FROM brain_apps") == [0])
        await memory.store.close()
    }

    @Test("a bound or a cell size that is not a finite number is refused before the commit, never stored as NULL or an infinity")
    func nonFiniteNumbersRefused() async throws {
        let memory = try await F.open()
        await #expect(throws: BrainProjectionError.unrepresentableNumber(table: "brain_anchors", id: "anchor-1", column: "typical_x")) {
            _ = try await memory.brain.ingest([det(.control, "Broken", x: .nan, y: 0.1)], into: F.bundle, now: F.t0, window: nil)
        }
        #expect(try await memory.integers("SELECT count(*) FROM brain_anchors") == [0])
        await #expect(throws: BrainProjectionError.unrepresentableNumber(table: "brain_anchors", id: "anchor-2", column: "typical_height")) {
            _ = try await memory.brain.ingest([det(.control, "Tall", x: 0.1, y: 0.1, h: .infinity)], into: F.bundle, now: F.t0, window: nil)
        }
        #expect(try await memory.load() == nil)
        let stats = try await memory.brain.ingest([det(.control, "Tiny", x: 5e-324, y: 1e-300)], into: F.bundle, now: F.t0, window: nil)
        #expect(stats.created == 1)
        #expect(try await memory.load()?.objects.first?.boundsTypical == F.rect(5e-324, 1e-300), "extreme finite values are kept exactly")
        await memory.store.close()
    }

}
