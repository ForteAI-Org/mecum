//
//  UIBrainTests.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import EngineCore
import Foundation
@testable import Memory
import PerceptionCore
import Testing

@Suite("The brain: anchors, groups, enrichment, the naming ledger and decay")
struct UIBrainTests {

    private let t0 = Fixtures.t0, t1 = Fixtures.t1

    private func det(_ kind: ElementKind, _ label: String, x: Double, y: Double,
                     w: Double = 0.03, h: Double = 0.017, state: ControlState? = nil) -> BrainDetection {
        Fixtures.detection(kind, label, x: x, y: y, width: w, height: h, state: state)
    }

    private static let destinations = ["Media File", "Behance", "Facebook", "TikTok", "Vimeo", "X", "YouTube", "FTP"]

    private func switchColumn(states: [ControlState]) -> [BrainDetection] {
        states.enumerated().map { i, state in
            det(.control, Self.destinations[i], x: 0.236, y: 0.18 + Double(i) * 0.036, state: state)
        }
    }

    private func trainedBrain() -> UIBrain {
        var brain = UIBrain()
        _ = BrainUpdater.ingest(switchColumn(states: Array(repeating: .off, count: 8)), into: &brain, now: t0)
        return brain
    }

    private func scene(_ labels: [String], x: Double = 0.5) -> [BrainDetection] {
        labels.enumerated().map { det(.control, $0.element, x: x, y: 0.1 + 0.05 * Double($0.offset)) }
    }

    // MARK: Anchors

    @Test("the same detection twice is one anchor")
    func sameDetection() {
        var brain = UIBrain()
        _ = BrainUpdater.ingest([det(.control, "Export", x: 0.1, y: 0.1)], into: &brain, now: t0)
        let stats = BrainUpdater.ingest([det(.control, "Export", x: 0.1, y: 0.1)], into: &brain, now: t1)
        #expect(brain.objects.count == 1)
        #expect(brain.objects[0].seenCount == 2)
        #expect(stats.updated == 1)
    }

    @Test("a jittered position with the same normalized label merges; a new label does not")
    func jitter() {
        var brain = UIBrain()
        _ = BrainUpdater.ingest([det(.control, "X", x: 0.30, y: 0.41)], into: &brain, now: t0)
        _ = BrainUpdater.ingest([det(.control, "X X", x: 0.304, y: 0.412)], into: &brain, now: t1)
        #expect(brain.objects.count == 2)
        var brain2 = UIBrain()
        _ = BrainUpdater.ingest([det(.control, "Media File", x: 0.30, y: 0.41)], into: &brain2, now: t0)
        _ = BrainUpdater.ingest([det(.control, "media  file", x: 0.304, y: 0.412)], into: &brain2, now: t1)
        #expect(brain2.objects.count == 1)
        #expect(brain2.objects[0].seenCount == 2)
    }

    @Test("a unique label survives a big move")
    func uniqueLabelMove() {
        var brain = UIBrain()
        _ = BrainUpdater.ingest([det(.control, "Export", x: 0.1, y: 0.1)], into: &brain, now: t0)
        _ = BrainUpdater.ingest([det(.control, "Export", x: 0.7, y: 0.8)], into: &brain, now: t1)
        #expect(brain.objects.count == 1)
        #expect(brain.objects[0].boundsTypical.x == 0.7)
    }

    @Test("two same-label siblings never merge and an ambiguous detection is skipped")
    func siblings() {
        var brain = UIBrain()
        _ = BrainUpdater.ingest([det(.control, "Mute", x: 0.2, y: 0.3), det(.control, "Mute", x: 0.2, y: 0.5)], into: &brain, now: t0)
        #expect(brain.objects.count == 2)
        var brain2 = UIBrain()
        _ = BrainUpdater.ingest([det(.control, "Mute", x: 0.2, y: 0.30), det(.control, "Mute", x: 0.2, y: 0.33)], into: &brain2, now: t0)
        let stats = BrainUpdater.ingest([det(.control, "Mute", x: 0.2, y: 0.315)], into: &brain2, now: t1)
        #expect(stats.skippedAmbiguous == 1)
        #expect(brain2.objects.count == 2)
    }

