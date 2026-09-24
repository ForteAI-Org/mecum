//
//  SceneIntakeTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import CoreGraphics
import EngineCore
import Foundation
@testable import Memory
import PerceptionCore
import Synchronization
import Testing

/// Invented scenes of a routing window; no application was captured.
@Suite("One intake path from captured scenes to the brain and sightings")
struct SceneIntakeTests {

    private let bundle = "test.synthetic.mixer"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func control(_ label: String, x: Double, y: Double = 0.2) -> SceneElement {
        SceneElement(id: "control|\(label)|\(x)", kind: .control, label: label,
                     bounds: NormalizedRect(x: x, y: y, width: 0.15, height: 0.05))
    }

    private func scene(
        title   : String = "Synthetic Routing",
        bundle  : String? = nil,
        coverage: SceneCoverage = .window,
        labels  : [String] = ["All Busses", "Input", "Output"]
    ) -> SceneSnapshot {
        var scene = SceneSnapshot(
            bundleID: bundle ?? self.bundle, appName: "Synthetic Mixer", windowTitle: title,
            viewportPixelSize: ViewportPixelSize(width: 800, height: 600),
            elements: labels.enumerated().map { control($1, x: 0.05 + Double($0) * 0.2) }
        )
        scene.coverage = coverage
        return scene
    }

    private struct Harness {
        let clock: TestClock
        let knowledge: InMemoryKnowledgeStore
        let living: InMemoryLivingMemoryStore
        let intake: SceneIntake
    }

    private func harness(living: InMemoryLivingMemoryStore = InMemoryLivingMemoryStore(),
                         knowledge: InMemoryKnowledgeStore = InMemoryKnowledgeStore()) -> Harness {
        let clock = TestClock(t0)
        let brain = BrainMemory(store: knowledge, clock: { clock.now })
        return Harness(clock: clock, knowledge: knowledge, living: living,
                       intake: SceneIntake(brain: brain, livingMemory: living))
    }

    @Test("repeats in one observation block count one piece of evidence")
    func sameBlock() async throws {
        let h = harness()
        _ = try await h.intake.learn(from: scene())
        h.clock.advance(30)
        let second = try await h.intake.learn(from: scene())
        guard case .recorded(let sightings) = second.sightings else { Issue.record("not recorded"); return }
        #expect(sightings.count == 3)
        #expect(sightings.allSatisfy { $0.readCount == 2 && $0.evidenceCount == 1 })
        #expect(sightings.allSatisfy { $0.lastSeen == t0.addingTimeInterval(30) })
    }

    @Test("the next observation block counts again")
    func nextBlock() async throws {
        let h = harness()
        let first = try await h.intake.learn(from: scene())
        h.clock.advance(UIBrain.observationBlock + 1)
        let later = try await h.intake.learn(from: scene())
        #expect(later.ingest.observationBlock == first.ingest.observationBlock + 1)
        let sightings = try await h.living.sightings(in: [bundle])
        #expect(sightings.allSatisfy { $0.evidenceCount == 2 && $0.lastCountedBlock == later.ingest.observationBlock })
    }

