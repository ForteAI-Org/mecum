//
//  BrainUpdaterSeamTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

import Foundation
@testable import Memory
import PerceptionCore
import Testing

/// The two pure seams the stored projection relies on: the keys an ingest hands to what it creates,
/// and the report of what a decay dropped and why. Neither changes what the brain keeps.
@Suite("The brain's seams: injected keys and the decay report")
struct BrainUpdaterSeamTests {

    private let t0 = Fixtures.t0, t1 = Fixtures.t1

    private func det(_ kind: ElementKind, _ label: String, x: Double, y: Double,
                     w: Double = 0.03, h: Double = 0.017, state: ControlState? = nil) -> BrainDetection {
        Fixtures.detection(kind, label, x: x, y: y, width: w, height: h, state: state)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count
        }
    }

    @Test("injected keys name the anchors and groups an ingest creates, in detection order; the default draws random UUIDs")
    func keys() {
        let anchors = Counter(), groups = Counter()
        let keys = BrainKeys(
            anchorKey: { "a\(anchors.next())" },
            groupID  : { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", groups.next()))! }
        )
        var brain = UIBrain()
        let column = (0..<3).map { det(.control, "S\($0)", x: 0.2, y: 0.1 + Double($0) * 0.05) }
        _ = BrainUpdater.ingest(column, into: &brain, now: t0, keys: keys)
        #expect(brain.objects.map(\.anchorKey) == ["a1", "a2", "a3"])
        #expect(brain.groups.map(\.id) == [UUID(uuidString: "00000000-0000-4000-8000-000000000001")!])
        #expect(brain.objects.allSatisfy { $0.groupID == brain.groups[0].id })
        _ = BrainUpdater.ingest([det(.control, "Lone", x: 0.9, y: 0.9)], into: &brain, now: t1, keys: keys)
        #expect(brain.objects.last?.anchorKey == "a4")

        var random = UIBrain()
        _ = BrainUpdater.ingest(column, into: &random, now: t0)
        #expect(Set(random.objects.map(\.anchorKey)).count == 3)
        #expect(random.objects.allSatisfy { UUID(uuidString: $0.anchorKey) != nil })
        var twin = UIBrain()
        _ = BrainUpdater.ingest(column, into: &twin, now: t0)
        #expect(Set(twin.objects.map(\.anchorKey)).isDisjoint(with: Set(random.objects.map(\.anchorKey))))
    }

    @Test("the decay report names every dropped anchor by its rule: backstop before stale before transient, then the cap")
    func anchorCauses() {
        var brain = UIBrain(ingestEpoch: 200)
        let old = t0.addingTimeInterval(-40 * 86400), ancient = t0.addingTimeInterval(-400 * 86400)
        brain.objects = [
            ObjectAnchor(anchorKey: "est", kind: .control, label: "Export", boundsTypical: Fixtures.rect(0.1, 0.1, 0.05, 0.02),
                         seenCount: 12, firstSeen: old, lastSeen: old, lastSeenEpoch: 196),
            ObjectAnchor(anchorKey: "tran", kind: .icon, label: "", boundsTypical: Fixtures.rect(0.2, 0.1, 0.02, 0.02),
                         seenCount: 1, firstSeen: old, lastSeen: old, lastSeenEpoch: 180),
            ObjectAnchor(anchorKey: "stale", kind: .control, label: "Old", boundsTypical: Fixtures.rect(0.3, 0.1, 0.05, 0.02),
                         seenCount: 50, firstSeen: old, lastSeen: old, lastSeenEpoch: 40),
            ObjectAnchor(anchorKey: "year", kind: .control, label: "Year", boundsTypical: Fixtures.rect(0.4, 0.1, 0.05, 0.02),
                         seenCount: 1, firstSeen: ancient, lastSeen: ancient, lastSeenEpoch: 1),
            ObjectAnchor(anchorKey: "taught", kind: .control, label: "Taught", labelSource: .llm, boundsTypical: Fixtures.rect(0.5, 0.1, 0.05, 0.02),
                         seenCount: 1, firstSeen: ancient, lastSeen: ancient, lastSeenEpoch: 1),
        ]
        let report = BrainUpdater.decay(&brain, now: t0)
        #expect(brain.objects.map(\.anchorKey) == ["est", "taught"])
        #expect(report.anchors == ["tran": .transient, "stale": .stale, "year": .backstop])
        #expect(report.groups.isEmpty && report.transitions.isEmpty)

        var capped = UIBrain()
        for i in 0..<10 {
            capped.objects.append(ObjectAnchor(anchorKey: "k\(i)", kind: .icon, label: "icon \(i)",
                                               boundsTypical: Fixtures.rect(0.1, Double(i) * 0.05, 0.02, 0.02),
                                               seenCount: i + 2, firstSeen: t0, lastSeen: t0))
        }
        let cap = BrainUpdater.decay(&capped, now: t0, maxObjects: 4)
        #expect(Set(capped.objects.map(\.anchorKey)) == ["k9", "k8", "k7", "k6"])
        #expect(cap.anchors == Dictionary(uniqueKeysWithValues: (0..<6).map { ("k\($0)", AnchorRetirementCause.cap) }))
    }

    @Test("the decay report names a dissolved group by members, stale or backstop, and a dropped transition by anchor, backstop, stale or coincidence")
    func groupAndTransitionCauses() {
        var brain = UIBrain(ingestEpoch: 400)
        let recent = t0, ancient = t0.addingTimeInterval(-400 * 86400)
        func anchor(_ key: String, protected: Bool = true, lastSeen: Date = recent, epoch: Int = 400) -> ObjectAnchor {
            ObjectAnchor(anchorKey: key, kind: .control, label: key, labelSource: protected ? .llm : .observed,
                         boundsTypical: Fixtures.rect(0.1, 0.1, 0.03, 0.017), seenCount: 5, firstSeen: lastSeen, lastSeen: lastSeen,
                         lastSeenEpoch: epoch)
        }
        brain.objects = (["a", "b", "c", "d", "e", "f", "g", "h", "i"].map { anchor($0) }) + [anchor("gone", protected: false, epoch: 100)]
        let cell = NormalizedSize(width: 0.03, height: 0.017)
        brain.groups = [
            SiblingGroup(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, axis: .column, memberAnchors: ["a", "b", "gone"],
                         sharedKind: .control, cellSize: cell, lastSeen: recent, lastSeenEpoch: 400),
            SiblingGroup(id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!, axis: .column, memberAnchors: ["c", "d", "e"],
                         sharedKind: .control, cellSize: cell, lastSeen: recent, lastSeenEpoch: 200),
            SiblingGroup(id: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!, axis: .column, memberAnchors: ["f", "g", "h"],
                         sharedKind: .control, cellSize: cell, lastSeen: ancient, lastSeenEpoch: 400),
            SiblingGroup(id: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!, axis: .row, memberAnchors: ["a", "c", "f", "i"],
                         sharedKind: .control, cellSize: cell, lastSeen: recent, lastSeenEpoch: 400),
        ]
        brain.transitions = [
            LearnedTransition(anchorKey: "gone", trigger: .click, effect: "menuOpened:A", evidence: 3, lastObserved: recent, lastObservedEpoch: 400),
            LearnedTransition(anchorKey: "a", trigger: .click, effect: "menuOpened:B", evidence: 3, lastObserved: ancient, lastObservedEpoch: 400),
            LearnedTransition(anchorKey: "b", trigger: .click, effect: "stateFlip:off>on", evidence: 3, lastObserved: recent, lastObservedEpoch: 100),
            LearnedTransition(anchorKey: "c", trigger: .click, effect: "elementsAppeared:X", evidence: 1, lastObserved: recent, lastObservedEpoch: 360),
            LearnedTransition(anchorKey: "d", trigger: .click, effect: "menuOpened:C", evidence: 1, lastObserved: recent, lastObservedEpoch: 360),
            LearnedTransition(anchorKey: "e", trigger: .rightClick, effect: "elementsAppeared:Y", evidence: 2, lastObserved: recent, lastObservedEpoch: 360),
        ]
        let report = BrainUpdater.decay(&brain, now: t0)
        #expect(brain.groups.map(\.id) == [UUID(uuidString: "00000000-0000-4000-8000-000000000004")!])
        #expect(report.anchors == ["gone": .stale])
        #expect(report.groups == [
            UUID(uuidString: "00000000-0000-4000-8000-000000000001")!: .members,
            UUID(uuidString: "00000000-0000-4000-8000-000000000002")!: .stale,
            UUID(uuidString: "00000000-0000-4000-8000-000000000003")!: .backstop,
        ])
        #expect(report.transitions == [
            LearnedTransition.Key(anchorKey: "gone", trigger: .click, effect: "menuOpened:A"): .anchor,
            LearnedTransition.Key(anchorKey: "a", trigger: .click, effect: "menuOpened:B"): .backstop,
            LearnedTransition.Key(anchorKey: "b", trigger: .click, effect: "stateFlip:off>on"): .stale,
            LearnedTransition.Key(anchorKey: "c", trigger: .click, effect: "elementsAppeared:X"): .coincidence,
        ])
        #expect(brain.transitions.map(\.effect) == ["menuOpened:C", "elementsAppeared:Y"])
        #expect(brain.objects.first { $0.anchorKey == "a" }?.groupID == nil, "a dissolved group's members lose their current group")
    }

    @Test("an ingest reports its decay only when the clock ticked, and an empty report when the tick dropped nothing")
    func ingestReportsDecay() {
        var brain = UIBrain()
        let small = BrainUpdater.ingest([det(.control, "Lone", x: 0.9, y: 0.9)], into: &brain, now: t0)
        #expect(small.decay == nil)
        let substantial = BrainUpdater.ingest(Fixtures.detection(.control, "A", x: 0.1, y: 0.1).replicated(3), into: &brain, now: t0)
        #expect(substantial.decay == DecayReport())
        #expect(substantial.decay?.isEmpty == true)
        for i in 1...12 {
            _ = BrainUpdater.ingest([det(.control, "A", x: 0.1, y: 0.1), det(.control, "B", x: 0.1, y: 0.2), det(.control, "C", x: 0.1, y: 0.3)],
                                    into: &brain, now: t0.addingTimeInterval(Double(i) * UIBrain.observationBlock))
        }
        #expect(!brain.objects.contains { $0.label == "Lone" })
    }
}

private extension BrainDetection {

    /// Copies of one detection at distinct positions, so a scene is substantial without a group.
    func replicated(_ count: Int) -> [BrainDetection] {
        (0..<count).map { index in
            BrainDetection(kind: kind, label: "\(label)\(index)",
                           bounds: NormalizedRect(x: bounds.x + Double(index) * 0.2, y: bounds.y + Double(index) * 0.11,
                                                  width: bounds.width, height: bounds.height),
                           state: state)
        }
    }
}