    @Test("state counts accumulate")
    func states() {
        var brain = UIBrain()
        _ = BrainUpdater.ingest([det(.control, "Facebook", x: 0.24, y: 0.30, state: .off)], into: &brain, now: t0)
        _ = BrainUpdater.ingest([det(.control, "Facebook", x: 0.24, y: 0.30, state: .on)], into: &brain, now: t1)
        _ = BrainUpdater.ingest([det(.control, "Facebook", x: 0.24, y: 0.30, state: .on)], into: &brain, now: t1)
        #expect(brain.objects[0].statesSeen == ["off": 1, "on": 2])
    }

    // MARK: Sibling groups

    @Test("an aligned column becomes one named group ordered top to bottom")
    func column() {
        var brain = UIBrain()
        let header = det(.text, "Destinations", x: 0.20, y: 0.15, w: 0.08, h: 0.012)
        _ = BrainUpdater.ingest(switchColumn(states: Array(repeating: .off, count: 8)) + [header], into: &brain, now: t0)
        #expect(brain.groups.count == 1)
        #expect(brain.groups[0].axis == .column)
        #expect(brain.groups[0].memberAnchors.count == 8)
        #expect(brain.groups[0].name == "Destinations")
        #expect(brain.groups[0].memberAnchors.first == brain.objects.first { $0.label == "Media File" }?.anchorKey)
        #expect(brain.objects.filter { $0.groupID != nil }.count >= 8)
    }

    @Test("a second ingest updates the group instead of duplicating it")
    func groupUpdate() {
        var brain = UIBrain()
        _ = BrainUpdater.ingest(switchColumn(states: Array(repeating: .off, count: 8)), into: &brain, now: t0)
        _ = BrainUpdater.ingest(switchColumn(states: [.off, .off, .on, .off, .off, .off, .off, .off]), into: &brain, now: t1)
        #expect(brain.groups.count == 1)
        #expect(brain.groups[0].seenCount == 2)
        #expect(brain.objects.count == 8)
        #expect(brain.objects.first { $0.label == "Facebook" }?.statesSeen["on"] == 1)
    }

    @Test("the ordinal rescues an unlabeled member")
    func ordinalRescue() {
        var brain = trainedBrain()
        let anonymous = det(.control, "", x: 0.236, y: 0.18 + 3 * 0.036, state: .off)
        let stats = BrainUpdater.ingest([anonymous], into: &brain, now: t1)
        #expect(stats.updated == 1)
        #expect(stats.created == 0)
        #expect(brain.objects.first { $0.label == "TikTok" }?.seenCount == 2)
    }

    @Test("fewer than three aligned elements is no group")
    func noGroup() {
        var brain = UIBrain()
        _ = BrainUpdater.ingest([det(.control, "A", x: 0.2, y: 0.1), det(.control, "B", x: 0.2, y: 0.2)], into: &brain, now: t0)
        #expect(brain.groups.isEmpty)
    }

    // MARK: Identity hygiene

    @Test("a composite never merges into a same-label switch of a different size")
    func sizeGate() {
        var brain = UIBrain()
        _ = BrainUpdater.ingest([det(.control, "Facebook", x: 0.211, y: 0.30, w: 0.025, h: 0.017, state: .off)], into: &brain, now: t0)
        _ = BrainUpdater.ingest([det(.control, "Facebook", x: 0.05, y: 0.30, w: 0.073, h: 0.02)], into: &brain, now: t1)
        #expect(brain.objects.count == 2)
        #expect(brain.objects[0].statesSeen == ["off": 1])
    }