    @Test("another window gets its own sightings")
    func otherWindow() async throws {
        let h = harness()
        _ = try await h.intake.learn(from: scene())
        _ = try await h.intake.learn(from: scene(title: "Synthetic Mix", labels: ["Master", "Solo", "Mute"]))
        let sightings = try await h.living.sightings(in: [bundle])
        #expect(Set(sightings.map(\.key.context.windowFamily)) == ["syntheticrouting", "syntheticmix"])
        #expect(sightings.filter { $0.key.context.windowFamily == "syntheticrouting" }.map(\.name).sorted()
                == ["All Busses", "Input", "Output"])
    }

    @Test("a scene with pop-up rows, or of unknown coverage, records no sighting but still feeds the brain")
    func popups() async throws {
        let h = harness()
        let mixed = try await h.intake.learn(from: scene(coverage: .windowAndPopups,
                                                         labels: ["All Busses", "Output Busses", "Input"]))
        #expect(mixed.sightings == .abstained(.popupsInScene))
        #expect(mixed.ingest.created == 3)
        let unknown = try await h.intake.learn(from: scene(coverage: .unattributed))
        #expect(unknown.sightings == .abstained(.coverageUnattributed))
        #expect(try await h.living.sightings(in: [bundle]).isEmpty)
    }

    @Test("a missing or process-fallback bundle and an untitled window record no sighting")
    func unattributableScenes() async throws {
        let h = harness()
        let fallback = try await h.intake.learn(from: scene(bundle: "pid.4242"))
        #expect(fallback.sightings == .abstained(.noApplicationIdentity))
        #expect(try await h.intake.learn(from: scene(bundle: "")).sightings == .abstained(.noApplicationIdentity))
        #expect(try await h.intake.learn(from: scene(title: "2 — 3")).sightings == .abstained(.untitledWindow))
        #expect(try await h.living.sightings(in: [bundle, "pid.4242", ""]).isEmpty)
    }

    @Test("no scene teaches nothing and touches neither store")
    func noScene() async throws {
        let h = harness()
        #expect(try await h.intake.learn(fromOutcomeScene: nil) == nil)
        #expect(await h.knowledge.bundleIDs().isEmpty)
        #expect(try await h.living.sightings(in: [bundle]).isEmpty)
    }

    @Test("learning from the observed scene and an action's scene captures nothing more")
    func captureCountUnchanged() async throws {
        let h = harness()
        let provider = CountingSceneProvider(scene: scene())
        let observed = try await provider.currentScene(of: 4242)
        _ = try await h.intake.learn(from: observed.scene)
        let outcome = ActOutcome(.foundActed, "synthetic action", scene: observed.scene)
        _ = try await h.intake.learn(fromOutcomeScene: outcome.scene)
        #expect(provider.captures == 1)
    }

    @Test("only this frame's accepted anchors are projected, never the brain's historical ones")
    func onlyAcceptedAnchors() async throws {
        let h = harness()
        _ = try await h.intake.learn(from: scene(labels: ["All Busses", "Input", "Output", "Legacy Bus"]))
        let living = InMemoryLivingMemoryStore()
        let brain = BrainMemory(store: h.knowledge, clock: { h.clock.now })
        let learning = try await SceneIntake(brain: brain, livingMemory: living).learn(from: scene())
        guard case .recorded(let sightings) = learning.sightings else { Issue.record("not recorded"); return }
        #expect(sightings.map(\.name).sorted() == ["All Busses", "Input", "Output"])
        #expect(learning.ingest.accepted.count == 3)
        #expect(Set(learning.ingest.accepted.map(\.anchorKey)).count == 3)
    }

    @Test("a sighting whose anchor never reached the brain's disk stays readable by name")
    func anchorLostBeforeFlush() async throws {
        let living = InMemoryLivingMemoryStore()
        let before = harness(living: living)
        _ = try await before.intake.learn(from: scene())
        // A fresh brain store stands for write-behind JSON lost in a crash before its flush.
        let after = harness(living: living, knowledge: InMemoryKnowledgeStore())
        _ = try await after.intake.learn(from: scene())
        let sightings = try await living.sightings(in: [bundle])
        #expect(sightings.count == 6)
        #expect(Dictionary(grouping: sightings, by: \.name).mapValues(\.count)
                == ["All Busses": 2, "Input": 2, "Output": 2])
    }

    @Test("coverage is provenance, not content: the scene JSON is unchanged and decodes as unattributed")
    func coverageNotEncoded() throws {
        let json = try JSONEncoder().encode(scene(coverage: .window))
        #expect(!String(decoding: json, as: UTF8.self).contains("coverage"))
        #expect(try JSONDecoder().decode(SceneSnapshot.self, from: json).coverage == .unattributed)
    }

    @Test("a failing living memory never blocks the brain or the caller")
    func failingLivingMemory() async throws {
        let knowledge = InMemoryKnowledgeStore()
        let brain = BrainMemory(store: knowledge, clock: { Date(timeIntervalSince1970: 1_800_000_000) })
        let failing = SceneIntake(brain: brain, livingMemory: FailingLivingMemory())
        let learning = try await failing.learn(from: scene())
        guard case .failed = learning.sightings else { Issue.record("expected a failure"); return }
        #expect(await knowledge.load(bundleID: bundle)?.brain.objects.count == 3)
        let unconfigured = try await SceneIntake(brain: brain, livingMemory: nil).learn(from: scene())
        #expect(unconfigured.sightings == .notConfigured)
    }
}

/// TestClock is a settable clock shared by the brain under test.
private final class TestClock: Sendable {
    private let state: Mutex<Date>

    init(_ start: Date) { state = Mutex(start) }

    var now: Date { state.withLock { $0 } }

    func advance(_ seconds: TimeInterval) { state.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// CountingSceneProvider counts captures; memory must never be the reason for one.
private final class CountingSceneProvider: SceneProviding, Sendable {
    private let scene: SceneSnapshot
    private let count = Mutex(0)

    init(scene: SceneSnapshot) { self.scene = scene }

    var captures: Int { count.withLock { $0 } }

    func currentScene(of processID: pid_t) async throws -> PerceivedWindow {
        count.withLock { $0 += 1 }
        return PerceivedWindow(scene: scene, frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    }
}

/// FailingLivingMemory refuses every call, as an unreadable store would.
private struct FailingLivingMemory: LivingMemoryStoring {
    struct Unavailable: Error {}

    func recordSightings(_ observations: [SightingObservation]) async throws -> [Sighting] { throw Unavailable() }
    func sightings(in bundleIDs: Set<String>) async throws -> [Sighting] { throw Unavailable() }
    func record(_ event: ExperienceEvent) async throws -> ExperienceRecording { throw Unavailable() }
    func experiences(in bundleIDs: Set<String>) async throws -> [ExperienceRecord] { throw Unavailable() }
    func history(of experience: ExperienceID) async throws -> [ExperienceHistoryEntry] { throw Unavailable() }
    func candidates(for phrase: String, in bundleIDs: Set<String>?) async throws -> [ExperienceRecord] {
        throw Unavailable()
    }
    func record(_ decision: RecallDecisionRecord) async throws { throw Unavailable() }
    func decisions(about experience: ExperienceID) async throws -> [RecallDecisionRecord] { throw Unavailable() }
}
