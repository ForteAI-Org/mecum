import XCTest
@testable import LocatorCore

final class UIBrainTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let t1 = Date(timeIntervalSince1970: 1_700_000_100)

    private func det(_ kind: String, _ label: String, x: Double, y: Double,
                     w: Double = 0.03, h: Double = 0.017, state: String? = nil) -> BrainDetection {
        BrainDetection(kind: kind, label: label, pos: [x, y, w, h], state: state)
    }

    // MARK: anchors

    func testSameDetectionTwiceIsOneAnchor() {
        var brain = UIBrain()
        _ = BrainUpdater.ingest([det("control", "Export", x: 0.1, y: 0.1)], into: &brain, now: t0)
        let s = BrainUpdater.ingest([det("control", "Export", x: 0.1, y: 0.1)], into: &brain, now: t1)
        XCTAssertEqual(brain.objects.count, 1)
        XCTAssertEqual(brain.objects[0].seenCount, 2)
        XCTAssertEqual(s.updated, 1)
    }

    func testJitteredPositionAndLabelVariantStillMatch() {
        var brain = UIBrain()
        _ = BrainUpdater.ingest([det("control", "X", x: 0.30, y: 0.41)], into: &brain, now: t0)
        _ = BrainUpdater.ingest([det("control", "X X", x: 0.304, y: 0.412)], into: &brain, now: t1)
        // "X X" is a NEW label at nearly the same spot — no label match, no group → new anchor is
        // correct (never force-merge). But a same-normalized-label jitter must merge:
        var brain2 = UIBrain()
        _ = BrainUpdater.ingest([det("control", "Media File", x: 0.30, y: 0.41)], into: &brain2, now: t0)
        _ = BrainUpdater.ingest([det("control", "media  file", x: 0.304, y: 0.412)], into: &brain2, now: t1)
        XCTAssertEqual(brain2.objects.count, 1)
        XCTAssertEqual(brain2.objects[0].seenCount, 2)
    }

    func testUniqueLabelSurvivesABigMove() {   // window resized — label+kind unique in the app
        var brain = UIBrain()
        _ = BrainUpdater.ingest([det("control", "Export", x: 0.1, y: 0.1)], into: &brain, now: t0)
        _ = BrainUpdater.ingest([det("control", "Export", x: 0.7, y: 0.8)], into: &brain, now: t1)
        XCTAssertEqual(brain.objects.count, 1)
        XCTAssertEqual(brain.objects[0].boundsTypical[0], 0.7)   // typical bounds follow the latest
    }

    func testTwoSameLabelSiblingsNeverMergeAndAmbiguousIsSkipped() {
        var brain = UIBrain()
        _ = BrainUpdater.ingest([det("control", "Mute", x: 0.2, y: 0.3),
                                 det("control", "Mute", x: 0.2, y: 0.5)], into: &brain, now: t0)
        XCTAssertEqual(brain.objects.count, 2)                    // distinct objects despite same label
        // A detection halfway between them (within tol of neither... make it within tol of BOTH is
        // impossible at this spacing; test the near-both case with tight spacing):
        var brain2 = UIBrain()
        _ = BrainUpdater.ingest([det("control", "Mute", x: 0.2, y: 0.30),
                                 det("control", "Mute", x: 0.2, y: 0.33)], into: &brain2, now: t0)
        let s = BrainUpdater.ingest([det("control", "Mute", x: 0.2, y: 0.315)], into: &brain2, now: t1)
        XCTAssertEqual(s.skippedAmbiguous, 1)                     // never guess between near-identical siblings
        XCTAssertEqual(brain2.objects.count, 2)                   // and never create a phantom third
    }

    func testStateCountsAccumulate() {
        var brain = UIBrain()
        _ = BrainUpdater.ingest([det("control", "Facebook", x: 0.24, y: 0.30, state: "off")], into: &brain, now: t0)
        _ = BrainUpdater.ingest([det("control", "Facebook", x: 0.24, y: 0.30, state: "on")], into: &brain, now: t1)
        _ = BrainUpdater.ingest([det("control", "Facebook", x: 0.24, y: 0.30, state: "on")], into: &brain, now: t1)
        XCTAssertEqual(brain.objects[0].statesSeen, ["off": 1, "on": 2])
    }

    // MARK: sibling groups

    private func switchColumn(states: [String]) -> [BrainDetection] {
        states.enumerated().map { i, s in
            det("control", ["Media File", "Behance", "Facebook", "TikTok", "Vimeo", "X", "YouTube", "FTP"][i],
                x: 0.236, y: 0.18 + Double(i) * 0.036, state: s)
        }
    }

    func testAlignedColumnBecomesOneNamedGroup() {
        var brain = UIBrain()
        let dets = switchColumn(states: Array(repeating: "off", count: 8))
            + [det("text", "Destinations", x: 0.05, y: 0.115, w: 0.08, h: 0.012)]
        // header ABOVE the first member, within reach and roughly the column's x
        var withHeader = dets
        withHeader[8].pos = [0.20, 0.15, 0.08, 0.012]
        _ = BrainUpdater.ingest(withHeader, into: &brain, now: t0)
        XCTAssertEqual(brain.groups.count, 1)
        XCTAssertEqual(brain.groups[0].axis, "column")
        XCTAssertEqual(brain.groups[0].memberAnchors.count, 8)
        XCTAssertEqual(brain.groups[0].name, "Destinations")
        XCTAssertEqual(brain.groups[0].memberAnchors.first,
                       brain.objects.first { $0.label == "Media File" }?.anchorKey)   // ordered top→bottom
        XCTAssertTrue(brain.objects.filter { $0.groupID != nil }.count >= 8)
    }

    func testSecondIngestUpdatesGroupNotDuplicates() {
        var brain = UIBrain()
        _ = BrainUpdater.ingest(switchColumn(states: Array(repeating: "off", count: 8)), into: &brain, now: t0)
        _ = BrainUpdater.ingest(switchColumn(states: ["off", "off", "on", "off", "off", "off", "off", "off"]),
                                into: &brain, now: t1)
        XCTAssertEqual(brain.groups.count, 1)
        XCTAssertEqual(brain.groups[0].seenCount, 2)
        XCTAssertEqual(brain.objects.count, 8)                    // states changed, identity didn't
        XCTAssertEqual(brain.objects.first { $0.label == "Facebook" }?.statesSeen["on"], 1)
    }

    func testOrdinalRescuesAnUnlabeledMember() {
        var brain = UIBrain()
        _ = BrainUpdater.ingest(switchColumn(states: Array(repeating: "off", count: 8)), into: &brain, now: t0)
        // Next scene: the TikTok switch comes back label-less (OCR missed the row label entirely).
        let anon = det("control", "", x: 0.236, y: 0.18 + 3 * 0.036, state: "off")
        let s = BrainUpdater.ingest([anon], into: &brain, now: t1)
        XCTAssertEqual(s.updated, 1)
        XCTAssertEqual(s.created, 0)                              // matched slot 4, no phantom
        XCTAssertEqual(brain.objects.first { $0.label == "TikTok" }?.seenCount, 2)
    }

    func testFewerThanThreeAlignedIsNoGroup() {
        var brain = UIBrain()
        _ = BrainUpdater.ingest([det("control", "A", x: 0.2, y: 0.1),
                                 det("control", "B", x: 0.2, y: 0.2)], into: &brain, now: t0)
        XCTAssertTrue(brain.groups.isEmpty)
    }

    // MARK: identity hygiene (measured failures from the live Premiere store, 2026-07-02)

    func testCompositeNeverMergesIntoSameLabelSwitchOfDifferentSize() {
        var brain = UIBrain()
        _ = BrainUpdater.ingest([det("control", "Facebook", x: 0.211, y: 0.30, w: 0.025, h: 0.017, state: "off")],
                                into: &brain, now: t0)
        // the wide logo+text composite shares the row's name — unique-label fallback must NOT fuse them
        _ = BrainUpdater.ingest([det("control", "Facebook", x: 0.05, y: 0.30, w: 0.073, h: 0.02)],
                                into: &brain, now: t1)
        XCTAssertEqual(brain.objects.count, 2)
        XCTAssertEqual(brain.objects[0].statesSeen, ["off": 1])   // the switch's history stays clean
    }

    func testConflictingLabelAtAKnownSlotIsADifferentObject() {
        var brain = trainedBrain()                                 // 8-member switch column
        // Another SCREEN's element at TikTok's normalized slot ("Downloads" in the Import sidebar).
        let s = BrainUpdater.ingest([det("control", "Downloads", x: 0.236, y: 0.18 + 3 * 0.036)],
                                    into: &brain, now: t1)
        XCTAssertEqual(s.created, 1)                               // new anchor, not an ordinal merge
        let tiktok = brain.objects.first { $0.label == "TikTok" }!
        XCTAssertEqual(tiktok.seenCount, 1)                        // untouched
        XCTAssertTrue(tiktok.aliases.isEmpty)                      // no alias poisoning
    }

    func testSliversAreNotAnchorable() {   // a moving scrollbar thumb must not spawn stacked anchors
        var brain = UIBrain()
        _ = BrainUpdater.ingest([det("icon", "", x: 0.968, y: 0.2, w: 0.004, h: 0.009),
                                 det("icon", "", x: 0.968, y: 0.4, w: 0.004, h: 0.009),
                                 det("icon", "", x: 0.968, y: 0.6, w: 0.004, h: 0.009)], into: &brain, now: t0)
        XCTAssertTrue(brain.objects.isEmpty)
        XCTAssertTrue(brain.groups.isEmpty)
    }

    func testMisalignedColumnsDoNotMergeAndImpostorsAreEvicted() {
        var brain = trainedBrain()                                 // switch column at x=0.236
        let sidebar = (0..<4).map { det("control", ["Home", "Downloads", "Documents", "Desktop"][$0],
                                        x: 0.028, y: 0.18 + Double($0) * 0.036, w: 0.06, h: 0.017) }
        _ = BrainUpdater.ingest(sidebar, into: &brain, now: t1)
        XCTAssertEqual(brain.groups.count, 2)                      // a SEPARATE group, no union
        // Simulate a legacy-polluted store: shove an impostor into the switch group, then re-ingest.
        let impostor = brain.objects.first { $0.label == "Home" }!.anchorKey
        let gi = brain.groups.firstIndex { $0.memberAnchors.count == 8 }!
        brain.groups[gi].memberAnchors.append(impostor)
        _ = BrainUpdater.ingest(switchColumn(states: Array(repeating: "off", count: 8)), into: &brain, now: t1)
        XCTAssertEqual(brain.groups[gi].memberAnchors.count, 8)    // evicted on the next merge
        XCTAssertNil(brain.objects.first { $0.anchorKey == impostor }?.groupID)
    }

    // MARK: B1 — enrichment + switch slots

    private func trainedBrain() -> UIBrain {
        var brain = UIBrain()
        _ = BrainUpdater.ingest(switchColumn(states: Array(repeating: "off", count: 8)), into: &brain, now: t0)
        return brain
    }

    func testSwitchMemberSlotsComeFromStatefulGroups() {
        var brain = trainedBrain()
        XCTAssertEqual(brain.switchMemberSlots().count, 8)
        // a group with NO stateful member yields no slots
        _ = BrainUpdater.ingest([det("icon", "a", x: 0.8, y: 0.1), det("icon", "b", x: 0.8, y: 0.2),
                                 det("icon", "c", x: 0.8, y: 0.3)], into: &brain, now: t1)
        XCTAssertEqual(brain.switchMemberSlots().count, 8)   // still only the switch column
    }

    func testEnrichAddsGroupTagWithOrdinal() {
        let brain = trainedBrain()
        let el = SceneElement(id: "x", kind: "control", label: "Facebook",
                              pos: [0.236, 0.18 + 2 * 0.036, 0.03, 0.017], state: "off")
        let out = brain.enrich([el])
        XCTAssertEqual(out[0].group, "column#3")             // 3rd slot; group name unset in synthetic data
        XCTAssertNil(out[0].recalled)                        // label was live, nothing recalled
    }

    func testEnrichRescuesAnUnlabeledElementAndMarksIt() {
        let brain = trainedBrain()
        let el = SceneElement(id: "anon", kind: "control", label: "(unlabeled)",
                              pos: [0.236, 0.18 + 3 * 0.036, 0.03, 0.017], state: "off", unlabeled: true)
        let out = brain.enrich([el])
        XCTAssertEqual(out[0].label, "TikTok")               // remembered name
        XCTAssertEqual(out[0].recalled, true)                // honestly marked as memory
        XCTAssertNil(out[0].unlabeled)
        XCTAssertNotEqual(out[0].id, "anon")                 // id rebuilt from the recalled label
        XCTAssertEqual(out[0].pos, el.pos)                   // position stays LIVE — memory never aims
    }

    func testEnrichLeavesUnknownAndTextElementsAlone() {
        let brain = trainedBrain()
        let text = SceneElement(id: "t", kind: "text", label: "Destinations", pos: [0.05, 0.1, 0.08, 0.012])
        let stranger = SceneElement(id: "s", kind: "control", label: "Render", pos: [0.9, 0.9, 0.05, 0.02])
        let out = brain.enrich([text, stranger])
        XCTAssertEqual(out[0], text)
        XCTAssertEqual(out[1], stranger)
    }

    // MARK: B5 — the naming ledger

    func testLLMNameIsImmutableToObservationChurn() {
        var brain = UIBrain()
        _ = BrainUpdater.ingest([det("control", "", x: 0.2, y: 0.2)], into: &brain, now: t0)
        let key = brain.objects[0].anchorKey
        XCTAssertTrue(BrainUpdater.setName("tracks list menu button", anchorKey: key, into: &brain, now: t0))
        // a later OCR caption at the same spot must NOT overwrite the llm name…
        _ = BrainUpdater.ingest([det("control", "TRACKS", x: 0.2, y: 0.2)], into: &brain, now: t1)
        XCTAssertEqual(brain.objects[0].label, "tracks list menu button")
        XCTAssertEqual(brain.objects[0].labelSource, "llm")
        XCTAssertTrue(brain.objects[0].aliases.contains("TRACKS"))        // …but survives as an alias
        // and enrich propagates the llm name onto unlabeled detections (the recalled path)
        let el = SceneElement(id: "x", kind: "control", label: "(unlabeled)",
                              pos: [0.2, 0.2, 0.03, 0.017], unlabeled: true)
        XCTAssertEqual(brain.enrich([el])[0].label, "tracks list menu button")
    }

    func testSetNamePreservesOldObservedLabelAsAlias() {
        var brain = UIBrain()
        _ = BrainUpdater.ingest([det("control", "wavafarm", x: 0.3, y: 0.3)], into: &brain, now: t0)
        let key = brain.objects[0].anchorKey
        _ = BrainUpdater.setName("waveform view selector", anchorKey: key, into: &brain, now: t1)
        XCTAssertEqual(brain.objects[0].label, "waveform view selector")
        XCTAssertTrue(brain.objects[0].aliases.contains("wavafarm"))      // the misread still matches scenes
    }

    func testNamingOpportunitiesRankByUsage() {
        var brain = UIBrain()
        _ = BrainUpdater.ingest(switchColumn(states: Array(repeating: "off", count: 8)), into: &brain, now: t0)
        // two unlabeled icons: one heavily used with a trusted transition, one seen once
        brain.objects.append(UIObjectAnchor(anchorKey: "hot", kind: "icon", label: "",
                                            boundsTypical: [0.5, 0.5, 0.02, 0.02],
                                            seenCount: 40, firstSeen: t0, lastSeen: t0))
        brain.objects.append(UIObjectAnchor(anchorKey: "cold", kind: "icon", label: "",
                                            boundsTypical: [0.6, 0.6, 0.02, 0.02],
                                            seenCount: 1, firstSeen: t0, lastSeen: t0))
        _ = BrainUpdater.recordTransition(anchorKey: "hot", trigger: "click", effect: "menuOpened:A|B", into: &brain, now: t0)
        _ = BrainUpdater.recordTransition(anchorKey: "hot", trigger: "click", effect: "menuOpened:A|B", into: &brain, now: t0)
        let opps = brain.namingOpportunities(limit: 5)
        XCTAssertEqual(opps.first?.anchor.anchorKey, "hot")               // usage beats existence
        XCTAssertTrue(opps.first?.context.contains("menu") == true)       // behavior shown as naming context
        XCTAssertTrue(opps.allSatisfy { $0.anchor.label.isEmpty })        // named things never reappear
    }

    // MARK: decay — the brain forgets by evidence

    /// Forgetting is measured in OBSERVATIONS of the app, never in days.
    func testDecayDropsTransientsKeepsEstablished() {
        var brain = UIBrain(ingestEpoch: 200)
        let old = t0.addingTimeInterval(-40 * 86400)                     // 40 days ago — the calendar is irrelevant
        brain.objects = [
            UIObjectAnchor(anchorKey: "est", kind: "control", label: "Export", boundsTypical: [0.1, 0.1, 0.05, 0.02],
                           seenCount: 12, firstSeen: old, lastSeen: old, lastSeenEpoch: 196),    // established, 4 observations ago → kept
            UIObjectAnchor(anchorKey: "tran", kind: "icon", label: "", boundsTypical: [0.2, 0.1, 0.02, 0.02],
                           seenCount: 1, firstSeen: old, lastSeen: old, lastSeenEpoch: 180),     // seen once, 20 observations ago → dropped
            UIObjectAnchor(anchorKey: "ancient", kind: "control", label: "Old", boundsTypical: [0.3, 0.1, 0.05, 0.02],
                           seenCount: 50, firstSeen: old, lastSeen: old, lastSeenEpoch: 40),     // 160 observations unseen → dropped
        ]
        brain.transitions = [
            UITransition(anchorKey: "est", trigger: "click", effect: "menuOpened:A|B", evidence: 3, lastObserved: old, lastObservedEpoch: 150),   // trusted → kept
            UITransition(anchorKey: "est", trigger: "click", effect: "elementsAppeared:X", evidence: 1, lastObserved: old, lastObservedEpoch: 160), // coincidence, 40 obs → dropped
        ]
        BrainUpdater.decay(&brain, now: t0)
        XCTAssertEqual(brain.objects.map(\.anchorKey), ["est"])
        XCTAssertEqual(brain.transitions.count, 1)
        XCTAssertEqual(brain.transitions[0].evidence, 3)
    }

    /// THE 2026-09-06 DISEASE: an app nobody looked at for weeks must not forget. Every date is stale,
    /// no observation happened, so nothing is evidence of absence — everything stays.
    func testDormantAppForgetsNothing() {
        var brain = UIBrain(ingestEpoch: 300)
        let stale = t0.addingTimeInterval(-45 * 86400)
        brain.objects = [
            UIObjectAnchor(anchorKey: "a", kind: "control", label: "Bounce", boundsTypical: [0.1, 0.1, 0.05, 0.02], seenCount: 9, firstSeen: stale, lastSeen: stale, lastSeenEpoch: 300),
            UIObjectAnchor(anchorKey: "b", kind: "icon", label: "", boundsTypical: [0.2, 0.1, 0.02, 0.02], seenCount: 1, firstSeen: stale, lastSeen: stale, lastSeenEpoch: 299),
        ]
        brain.transitions = [UITransition(anchorKey: "a", trigger: "click", effect: "menuOpened:A", evidence: 1, lastObserved: stale, lastObservedEpoch: 299)]
        BrainUpdater.decay(&brain, now: t0)
        XCTAssertEqual(brain.objects.count, 2)
        XCTAssertEqual(brain.transitions.count, 1)
    }

    /// A name someone ASSIGNED survives any amount of not being shown and outranks everything at the cap.
    func testProtectedNamesAreNeverDecayed() {
        var brain = UIBrain(ingestEpoch: 5000)
        let ancient = t0.addingTimeInterval(-400 * 86400)
        brain.objects = [
            UIObjectAnchor(anchorKey: "taught", kind: "icon", label: "Solo Safe", labelSource: "llm", boundsTypical: [0.1, 0.1, 0.02, 0.02],
                           seenCount: 1, firstSeen: ancient, lastSeen: ancient, lastSeenEpoch: 1),
            UIObjectAnchor(anchorKey: "obs", kind: "icon", label: "Mute", labelSource: "observed", boundsTypical: [0.2, 0.1, 0.02, 0.02],
                           seenCount: 500, firstSeen: t0, lastSeen: t0, lastSeenEpoch: 5000),
            UIObjectAnchor(anchorKey: "obs2", kind: "icon", label: "Rec", boundsTypical: [0.3, 0.1, 0.02, 0.02],
                           seenCount: 400, firstSeen: t0, lastSeen: t0, lastSeenEpoch: 5000),
        ]
        BrainUpdater.decay(&brain, now: t0, maxObjects: 1)
        XCTAssertEqual(brain.objects.map(\.anchorKey), ["taught", "obs"], "protected are outside the cap; the cap keeps the most established")
    }

    /// Legacy rows carry no epoch: the first ingest stamps them with the current one, so they start ageing
    /// from NOW — a brain upgraded today loses nothing today.
    func testLegacyRowsAreStampedOnFirstIngestNotDropped() {
        var brain = UIBrain()
        let stale = t0.addingTimeInterval(-60 * 86400)
        brain.objects = (0..<5).map { i in
            UIObjectAnchor(anchorKey: "l\(i)", kind: "control", label: "Legacy \(i)", boundsTypical: [0.1, 0.1 + 0.1 * Double(i), 0.05, 0.02],
                           seenCount: 1, firstSeen: stale, lastSeen: stale)
        }
        _ = BrainUpdater.ingest([det("control", "Something new", x: 0.8, y: 0.8), det("control", "B", x: 0.8, y: 0.6), det("control", "C", x: 0.8, y: 0.4)],
                                into: &brain, now: t0)
        XCTAssertEqual(brain.ingestEpoch, 1)
        XCTAssertEqual(brain.objects.count, 8, "no legacy row was dropped by the upgrade")
        XCTAssertTrue(brain.objects.filter { $0.label.hasPrefix("Legacy") }.allSatisfy { $0.lastSeenEpoch == 0 })
        XCTAssertEqual(brain.objects.first { $0.label == "Something new" }?.lastSeenEpoch, 1)
        // …and they DO age by observation from here: 12 more observation BLOCKS (≥10 min apart) of a
        // substantial scene without them → transients gone.
        let scene = [det("control", "Something new", x: 0.8, y: 0.8), det("control", "B", x: 0.8, y: 0.6), det("control", "C", x: 0.8, y: 0.4)]
        for i in 1...12 { _ = BrainUpdater.ingest(scene, into: &brain, now: t0.addingTimeInterval(Double(i) * UIBrain.observationBlock)) }
        XCTAssertEqual(Set(brain.objects.map(\.label)), ["Something new", "B", "C"])
        XCTAssertEqual(brain.objects.first { $0.label == "Something new" }?.seenCount, 13)
    }

    func testDecayDissolvesGroupsBelowThreeMembers() {
        var brain = trainedBrain()                                       // 8-member switch column at t0
        // 20 observations later, 6 of the 8 members were never seen again (transients); two are established.
        brain.ingestEpoch += 20
        for i in brain.objects.indices {
            if brain.objects[i].label == "Facebook" || brain.objects[i].label == "TikTok" {
                brain.objects[i].seenCount = 9; brain.objects[i].lastSeenEpoch = brain.ingestEpoch
            }
        }
        BrainUpdater.decay(&brain, now: t0)
        XCTAssertTrue(brain.groups.isEmpty)                              // 2 survivors < 3 → dissolved
        XCTAssertTrue(brain.objects.allSatisfy { $0.groupID == nil })    // survivors ungrouped, not dangling
    }

    func testDecayHardCapKeepsMostEstablished() {
        var brain = UIBrain()
        for i in 0..<10 {
            brain.objects.append(UIObjectAnchor(anchorKey: "k\(i)", kind: "icon", label: "icon \(i)",
                                                boundsTypical: [0.1, Double(i) * 0.05, 0.02, 0.02],
                                                seenCount: i + 2, firstSeen: t0, lastSeen: t0))
        }
        BrainUpdater.decay(&brain, now: t0, maxObjects: 4)
        XCTAssertEqual(brain.objects.count, 4)
        XCTAssertEqual(Set(brain.objects.map(\.anchorKey)), ["k9", "k8", "k7", "k6"])   // highest seenCount win (order preserved)
    }

    // MARK: persistence back-compat

    func testAppKnowledgeWithoutBrainKeyDecodes() throws {
        let old = #"{"bundleID":"com.x","windows":[],"menuCommands":[]}"#
        let app = try DescriptorStore.makeDecoder().decode(AppKnowledge.self, from: Data(old.utf8))
        XCTAssertTrue(app.brain.objects.isEmpty)
        // and round-trips with the brain populated
        var copy = app
        copy.brain.objects.append(UIObjectAnchor(kind: "control", label: "Export",
                                                 boundsTypical: [0.1, 0.1, 0.03, 0.02],
                                                 firstSeen: t0, lastSeen: t0))
        let data = try DescriptorStore.makeEncoder().encode(copy)
        let back = try DescriptorStore.makeDecoder().decode(AppKnowledge.self, from: data)
        XCTAssertEqual(back.brain.objects.count, 1)
    }

    // MARK: the observation clock (review findings, 2026-09-06)

    private func scene(_ labels: [String], x: Double = 0.5) -> [BrainDetection] {
        labels.enumerated().map { det("control", $0.element, x: x, y: 0.1 + 0.05 * Double($0.offset)) }
    }

    /// A scroll burst is ONE look: 150 parses inside a minute tick the clock once and drop nothing.
    func testClockTicksOncePerObservationBlock() {
        var brain = UIBrain()
        _ = BrainUpdater.ingest(scene(["Bounce", "Mix", "Edit"]), into: &brain, now: t0)
        for i in 1...150 { _ = BrainUpdater.ingest(scene(["Mix", "Edit", "Save"]), into: &brain, now: t0.addingTimeInterval(Double(i) * 0.4)) }
        XCTAssertEqual(brain.ingestEpoch, 1)
        XCTAssertTrue(brain.objects.contains { $0.label == "Bounce" }, "seen once, but the app was observed only ONCE since")
    }

    /// Parses of one window are not evidence that another window's controls are gone.
    func testOtherWindowsParsesAreNotEvidenceOfAbsence() {
        var brain = UIBrain()
        _ = BrainUpdater.ingest(scene(["Bounce", "Mix", "Edit"]), into: &brain, now: t0, window: "bounce")
        let bounce = brain.objects.first { $0.label == "Bounce" }!
        XCTAssertEqual(bounce.window, "bounce")
        // 200 observation blocks of the Edit window, none showing Bounce.
        for i in 1...200 { _ = BrainUpdater.ingest(scene(["Tracks", "Clips", "Save"]), into: &brain, now: t0.addingTimeInterval(Double(i) * UIBrain.observationBlock), window: "edit") }
        XCTAssertTrue(brain.objects.contains { $0.anchorKey == bounce.anchorKey }, "its own window was never looked at again")
        // 12 blocks of the Bounce window without it → a transient, gone.
        for i in 201...212 { _ = BrainUpdater.ingest(scene(["Mix", "Edit", "Other"]), into: &brain, now: t0.addingTimeInterval(Double(i) * UIBrain.observationBlock), window: "bounce") }
        XCTAssertFalse(brain.objects.contains { $0.anchorKey == bounce.anchorKey })
    }

    /// A single-detection upsert (the popup-reveal path) and a text-only frame are not observations.
    func testSmallIngestsDoNotTickTheClock() {
        var brain = UIBrain()
        _ = BrainUpdater.ingest(scene(["A", "B", "C"]), into: &brain, now: t0)
        for i in 1...50 { _ = BrainUpdater.ingest([det("control", "Lone", x: 0.9, y: 0.9)], into: &brain, now: t0.addingTimeInterval(Double(i) * UIBrain.observationBlock)) }
        for i in 51...60 { _ = BrainUpdater.ingest([det("text", "just text", x: 0.9, y: 0.9)], into: &brain, now: t0.addingTimeInterval(Double(i) * UIBrain.observationBlock)) }
        XCTAssertEqual(brain.ingestEpoch, 1)
        XCTAssertEqual(brain.objects.count, 4)
    }

    /// A popup-verified reveal (trusted at evidence 1) lives while its revealer is on screen; an evidence-1
    /// redraw coincidence on the same always-visible control still decays.
    func testTrustedRevealSurvivesWhileRevealerOnScreenButCoincidencesDecay() {
        var brain = UIBrain()
        _ = BrainUpdater.ingest(scene(["File", "Edit", "View"]), into: &brain, now: t0)
        let file = brain.objects.first { $0.label == "File" }!.anchorKey
        _ = BrainUpdater.recordTransition(anchorKey: file, trigger: "click", effect: "menuOpened:New|Open|Save", into: &brain, now: t0)
        _ = BrainUpdater.recordTransition(anchorKey: file, trigger: "click", effect: "elementsAppeared:Tooltip", into: &brain, now: t0)
        for i in 1...40 { _ = BrainUpdater.ingest(scene(["File", "Edit", "View"]), into: &brain, now: t0.addingTimeInterval(Double(i) * UIBrain.observationBlock)) }
        XCTAssertEqual(brain.transitions.map(\.effect), ["menuOpened:New|Open|Save"])
    }

    /// Two near-identical siblings on screen every frame are marked PRESENT even though neither is picked.
    func testAmbiguousSiblingsStayPresentAndKeepTheirKeys() {
        var brain = UIBrain()
        let pair = [det("control", "Mute", x: 0.1, y: 0.30), det("control", "Mute", x: 0.1, y: 0.33), det("control", "Solo", x: 0.2, y: 0.30)]
        _ = BrainUpdater.ingest(pair, into: &brain, now: t0)
        let keys = Set(brain.objects.map(\.anchorKey))
        for i in 1...20 { _ = BrainUpdater.ingest(pair, into: &brain, now: t0.addingTimeInterval(Double(i) * UIBrain.observationBlock)) }
        XCTAssertEqual(brain.objects.count, 3)
        XCTAssertEqual(Set(brain.objects.map(\.anchorKey)), keys, "no churn: the same anchors survive")
    }

    /// Protected rows are outside the cap; the cap trims the unprotected by establishment.
    func testCapKeepsAllProtectedAndTrimsUnprotected() {
        var brain = UIBrain(ingestEpoch: 10)
        for i in 0..<5 {
            brain.objects.append(UIObjectAnchor(anchorKey: "p\(i)", kind: "icon", label: "Taught \(i)", labelSource: "llm",
                                                boundsTypical: [0.1, Double(i) * 0.05, 0.02, 0.02], seenCount: 1, firstSeen: t0, lastSeen: t0, lastSeenEpoch: 10))
        }
        for i in 0..<6 {
            brain.objects.append(UIObjectAnchor(anchorKey: "u\(i)", kind: "icon", label: "Seen \(i)",
                                                boundsTypical: [0.5, Double(i) * 0.05, 0.02, 0.02], seenCount: i + 2, firstSeen: t0, lastSeen: t0, lastSeenEpoch: 10))
        }
        BrainUpdater.decay(&brain, now: t0, maxObjects: 3)
        XCTAssertEqual(brain.objects.filter(\.isProtected).count, 5)
        XCTAssertEqual(Set(brain.objects.filter { !$0.isProtected }.map(\.anchorKey)), ["u5", "u4", "u3"])
    }
}