    @Test("a conflicting label at a known slot is a different object")
    func conflictingLabel() throws {
        var brain = trainedBrain()
        let stats = BrainUpdater.ingest([det(.control, "Downloads", x: 0.236, y: 0.18 + 3 * 0.036)], into: &brain, now: t1)
        #expect(stats.created == 1)
        let tiktok = try #require(brain.objects.first { $0.label == "TikTok" })
        #expect(tiktok.seenCount == 1)
        #expect(tiktok.aliases.isEmpty)
    }

    @Test("slivers are not anchorable")
    func slivers() {
        var brain = UIBrain()
        _ = BrainUpdater.ingest([det(.icon, "", x: 0.968, y: 0.2, w: 0.004, h: 0.009),
                                 det(.icon, "", x: 0.968, y: 0.4, w: 0.004, h: 0.009),
                                 det(.icon, "", x: 0.968, y: 0.6, w: 0.004, h: 0.009)], into: &brain, now: t0)
        #expect(brain.objects.isEmpty)
        #expect(brain.groups.isEmpty)
    }

    @Test("misaligned columns do not merge and impostors are evicted")
    func impostors() throws {
        var brain = trainedBrain()
        let sidebar = (0..<4).map { det(.control, ["Home", "Downloads", "Documents", "Desktop"][$0],
                                        x: 0.028, y: 0.18 + Double($0) * 0.036, w: 0.06, h: 0.017) }
        _ = BrainUpdater.ingest(sidebar, into: &brain, now: t1)
        #expect(brain.groups.count == 2)
        let impostor = try #require(brain.objects.first { $0.label == "Home" }).anchorKey
        let gi = try #require(brain.groups.firstIndex { $0.memberAnchors.count == 8 })
        brain.groups[gi].memberAnchors.append(impostor)
        _ = BrainUpdater.ingest(switchColumn(states: Array(repeating: .off, count: 8)), into: &brain, now: t1)
        #expect(brain.groups[gi].memberAnchors.count == 8)
        #expect(brain.objects.first { $0.anchorKey == impostor }?.groupID == nil)
    }

    // MARK: Enrichment and switch slots

    @Test("switch slots come from stateful groups only")
    func switchSlots() {
        var brain = trainedBrain()
        #expect(brain.switchMemberSlots().count == 8)
        _ = BrainUpdater.ingest([det(.icon, "a", x: 0.8, y: 0.1), det(.icon, "b", x: 0.8, y: 0.2), det(.icon, "c", x: 0.8, y: 0.3)],
                                into: &brain, now: t1)
        #expect(brain.switchMemberSlots().count == 8)
    }

    @Test("enrich adds the group tag with an ordinal")
    func enrichTag() {
        let brain = trainedBrain()
        let element = SceneElement(id: "x", kind: .control, label: "Facebook",
                                   bounds: Fixtures.rect(0.236, 0.18 + 2 * 0.036), state: .off)
        let out = brain.enrich([element])
        #expect(out[0].group == "column#3")
        #expect(!out[0].isRecalled)
    }

    @Test("enrich rescues an unlabeled element, marks it recalled, and keeps its position live")
    func enrichRecall() {
        let brain = trainedBrain()
        let element = SceneElement(id: "anon", kind: .control, label: "(unlabeled)",
                                   bounds: Fixtures.rect(0.236, 0.18 + 3 * 0.036), state: .off, isUnlabeled: true)
        let out = brain.enrich([element])
        #expect(out[0].label == "TikTok")
        #expect(out[0].isRecalled)
        #expect(!out[0].isUnlabeled)
        #expect(out[0].id != "anon")
        #expect(out[0].bounds == element.bounds)
    }

    @Test("enrich leaves unknown and text elements alone")
    func enrichUntouched() {
        let brain = trainedBrain()
        let text = SceneElement(id: "t", kind: .text, label: "Destinations", bounds: Fixtures.rect(0.05, 0.1, 0.08, 0.012))
        let stranger = SceneElement(id: "s", kind: .control, label: "Render", bounds: Fixtures.rect(0.9, 0.9, 0.05, 0.02))
        let out = brain.enrich([text, stranger])
        #expect(out[0] == text)
        #expect(out[1] == stranger)
    }

    // MARK: The naming ledger

    @Test("a model-assigned name is immutable to observation churn and propagates to unlabeled detections")
    func modelName() {
        var brain = UIBrain()
        _ = BrainUpdater.ingest([det(.control, "", x: 0.2, y: 0.2)], into: &brain, now: t0)
        let key = brain.objects[0].anchorKey
        #expect(BrainUpdater.setName("tracks list menu button", anchorKey: key, into: &brain, now: t0))
        _ = BrainUpdater.ingest([det(.control, "TRACKS", x: 0.2, y: 0.2)], into: &brain, now: t1)
        #expect(brain.objects[0].label == "tracks list menu button")
        #expect(brain.objects[0].labelSource == .llm)
        #expect(brain.objects[0].aliases.contains("TRACKS"))
        let element = SceneElement(id: "x", kind: .control, label: "(unlabeled)", bounds: Fixtures.rect(0.2, 0.2), isUnlabeled: true)
        #expect(brain.enrich([element])[0].label == "tracks list menu button")
    }

    @Test("naming preserves the old observed label as an alias")
    func nameAlias() {
        var brain = UIBrain()
        _ = BrainUpdater.ingest([det(.control, "wavafarm", x: 0.3, y: 0.3)], into: &brain, now: t0)
        _ = BrainUpdater.setName("waveform view selector", anchorKey: brain.objects[0].anchorKey, into: &brain, now: t1)
        #expect(brain.objects[0].label == "waveform view selector")
        #expect(brain.objects[0].aliases.contains("wavafarm"))
    }

    @Test("naming opportunities rank by usage")
    func namingOpportunities() {
        var brain = trainedBrain()
        brain.objects.append(ObjectAnchor(anchorKey: "hot", kind: .icon, label: "", boundsTypical: Fixtures.rect(0.5, 0.5, 0.02, 0.02),
                                          seenCount: 40, firstSeen: t0, lastSeen: t0))
        brain.objects.append(ObjectAnchor(anchorKey: "cold", kind: .icon, label: "", boundsTypical: Fixtures.rect(0.6, 0.6, 0.02, 0.02),
                                          seenCount: 1, firstSeen: t0, lastSeen: t0))
        _ = BrainUpdater.recordTransition(anchorKey: "hot", verb: .click, effect: "menuOpened:A|B", into: &brain, now: t0)
        _ = BrainUpdater.recordTransition(anchorKey: "hot", verb: .click, effect: "menuOpened:A|B", into: &brain, now: t0)
        let opportunities = brain.namingOpportunities(limit: 5)
        #expect(opportunities.first?.anchor.anchorKey == "hot")
        #expect(opportunities.first?.context.contains("menu") == true)
        #expect(opportunities.allSatisfy { $0.anchor.label.isEmpty })
    }

    @Test("does and revealers read only trusted menu reveals")
    func doesAndRevealers() {
        var brain = UIBrain()
        _ = BrainUpdater.ingest(scene(["Platform", "Files", "Edit"]), into: &brain, now: t0)
        let platform = brain.objects[0].anchorKey
        _ = BrainUpdater.recordTransition(anchorKey: platform, verb: .click, effect: "menuOpened:Desktop|Mobile|Web", into: &brain, now: t0)
        _ = BrainUpdater.recordTransition(anchorKey: platform, verb: .click, effect: "elementsAppeared:Desktop", into: &brain, now: t0)
        #expect(brain.does(anchorKey: platform) == "click: opens menu(Desktop|Mobile|Web)")
        let revealers = brain.revealers(of: "desktop")
        #expect(revealers.count == 1)
        #expect(revealers.first?.label == "Platform")
        #expect(revealers.first?.items == ["Desktop", "Mobile", "Web"])
        #expect(brain.revealers(of: "Illustrator").isEmpty)
    }

    // MARK: Decay

    @Test("decay drops transients and keeps the established, measured in observations")
    func decayBasics() {
        var brain = UIBrain(ingestEpoch: 200)
        let old = t0.addingTimeInterval(-40 * 86400)
        brain.objects = [
            ObjectAnchor(anchorKey: "est", kind: .control, label: "Export", boundsTypical: Fixtures.rect(0.1, 0.1, 0.05, 0.02),
                         seenCount: 12, firstSeen: old, lastSeen: old, lastSeenEpoch: 196),
            ObjectAnchor(anchorKey: "tran", kind: .icon, label: "", boundsTypical: Fixtures.rect(0.2, 0.1, 0.02, 0.02),
                         seenCount: 1, firstSeen: old, lastSeen: old, lastSeenEpoch: 180),
            ObjectAnchor(anchorKey: "ancient", kind: .control, label: "Old", boundsTypical: Fixtures.rect(0.3, 0.1, 0.05, 0.02),
                         seenCount: 50, firstSeen: old, lastSeen: old, lastSeenEpoch: 40),
        ]
        brain.transitions = [
            LearnedTransition(anchorKey: "est", trigger: .click, effect: "menuOpened:A|B", evidence: 3, lastObserved: old, lastObservedEpoch: 150),
            LearnedTransition(anchorKey: "est", trigger: .click, effect: "elementsAppeared:X", evidence: 1, lastObserved: old, lastObservedEpoch: 160),
        ]
        BrainUpdater.decay(&brain, now: t0)
        #expect(brain.objects.map(\.anchorKey) == ["est"])
        #expect(brain.transitions.count == 1)
        #expect(brain.transitions[0].evidence == 3)
    }

    @Test("a dormant application forgets nothing")
    func dormant() {
        var brain = UIBrain(ingestEpoch: 300)
        let stale = t0.addingTimeInterval(-45 * 86400)
        brain.objects = [
            ObjectAnchor(anchorKey: "a", kind: .control, label: "Bounce", boundsTypical: Fixtures.rect(0.1, 0.1, 0.05, 0.02),
                         seenCount: 9, firstSeen: stale, lastSeen: stale, lastSeenEpoch: 300),
            ObjectAnchor(anchorKey: "b", kind: .icon, label: "", boundsTypical: Fixtures.rect(0.2, 0.1, 0.02, 0.02),
                         seenCount: 1, firstSeen: stale, lastSeen: stale, lastSeenEpoch: 299),
        ]
        brain.transitions = [LearnedTransition(anchorKey: "a", trigger: .click, effect: "menuOpened:A", evidence: 1,
                                               lastObserved: stale, lastObservedEpoch: 299)]
        BrainUpdater.decay(&brain, now: t0)
        #expect(brain.objects.count == 2)
        #expect(brain.transitions.count == 1)
    }

    @Test("protected names are never decayed and sit outside the cap")
    func protected() {
        var brain = UIBrain(ingestEpoch: 5000)
        let ancient = t0.addingTimeInterval(-400 * 86400)
        brain.objects = [
            ObjectAnchor(anchorKey: "taught", kind: .icon, label: "Solo Safe", labelSource: .llm, boundsTypical: Fixtures.rect(0.1, 0.1, 0.02, 0.02),
                         seenCount: 1, firstSeen: ancient, lastSeen: ancient, lastSeenEpoch: 1),
            ObjectAnchor(anchorKey: "obs", kind: .icon, label: "Mute", labelSource: .observed, boundsTypical: Fixtures.rect(0.2, 0.1, 0.02, 0.02),
                         seenCount: 500, firstSeen: t0, lastSeen: t0, lastSeenEpoch: 5000),
            ObjectAnchor(anchorKey: "obs2", kind: .icon, label: "Rec", boundsTypical: Fixtures.rect(0.3, 0.1, 0.02, 0.02),
                         seenCount: 400, firstSeen: t0, lastSeen: t0, lastSeenEpoch: 5000),
        ]
        BrainUpdater.decay(&brain, now: t0, maxObjects: 1)
        #expect(brain.objects.map(\.anchorKey) == ["taught", "obs"])
    }

    @Test("legacy rows are stamped on the first ingest, not dropped, and age by observation from there")
    func legacyRows() {
        var brain = UIBrain()
        let stale = t0.addingTimeInterval(-60 * 86400)
        brain.objects = (0..<5).map { i in
            ObjectAnchor(anchorKey: "l\(i)", kind: .control, label: "Legacy \(i)", boundsTypical: Fixtures.rect(0.1, 0.1 + 0.1 * Double(i), 0.05, 0.02),
                         seenCount: 1, firstSeen: stale, lastSeen: stale)
        }
        let fresh = [det(.control, "Something new", x: 0.8, y: 0.8), det(.control, "B", x: 0.8, y: 0.6), det(.control, "C", x: 0.8, y: 0.4)]
        _ = BrainUpdater.ingest(fresh, into: &brain, now: t0)
        #expect(brain.ingestEpoch == 1)
        #expect(brain.objects.count == 8)
        #expect(brain.objects.filter { $0.label.hasPrefix("Legacy") }.allSatisfy { $0.lastSeenEpoch == 0 })
        #expect(brain.objects.first { $0.label == "Something new" }?.lastSeenEpoch == 1)
        for i in 1...12 { _ = BrainUpdater.ingest(fresh, into: &brain, now: t0.addingTimeInterval(Double(i) * UIBrain.observationBlock)) }
        #expect(Set(brain.objects.map(\.label)) == ["Something new", "B", "C"])
        #expect(brain.objects.first { $0.label == "Something new" }?.seenCount == 13)
    }

    @Test("decay dissolves groups below three members")
    func dissolve() {
        var brain = trainedBrain()
        brain.ingestEpoch += 20
        for i in brain.objects.indices where brain.objects[i].label == "Facebook" || brain.objects[i].label == "TikTok" {
            brain.objects[i].seenCount = 9
            brain.objects[i].lastSeenEpoch = brain.ingestEpoch
        }
        BrainUpdater.decay(&brain, now: t0)
        #expect(brain.groups.isEmpty)
        #expect(brain.objects.allSatisfy { $0.groupID == nil })
    }

    @Test("the hard cap keeps the most established")
    func cap() {
        var brain = UIBrain()
        for i in 0..<10 {
            brain.objects.append(ObjectAnchor(anchorKey: "k\(i)", kind: .icon, label: "icon \(i)",
                                              boundsTypical: Fixtures.rect(0.1, Double(i) * 0.05, 0.02, 0.02),
                                              seenCount: i + 2, firstSeen: t0, lastSeen: t0))
        }
        BrainUpdater.decay(&brain, now: t0, maxObjects: 4)
        #expect(brain.objects.count == 4)
        #expect(Set(brain.objects.map(\.anchorKey)) == ["k9", "k8", "k7", "k6"])
    }

    @Test("the cap keeps every protected row and trims the unprotected by establishment")
    func capProtected() {
        var brain = UIBrain(ingestEpoch: 10)
        for i in 0..<5 {
            brain.objects.append(ObjectAnchor(anchorKey: "p\(i)", kind: .icon, label: "Taught \(i)", labelSource: .llm,
                                              boundsTypical: Fixtures.rect(0.1, Double(i) * 0.05, 0.02, 0.02),
                                              seenCount: 1, firstSeen: t0, lastSeen: t0, lastSeenEpoch: 10))
        }
        for i in 0..<6 {
            brain.objects.append(ObjectAnchor(anchorKey: "u\(i)", kind: .icon, label: "Seen \(i)",
                                              boundsTypical: Fixtures.rect(0.5, Double(i) * 0.05, 0.02, 0.02),
                                              seenCount: i + 2, firstSeen: t0, lastSeen: t0, lastSeenEpoch: 10))
        }
        BrainUpdater.decay(&brain, now: t0, maxObjects: 3)
        #expect(brain.objects.filter(\.isProtected).count == 5)
        #expect(Set(brain.objects.filter { !$0.isProtected }.map(\.anchorKey)) == ["u5", "u4", "u3"])
    }

    // MARK: Persistence

    @Test("knowledge without a brain key decodes and round-trips with one")
    func brainCoding() throws {
        let decoder = KnowledgeCoding.makeDecoder(), encoder = KnowledgeCoding.makeEncoder()
        let app = try decoder.decode(AppKnowledge.self, from: Data(#"{"bundleID":"com.x","windows":[],"menuCommands":[]}"#.utf8))
        #expect(app.brain.objects.isEmpty)
        var copy = app
        copy.brain.objects.append(ObjectAnchor(kind: .control, label: "Export", boundsTypical: Fixtures.rect(0.1, 0.1, 0.03, 0.02),
                                               firstSeen: t0, lastSeen: t0))
        copy.brain.groups.append(SiblingGroup(axis: .column, memberAnchors: ["a", "b", "c"], sharedKind: .control,
                                              cellSize: NormalizedSize(width: 0.03, height: 0.017), name: "Destinations", lastSeen: t0))
        copy.brain.transitions.append(LearnedTransition(anchorKey: "a", trigger: .rightClick, effect: "menuOpened:A|B", lastObserved: t0))
        let back = try decoder.decode(AppKnowledge.self, from: try encoder.encode(copy))
        #expect(back == copy)
        let legacy = Data(#"{"bundleID":"com.x.app","windows":[],"menuCommands":[],"routes":[],"brain":{"objects":[],"groups":[],"transitions":[]}}"#.utf8)
        #expect(try decoder.decode(AppKnowledge.self, from: legacy).brain.ingestEpoch == 0)
    }

    @Test("the stored brain keys are the ones the previous engine wrote")
    func legacyBrainJSON() throws {
        let json = """
        {"objects":[{"anchorKey":"k1","kind":"control","label":"Export","labelSource":"llm","aliases":["Exprt"],
          "boundsTypical":[0.1,0.2,0.03,0.017],"statesSeen":{"on":2},"seenCount":3,
          "firstSeen":"2026-07-02T10:00:00.000Z","lastSeen":"2026-07-02T10:00:00.000Z","lastSeenEpoch":4,"window":"edit"}],
         "groups":[{"id":"6BA7B810-9DAD-11D1-80B4-00C04FD430C8","axis":"row","memberAnchors":["k1"],"sharedKind":"control",
          "cellSize":[0.03,0.017],"seenCount":1,"lastSeen":"2026-07-02T10:00:00.000Z"}],
         "transitions":[{"anchorKey":"k1","trigger":"rightclick","effect":"stateFlip:off>on","evidence":2,
          "lastObserved":"2026-07-02T10:00:00.000Z"}],
         "ingestEpoch":7,"windowEpochs":{"edit":7}}
        """
        let brain = try KnowledgeCoding.makeDecoder().decode(UIBrain.self, from: Data(json.utf8))
        #expect(brain.objects[0].labelSource == .llm)
        #expect(brain.objects[0].boundsTypical == Fixtures.rect(0.1, 0.2))
        #expect(brain.groups[0].axis == .row)
        #expect(brain.groups[0].cellSize == NormalizedSize(width: 0.03, height: 0.017))
        #expect(brain.transitions[0].trigger == .rightClick)
        #expect(brain.transitions[0].sceneEffect == .stateFlip(from: .off, to: .on))
        #expect(brain.transitions[0].isTrusted)
    }

    // MARK: The observation clock

    @Test("the clock ticks once per observation block, so a scroll burst is one look")
    func clockTicks() {
        var brain = UIBrain()
        _ = BrainUpdater.ingest(scene(["Bounce", "Mix", "Edit"]), into: &brain, now: t0)
        for i in 1...150 { _ = BrainUpdater.ingest(scene(["Mix", "Edit", "Save"]), into: &brain, now: t0.addingTimeInterval(Double(i) * 0.4)) }
        #expect(brain.ingestEpoch == 1)
        #expect(brain.objects.contains { $0.label == "Bounce" })
    }

    @Test("parses of other windows are not evidence of absence")
    func windowScope() throws {
        var brain = UIBrain()
        _ = BrainUpdater.ingest(scene(["Bounce", "Mix", "Edit"]), into: &brain, now: t0, window: "bounce")
        let bounce = try #require(brain.objects.first { $0.label == "Bounce" })
        #expect(bounce.window == "bounce")
        for i in 1...200 {
            _ = BrainUpdater.ingest(scene(["Tracks", "Clips", "Save"]), into: &brain,
                                    now: t0.addingTimeInterval(Double(i) * UIBrain.observationBlock), window: "edit")
        }
        #expect(brain.objects.contains { $0.anchorKey == bounce.anchorKey })
        for i in 201...212 {
            _ = BrainUpdater.ingest(scene(["Mix", "Edit", "Other"]), into: &brain,
                                    now: t0.addingTimeInterval(Double(i) * UIBrain.observationBlock), window: "bounce")
        }
        #expect(!brain.objects.contains { $0.anchorKey == bounce.anchorKey })
    }

    @Test("small ingests do not tick the clock")
    func smallIngests() {
        var brain = UIBrain()
        _ = BrainUpdater.ingest(scene(["A", "B", "C"]), into: &brain, now: t0)
        for i in 1...50 {
            _ = BrainUpdater.ingest([det(.control, "Lone", x: 0.9, y: 0.9)], into: &brain, now: t0.addingTimeInterval(Double(i) * UIBrain.observationBlock))
        }
        for i in 51...60 {
            _ = BrainUpdater.ingest([det(.text, "just text", x: 0.9, y: 0.9)], into: &brain, now: t0.addingTimeInterval(Double(i) * UIBrain.observationBlock))
        }
        #expect(brain.ingestEpoch == 1)
        #expect(brain.objects.count == 4)
    }

    @Test("a trusted reveal survives while its revealer is on screen, a coincidence decays")
    func revealSurvives() throws {
        var brain = UIBrain()
        _ = BrainUpdater.ingest(scene(["File", "Edit", "View"]), into: &brain, now: t0)
        let file = try #require(brain.objects.first { $0.label == "File" }).anchorKey
        _ = BrainUpdater.recordTransition(anchorKey: file, verb: .click, effect: "menuOpened:New|Open|Save", into: &brain, now: t0)
        _ = BrainUpdater.recordTransition(anchorKey: file, verb: .click, effect: "elementsAppeared:Tooltip", into: &brain, now: t0)
        for i in 1...40 {
            _ = BrainUpdater.ingest(scene(["File", "Edit", "View"]), into: &brain, now: t0.addingTimeInterval(Double(i) * UIBrain.observationBlock))
        }
        #expect(brain.transitions.map(\.effect) == ["menuOpened:New|Open|Save"])
    }

    @Test("ambiguous siblings stay present and keep their keys")
    func ambiguousPresent() {
        var brain = UIBrain()
        let pair = [det(.control, "Mute", x: 0.1, y: 0.30), det(.control, "Mute", x: 0.1, y: 0.33), det(.control, "Solo", x: 0.2, y: 0.30)]
        _ = BrainUpdater.ingest(pair, into: &brain, now: t0)
        let keys = Set(brain.objects.map(\.anchorKey))
        for i in 1...20 { _ = BrainUpdater.ingest(pair, into: &brain, now: t0.addingTimeInterval(Double(i) * UIBrain.observationBlock)) }
        #expect(brain.objects.count == 3)
        #expect(Set(brain.objects.map(\.anchorKey)) == keys)
    }
}
