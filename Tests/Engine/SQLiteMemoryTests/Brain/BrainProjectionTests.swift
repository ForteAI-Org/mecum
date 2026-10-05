//
//  BrainProjectionTests.swift
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

/// The stored projection of a brain equals the pure brain run on the same sequence with the same
/// identities, step by step, after reopening, through retirement and reappearance, and through every
/// reader the engine uses today. The sequences are the ones of `UIBrainTests` and of the S0 proofs
/// P1 to P14; nothing is normalized away before comparing.
@Suite("The brain's stored projection equals the pure brain")
struct BrainProjectionTests {

    private typealias F = BrainFixtures

    private func det(_ kind: ElementKind, _ label: String, x: Double, y: Double,
                     w: Double = 0.03, h: Double = 0.017, state: ControlState? = nil) -> BrainDetection {
        F.det(kind, label, x: x, y: y, w: w, h: h, state: state)
    }

    @Test("every step of a mixed sequence round-trips: groups, states, ordinal rescue, impostors, ambiguity, records, naming, small ingests and the cap")
    func roundTripAfterEveryStep() async throws {
        let twin = try await F.Twin()
        let header = det(.text, "Destinations", x: 0.20, y: 0.15, w: 0.08, h: 0.012)
        try await twin.ingest(F.switchColumn(states: Array(repeating: .off, count: 8)) + [header], at: F.t0)
        #expect(twin.reference.groups.first?.name == "Destinations")
        try await twin.ingest(F.switchColumn(states: [.off, .off, .on, .off, .off, .off, .off, .off]), at: F.t1)
        #expect(twin.anchor(labeled: "Facebook")?.statesSeen == ["off": 1, "on": 1])
        let rescued = try await twin.ingest([det(.control, "", x: 0.236, y: 0.18 + 3 * 0.036, state: .off)], at: F.t1)
        #expect(rescued.updated == 1 && rescued.created == 0)
        let sidebar = (0..<4).map {
            det(.control, ["Home", "Downloads", "Documents", "Desktop"][$0], x: 0.028, y: 0.18 + Double($0) * 0.036, w: 0.06)
        }
        try await twin.ingest(sidebar, at: F.t1)
        #expect(twin.reference.groups.count == 2)
        let pair = [det(.control, "Mute", x: 0.6, y: 0.30), det(.control, "Mute", x: 0.6, y: 0.33), det(.control, "Solo", x: 0.7, y: 0.30)]
        try await twin.ingest(pair, at: F.t1)
        let ambiguous = try await twin.ingest([det(.control, "Mute", x: 0.6, y: 0.315)], at: try F.block(1))
        #expect(ambiguous.skippedAmbiguous == 1)
        let platform = F.element("control|platform", "Platform", x: 0.5, y: 0.1)
        try await twin.record(platform, effect: .menuOpened(labels: ["Desktop", "Mobile", "Web"]), at: try F.block(1))
        try await twin.record(platform, effect: .elementsAppeared(labels: ["Desktop"]), at: try F.block(1))
        let second = try await twin.record(platform, effect: .elementsAppeared(labels: ["Desktop"]), at: try F.block(1))
        guard case .recorded(let platformKey, 2) = second else {
            Issue.record("expected evidence 2, got \(second)")
            return
        }
        #expect(twin.reference.does(anchorKey: platformKey) == "click: reveals elements", "evidence two outranks the reveal's one")
        let tiktok = try #require(twin.anchor(labeled: "TikTok"))
        try await twin.setName("Fourth destination", anchorKey: tiktok.anchorKey, at: try F.block(1))
        #expect(twin.anchor(labeled: "Fourth destination")?.aliases == ["TikTok"])
        for i in 2...6 {
            try await twin.ingest([det(.control, "Lone", x: 0.9, y: 0.9)], at: try F.block(i))
        }
        #expect(twin.reference.ingestEpoch == 1, "only the first scene was substantial and far enough from the previous tick")
        let report = try await twin.decay(at: try F.block(6), maxObjects: 6)
        #expect(report.anchors.values.allSatisfy { $0 == .cap })
        #expect(twin.reference.objects.filter { !$0.isProtected }.count == 6)
        #expect(twin.reference.objects.contains { $0.label == "Fourth destination" }, "a protected name sits outside the cap")
        await twin.close()
    }

    @Test("one anchor may be a member of two groups while the current group is the one the algorithm last assigned")
    func overlappingGroupsKeepTheCurrentGroup() async throws {
        func detections(column: Bool) -> [BrainDetection] {
            ["A", "B", "C"].enumerated().map { i, label in
                det(.control, label, x: column ? 0.2 : 0.2 + Double(i) * 0.15, y: column ? 0.1 + Double(i) * 0.1 : 0.1)
            }
        }
        let twin = try await F.Twin()
        try await twin.ingest(detections(column: true), at: F.t0)
        let column = try #require(twin.reference.groups.first?.id)
        try await twin.ingest(detections(column: false), at: F.t0)
        let row = try #require(twin.reference.groups.last?.id)
        #expect(twin.reference.groups.count == 2 && row != column)
        #expect(twin.reference.objects.allSatisfy { $0.groupID == row })
        let memberships = try await twin.memory.integers(
            "SELECT count(*) FROM brain_group_members GROUP BY anchor_id ORDER BY anchor_id"
        )
        #expect(memberships == [2, 2, 2])
        #expect(try await twin.memory.texts("SELECT DISTINCT current_group_id FROM brain_anchors") == [row.uuidString])
        try await twin.ingest(detections(column: true), at: F.t0)
        #expect(twin.reference.groups.count == 2)
        #expect(twin.reference.objects.allSatisfy { $0.groupID == column })
        #expect(try await twin.memory.texts("SELECT DISTINCT current_group_id FROM brain_anchors") == [column.uuidString])
        #expect(try await twin.memory.integers("SELECT count(*) FROM brain_group_members GROUP BY anchor_id") == [2, 2, 2])
        #expect(try await twin.memory.foreignKeyCheck() == 0)
        await twin.close()
    }

    @Test("after closing and reopening the file the projection has the same keys, orders, aliases, members, exact REALs and dates")
    func reopenKeepsIdentities() async throws {
        let twin = try await F.Twin()
        try await twin.ingest(F.switchColumn(states: Array(repeating: .off, count: 8)), at: try F.clock(0.123))
        let behance = try #require(twin.anchor(labeled: "Behance"))
        try await twin.setName("Behance switch", anchorKey: behance.anchorKey, at: try F.clock(7.5))
        try await twin.ingest([det(.control, "Behance Pro", x: 0.236, y: 0.18 + 0.036, state: .on)], at: try F.clock(9))
        try await twin.record(F.element("c|x", "X", x: 0.236, y: 0.18 + 5 * 0.036), effect: .menuOpened(labels: ["Tweet", "Thread"]), at: try F.clock(10))
        let expected = twin.reference
        await twin.close()

        let reopened = try await F.open(at: twin.memory.url)
        let loaded = try await reopened.load()
        #expect(loaded == expected)
        #expect(try await reopened.texts("SELECT anchor_id FROM brain_anchors ORDER BY insertion_order") == expected.objects.map(\.anchorKey))
        #expect(try await reopened.texts("SELECT alias FROM brain_anchor_aliases ORDER BY position") == ["Behance", "Behance Pro"])
        #expect(try await reopened.texts("SELECT anchor_id FROM brain_group_members ORDER BY position") == expected.groups[0].memberAnchors)
        #expect(loaded?.objects.map(\.boundsTypical.y) == (0..<8).map { 0.18 + Double($0) * 0.036 })
        #expect(loaded?.objects.first?.firstSeen == (try F.clock(0.123)))
        #expect(loaded?.lastEpochAdvance == (try F.clock(0.123)))
        await reopened.store.close()
    }

    @Test("a retired anchor that reappears is a new identity with the state seen now and nothing inherited; the retired row keeps its history")
    func reappearanceIsANewIdentity() async throws {
        let twin = try await F.Twin()
        let base = F.scene(["A", "B", "C"])
        let flash = det(.control, "Flash", x: 0.8, y: 0.8, state: .off)
        try await twin.ingest(base + [flash], at: try F.block(0))
        let old = try #require(twin.anchor(labeled: "Flash"))
        try await twin.record(F.element("c|flash", "Flash", x: 0.8, y: 0.8), effect: .menuOpened(labels: ["Now", "Later"]), at: try F.block(0))
        for i in 1...12 { try await twin.ingest(base, at: try F.block(i)) }
        #expect(twin.anchor(labeled: "Flash") == nil)
        #expect(try await twin.memory.texts("SELECT retirement_cause FROM brain_anchors WHERE anchor_id = ?", [.text(old.anchorKey)]) == ["transient"])
        #expect(try await twin.memory.integers("SELECT retired_epoch FROM brain_anchors WHERE anchor_id = ?", [.text(old.anchorKey)]) == [13])
        #expect(try await twin.memory.texts("SELECT retirement_cause FROM brain_transitions WHERE anchor_id = ?", [.text(old.anchorKey)]) == ["anchor"])

        try await twin.ingest(base + [det(.control, "Flash", x: 0.8, y: 0.8, state: .on)], at: try F.block(13))
        let fresh = try #require(twin.anchor(labeled: "Flash"))
        #expect(fresh.anchorKey != old.anchorKey)
        #expect(fresh.seenCount == 1 && fresh.aliases.isEmpty && fresh.statesSeen == ["on": 1] && fresh.groupID == nil)
        #expect(twin.reference.transitions.filter { $0.anchorKey == fresh.anchorKey }.isEmpty)
        #expect(try await twin.memory.texts("SELECT state FROM brain_anchor_states WHERE anchor_id = ?", [.text(old.anchorKey)]) == ["off"])
        #expect(try await twin.memory.integers("SELECT count(*) FROM brain_anchors WHERE label = 'Flash'") == [2])
        #expect(try await twin.memory.integers("SELECT count(*) FROM brain_anchors WHERE label = 'Flash' AND retired_at_ms IS NULL") == [1])
        #expect(try await twin.memory.foreignKeyCheck() == 0)
        await twin.close()
    }

    @Test("aliases keep their order of appearance, a deliberate name keeps the old label as an alias, and the readers agree after reopening")
    func aliasOrder() async throws {
        let twin = try await F.Twin()
        try await twin.ingest([det(.control, "Send", x: 0.3, y: 0.3)], at: F.t0)
        let key = try #require(twin.reference.objects.first?.anchorKey)
        try await twin.setName("Submit", anchorKey: key, at: F.t0)
        try await twin.ingest([det(.control, "Send now", x: 0.3, y: 0.3)], at: F.t1)
        try await twin.ingest([det(.control, "Invia", x: 0.3, y: 0.3)], at: F.t1)
        #expect(twin.reference.objects[0].aliases == ["Send", "Send now", "Invia"])
        #expect(twin.reference.objects[0].labelSource == .llm)
        try await twin.record(F.element("c|submit", "Submit", x: 0.3, y: 0.3), effect: .menuOpened(labels: ["Mail", "Chat"]), at: F.t1)
        #expect(try await twin.memory.texts("SELECT alias FROM brain_anchor_aliases ORDER BY position") == ["Send", "Send now", "Invia"])
        #expect(try await twin.memory.integers("SELECT position FROM brain_anchor_aliases ORDER BY position") == [0, 1, 2])
        let reference = twin.reference
        await twin.close()
        let reopened = try await F.open(at: twin.memory.url)
        let loaded = try #require(try await reopened.load())
        #expect(loaded == reference)
        #expect(loaded.revealers(of: "chat") == reference.revealers(of: "chat"))
        #expect(loaded.revealers(of: "chat").first?.label == "Submit")
        #expect(loaded.namingOpportunities() == reference.namingOpportunities())
        await reopened.store.close()
    }

    @Test("members are reordered along the axis at every merge and an evicted member loses its row and its current group")
    func memberOrder() async throws {
        let twin = try await F.Twin()
        let four = (0..<4).map { det(.control, "S\($0)", x: 0.3, y: 0.2 + Double($0) * 0.05, state: .off) }
        try await twin.ingest(four, at: F.t0)
        let group = try #require(twin.reference.groups.first)
        #expect(group.memberAnchors == ["S0", "S1", "S2", "S3"].compactMap { twin.anchor(labeled: $0)?.anchorKey })
        try await twin.ingest(four + [det(.control, "S9", x: 0.3, y: 0.225, state: .off)], at: F.t1)
        let merged = try #require(twin.reference.groups.first)
        #expect(merged.id == group.id)
        #expect(merged.memberAnchors == ["S0", "S9", "S1", "S2", "S3"].compactMap { twin.anchor(labeled: $0)?.anchorKey })
        #expect(try await twin.memory.texts("SELECT anchor_id FROM brain_group_members WHERE group_id = ? ORDER BY position", [.text(group.id.uuidString)])
                == merged.memberAnchors)
        #expect(try await twin.memory.integers("SELECT position FROM brain_group_members ORDER BY position") == [0, 1, 2, 3, 4])
        #expect(merged.tag(forMember: try #require(twin.anchor(labeled: "S9")?.anchorKey)) == "column#2")

        let moved = four.dropLast() + [det(.control, "S3", x: 0.8, y: 0.35, state: .off), det(.control, "S9", x: 0.3, y: 0.225, state: .off)]
        try await twin.ingest(Array(moved), at: try F.block(1))
        let s3 = try #require(twin.anchor(labeled: "S3"))
        #expect(s3.groupID == nil && s3.boundsTypical.x == 0.8)
        #expect(!(twin.reference.groups.first?.memberAnchors.contains(s3.anchorKey) ?? true))
        #expect(try await twin.memory.integers("SELECT count(*) FROM brain_group_members WHERE anchor_id = ?", [.text(s3.anchorKey)]) == [0])
        #expect(try await twin.memory.texts("SELECT coalesce(current_group_id, '<null>') FROM brain_anchors WHERE anchor_id = ?", [.text(s3.anchorKey)]) == ["<null>"])
        await twin.close()
    }

    @Test("the cap on tied counts keeps what the pure brain keeps, retires the rest as cap, and a later anchor never reuses a retired order")
    func capWithTies() async throws {
        let twin = try await F.Twin()
        let ten = (0..<10).map { det(.icon, "icon \($0)", x: 0.1, y: Double($0) * 0.05, w: 0.02, h: 0.02) }
        try await twin.ingest(ten, at: F.t0)
        let report = try await twin.decay(at: F.t0, maxObjects: 4)
        #expect(report.anchors.count == 6 && report.anchors.values.allSatisfy { $0 == .cap })
        #expect(twin.reference.objects.count == 4)
        #expect(try await twin.memory.integers("SELECT count(*) FROM brain_anchors WHERE retirement_cause = 'cap'") == [6])
        let keptOrders = try await twin.memory.integers("SELECT insertion_order FROM brain_anchors WHERE retired_at_ms IS NULL ORDER BY insertion_order")
        #expect(keptOrders.count == 4 && Set(keptOrders.compactMap { $0 }).isSubset(of: Set(0...9)))
        try await twin.ingest([det(.icon, "icon 99", x: 0.9, y: 0.9, w: 0.02, h: 0.02)], at: F.t1)
        #expect(try await twin.memory.integers("SELECT insertion_order FROM brain_anchors WHERE label = 'icon 99'") == [10])
        await twin.close()
    }

    @Test("two trusted transitions tied on evidence are answered in insertion order by does and by the expectation, before and after reopening")
    func transitionTies() async throws {
        let twin = try await F.Twin()
        try await twin.ingest(F.scene(["Platform", "Files", "Edit"]), at: F.t0)
        let platform = F.element("c|platform", "Platform", x: 0.5, y: 0.1)
        try await twin.record(platform, effect: .menuOpened(labels: ["Desktop", "Mobile"]), at: F.t0)
        try await twin.record(platform, effect: .menuOpened(labels: ["Web"]), at: F.t0)
        let key = try #require(twin.anchor(labeled: "Platform")?.anchorKey)
        #expect(twin.reference.does(anchorKey: key) == "click: opens menu(Desktop|Mobile)")
        let reference = twin.reference
        await twin.close()
        let reopened = try await F.open(at: twin.memory.url)
        let loaded = try #require(try await reopened.load())
        #expect(loaded.transitions.map(\.effect) == ["menuOpened:Desktop|Mobile", "menuOpened:Web"])
        #expect(loaded.does(anchorKey: key) == reference.does(anchorKey: key))
        #expect(expectedEffect(of: .click, on: platform, in: loaded) == expectedEffect(of: .click, on: platform, in: reference))
        #expect(expectedEffect(of: .click, on: platform, in: loaded) == .menuOpened(labels: ["Desktop", "Mobile"]))
        #expect(try await reopened.integers("SELECT insertion_order FROM brain_transitions ORDER BY insertion_order") == [0, 1])
        await reopened.store.close()
    }

    @Test("a menu reveal whose revealer is seen again moves its epoch and not its date, outlives a coincidence, and dies stale without its revealer")
    func menuRevealerEpoch() async throws {
        let twin = try await F.Twin()
        let menu = F.scene(["File", "Edit", "View"])
        try await twin.ingest(menu, at: try F.block(0))
        let file = try #require(twin.anchor(labeled: "File"))
        try await twin.setName("File menu", anchorKey: file.anchorKey, at: try F.block(0))
        let element = F.element("c|file", "File", x: 0.5, y: 0.1)
        try await twin.record(element, effect: .menuOpened(labels: ["New", "Open", "Save"]), at: try F.block(0))
        try await twin.record(element, effect: .elementsAppeared(labels: ["Tooltip"]), at: try F.block(0))
        for i in 1...40 { try await twin.ingest(menu, at: try F.block(i)) }
        #expect(twin.reference.transitions.map(\.effect) == ["menuOpened:New|Open|Save"])
        let reveal = try await twin.memory.query(
            "SELECT last_seen_ms, last_observed_epoch FROM brain_transitions WHERE effect_kind = 'menuOpened'"
        ) { row in (row.integer(0), row.integer(1)) }
        #expect(reveal.map(\.0) == [try BrainClock.milliseconds(of: try F.block(0))])
        #expect(reveal.map(\.1) == [41])
        #expect(try await twin.memory.texts("SELECT retirement_cause FROM brain_transitions WHERE effect_kind = 'elementsAppeared'") == ["coincidence"])
        for i in 41...341 { try await twin.ingest(F.scene(["Other", "Stuff", "Here"], x: 0.8), at: try F.block(i)) }
        #expect(twin.reference.transitions.isEmpty)
        #expect(twin.anchor(labeled: "File menu") != nil, "a protected anchor is never retired")
        #expect(try await twin.memory.texts("SELECT retirement_cause FROM brain_transitions WHERE effect_kind = 'menuOpened'") == ["stale"])
        await twin.close()
    }

    @Test("parses of another window are not evidence of absence, and the per-window clock is stored one row per family")
    func windowClock() async throws {
        let twin = try await F.Twin()
        try await twin.ingest(F.scene(["Bounce", "Mix", "Edit"]), at: try F.block(0), window: "bounce")
        let bounce = try #require(twin.anchor(labeled: "Bounce"))
        for i in 1...150 { try await twin.ingest(F.scene(["Tracks", "Clips", "Save"]), at: try F.block(i), window: "edit") }
        #expect(twin.reference.objects.contains { $0.anchorKey == bounce.anchorKey })
        let epochs = try await twin.memory.query("SELECT window_family, epoch FROM brain_app_window_epochs ORDER BY window_family") { row in
            (try row.text(0) ?? "", Int(row.integer(1) ?? -1))
        }
        #expect(Dictionary(uniqueKeysWithValues: epochs) == twin.reference.windowEpochs)
        #expect(twin.reference.windowEpochs == ["bounce": 1, "edit": 150])
        for i in 151...162 { try await twin.ingest(F.scene(["Mix", "Edit", "Other"]), at: try F.block(i), window: "bounce") }
        #expect(!twin.reference.objects.contains { $0.anchorKey == bounce.anchorKey })
        #expect(try await twin.memory.texts("SELECT retirement_cause FROM brain_anchors WHERE anchor_id = ?", [.text(bounce.anchorKey)]) == ["transient"])
        await twin.close()
    }

    @Test("protected names are never retired and sit outside the cap")
    func protectedAndCap() async throws {
        let twin = try await F.Twin()
        try await twin.ingest(F.scene(["Solo Safe", "Mute", "Rec"]), at: try F.block(0))
        let taught = try #require(twin.anchor(labeled: "Solo Safe"))
        try await twin.setName("Solo safe switch", anchorKey: taught.anchorKey, at: try F.block(0))
        for _ in 0..<3 { try await twin.ingest([det(.control, "Mute", x: 0.5, y: 0.15)], at: try F.block(0)) }
        let rec = try #require(twin.anchor(labeled: "Rec"))
        let report = try await twin.decay(at: try F.block(0), maxObjects: 1)
        #expect(twin.reference.objects.map(\.label) == ["Solo safe switch", "Mute"])
        #expect(report.anchors == [rec.anchorKey: .cap])
        #expect(try await twin.memory.texts("SELECT label FROM brain_anchors WHERE retirement_cause = 'cap'") == ["Rec"])
        await twin.close()
    }

    @Test("retirement leaves every evidence row, every foreign key and every other application's rows exactly as they were")
    func retirementKeepsHistory() async throws {
        let twin = try await F.Twin()
        try await twin.ingest(F.switchColumn(states: Array(repeating: .off, count: 8)), at: try F.block(0))
        let group = try #require(twin.reference.groups.first)
        let media = try #require(twin.anchor(labeled: "Media File"))
        try await twin.record(F.element("c|media", "Media File", x: 0.236, y: 0.18), effect: .menuOpened(labels: ["Open"]), at: try F.block(0))
        // Another application through a repository of its own, so the twin's key sequence stays in step.
        let otherBrain = SQLiteBrainRepository(store: twin.memory.store)
        _ = try await otherBrain.ingest(F.scene(["Alpha", "Beta", "Gamma"]), into: F.other, now: try F.block(0), window: nil)
        let otherBefore = try await otherBrain.brain(of: F.other)
        let appID = try #require(try await twin.memory.integers("SELECT app_id FROM brain_apps WHERE bundle_id = ?", [.text(F.bundle)]).first ?? nil)
        let transitionID = try #require(try await twin.memory.texts("SELECT transition_id FROM brain_transitions").first)
        try await twin.memory.store.write { transaction in
            try transaction.execute(
                """
                INSERT INTO memory_events (event_id, source, source_stream_id, source_key, event_kind, app_id, occurred_at_ms, capture_status)
                VALUES ('ev1', 'cli', 'fixtures', 'ev1', 'action', ?, 1, 'not_applicable')
                """,
                [.integer(appID)]
            )
            for (column, value) in [("anchor_id", media.anchorKey), ("group_id", group.id.uuidString), ("transition_id", transitionID)] {
                try transaction.execute(
                    """
                    INSERT INTO brain_evidence (app_id, event_id, relation, assessed_by, assessment_version, assessed_at_ms, \(column))
                    VALUES (?, 'ev1', 'supports', 'fixture', '1', 1, ?)
                    """,
                    [.integer(appID), .text(value)]
                )
            }
        }
        for i in 1...12 { try await twin.ingest(F.scene(["Other1", "Other2", "Other3"], x: 0.8), at: try F.block(i)) }
        #expect(twin.reference.objects.filter { F.destinations.contains($0.label) }.isEmpty)
        #expect(!twin.reference.groups.contains { $0.id == group.id } && twin.reference.transitions.isEmpty)
        #expect(twin.reference.groups.count == 1, "the other scene's own column is alive")
        #expect(try await twin.memory.integers("SELECT count(*) FROM brain_anchors WHERE retirement_cause = 'transient'") == [8])
        #expect(try await twin.memory.texts("SELECT retirement_cause FROM brain_groups WHERE group_id = ?", [.text(group.id.uuidString)]) == ["members"])
        #expect(try await twin.memory.texts("SELECT retirement_cause FROM brain_transitions") == ["anchor"])
        #expect(try await twin.memory.integers("SELECT count(*) FROM brain_evidence") == [3])
        #expect(try await twin.memory.integers("SELECT count(*) FROM brain_group_members WHERE group_id = ?", [.text(group.id.uuidString)]) == [8],
                "a dissolved group keeps its last membership as history")
        #expect(try await twin.memory.foreignKeyCheck() == 0)
        #expect(try await otherBrain.brain(of: F.other) == otherBefore)
        #expect(otherBefore?.objects.count == 3)
        await twin.close()
    }

    @Test("the five effects are typed columns and ordered items, rebuilt to the exact string, with trust derived and never stored as a threshold")
    func fiveEffects() async throws {
        let twin = try await F.Twin()
        try await twin.ingest(F.scene(["Target", "B", "C"]), at: F.t0)
        let target = F.element("c|target", "Target", x: 0.5, y: 0.1)
        try await twin.record(target, effect: .windowTitleChanged(title: "Export: a|b > c"), at: F.t0)
        try await twin.record(target, effect: .stateFlip(from: .off, to: .on), at: F.t0)
        try await twin.record(target, effect: .menuOpened(labels: ["Desktop", "Mobile", "Web"]), at: F.t0)
        try await twin.record(target, effect: .elementsAppeared(labels: ["Queue"]), at: F.t0)
        try await twin.record(target, effect: .elementsDisappeared(labels: []), at: F.t0)
        let rows = try await twin.memory.query(
            """
            SELECT effect_kind, coalesce(effect_text, '<null>'), coalesce(required_target_state, '<null>'),
                   coalesce(resulting_target_state, '<null>'), status, evidence_count,
                   (SELECT group_concat(title, '/') FROM (SELECT title FROM brain_transition_menu_items i
                     WHERE i.transition_id = t.transition_id ORDER BY position))
            FROM brain_transitions t ORDER BY insertion_order
            """
        ) { row in
            [try row.text(0) ?? "", try row.text(1) ?? "", try row.text(2) ?? "", try row.text(3) ?? "", try row.text(4) ?? "",
             String(row.integer(5) ?? -1), try row.text(6) ?? "<none>"]
        }
        #expect(rows == [
            ["windowTitleChanged", "Export: a|b > c", "<null>", "<null>", "candidate", "1", "<none>"],
            ["stateFlip", "<null>", "off", "on", "candidate", "1", "<none>"],
            ["menuOpened", "<null>", "<null>", "<null>", "trusted", "1", "Desktop/Mobile/Web"],
            ["elementsAppeared", "<null>", "<null>", "<null>", "candidate", "1", "Queue"],
            ["elementsDisappeared", "<null>", "<null>", "<null>", "candidate", "1", "<none>"],
        ])
        try await twin.record(target, effect: .stateFlip(from: .off, to: .on), at: F.t1)
        #expect(try await twin.memory.texts("SELECT status FROM brain_transitions WHERE effect_kind = 'stateFlip'") == ["trusted"])
        #expect(try await twin.memory.integers("SELECT count(*) FROM brain_transitions") == [5], "evidence accrues on the same row")
        let reference = twin.reference
        await twin.close()
        let reopened = try await F.open(at: twin.memory.url)
        let loaded = try #require(try await reopened.load())
        #expect(loaded == reference)
        #expect(loaded.transitions.map(\.effect) == [
            "windowTitleChanged:Export: a|b > c", "stateFlip:off>on", "menuOpened:Desktop|Mobile|Web",
            "elementsAppeared:Queue", "elementsDisappeared:",
        ])
        #expect(loaded.transitions.map(\.sceneEffect) == reference.transitions.map(\.sceneEffect))
        #expect(loaded.transitions.map(\.isTrusted) == [false, true, true, false, false])
        #expect(try await reopened.texts("SELECT scene_kind FROM brain_scenes") == ["app"])
        let scope = try await reopened.texts("SELECT scene_id FROM brain_scenes WHERE scene_kind = 'app'")
        #expect(try await reopened.texts("SELECT DISTINCT from_scene_id FROM brain_transitions") == scope)
        #expect(try await reopened.integers("SELECT count(*) FROM brain_transitions WHERE to_scene_id IS NOT NULL") == [0])
        await reopened.store.close()
    }

    @Test("every active reader answers the same from the stored projection as from the pure brain")
    func activeReaders() async throws {
        let twin = try await F.Twin()
        let header = det(.text, "Destinations", x: 0.20, y: 0.15, w: 0.08, h: 0.012)
        try await twin.ingest(F.switchColumn(states: Array(repeating: .off, count: 8)) + [header], at: F.t0)
        try await twin.ingest(F.scene(["Platform", "Files", "Edit"]) + [det(.control, "", x: 0.7, y: 0.7, w: 0.02, h: 0.02)], at: F.t1)
        let platform = F.element("c|platform", "Platform", x: 0.5, y: 0.1)
        try await twin.record(platform, effect: .menuOpened(labels: ["Desktop", "Mobile", "Web"]), at: F.t1)
        try await twin.record(platform, effect: .elementsAppeared(labels: ["Desktop"]), at: F.t1)
        try await twin.record(platform, effect: .elementsAppeared(labels: ["Desktop"]), at: F.t1)
        let tiktok = try #require(twin.anchor(labeled: "TikTok"))
        try await twin.setName("Fourth destination", anchorKey: tiktok.anchorKey, at: F.t1)
        let reference = twin.reference
        await twin.close()
        let reopened = try await F.open(at: twin.memory.url)
        let loaded = try #require(try await reopened.load())
        let scene = [
            SceneElement(id: "x", kind: .control, label: "Facebook", bounds: F.rect(0.236, 0.18 + 2 * 0.036), state: .off),
            SceneElement(id: "anon", kind: .control, label: "(unlabeled)", bounds: F.rect(0.236, 0.18 + 3 * 0.036), state: .off, isUnlabeled: true),
            platform,
            SceneElement(id: "t", kind: .text, label: "Destinations", bounds: F.rect(0.05, 0.1, 0.08, 0.012)),
        ]
        #expect(loaded.enrich(scene) == reference.enrich(scene))
        #expect(loaded.enrich(scene)[0].group == "Destinations#3")
        #expect(loaded.enrich(scene)[1].label == "Fourth destination" && loaded.enrich(scene)[1].isRecalled)
        for anchor in reference.objects { #expect(loaded.does(anchorKey: anchor.anchorKey) == reference.does(anchorKey: anchor.anchorKey)) }
        #expect(loaded.revealers(of: "Mobile") == reference.revealers(of: "Mobile"))
        #expect(loaded.switchMemberSlots() == reference.switchMemberSlots())
        #expect(loaded.namingOpportunities() == reference.namingOpportunities())
        #expect(loaded.namingOpportunities().count == 1)
        for verb in [ActionVerb.click, .rightClick] {
            #expect(expectedEffect(of: verb, on: platform, in: loaded) == expectedEffect(of: verb, on: platform, in: reference))
        }
        #expect(expectedEffect(of: .click, on: platform, in: loaded) == .elementsAppeared(labels: ["Desktop"]), "evidence two outranks the reveal's one")
        let index = BrainIndex(loaded)
        for element in scene {
            #expect(BrainMatcher.match(BrainDetection(element), in: loaded, index: index)
                    == BrainMatcher.match(BrainDetection(element), in: reference))
        }
        await reopened.store.close()
    }

    @Test("F7: a scene without roles and without an accessibility read still teaches the brain every control and icon, while the sample keeps none of them")
    func pixelOnlyScene() async throws {
        let memory = try await F.open()
        let scene = SceneSnapshot(
            bundleID: F.bundle, appName: "Fixture", windowTitle: "Inbox 3",
            viewportPixelSize: ViewportPixelSize(width: 1000, height: 800),
            elements: [
                F.element("icon|a", "(unlabeled)", x: 0.1, y: 0.1, kind: .icon, unlabeled: true),
                F.element("icon|b", "(unlabeled)", x: 0.1, y: 0.2, kind: .icon, unlabeled: true),
                F.element("control|send", "Send", x: 0.3, y: 0.3),
                SceneElement(id: "text|t", kind: .text, label: "Inbox", bounds: F.rect(0.1, 0.05, 0.08, 0.012)),
            ]
        )
        #expect(scene.elements.allSatisfy { $0.role == nil })
        let perceived = PerceivedWindow(scene: scene, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        #expect(CaptureSample(key: CaptureSampleKey(eventID: "e", phase: .current), of: perceived).elements.isEmpty)
        #expect(perceived.capture.completeness == .unknown)
        let stats = try await memory.brain.observe(scene, now: F.t0)
        #expect(stats.created == 3)
        var reference = UIBrain()
        _ = BrainUpdater.ingest(scene.elements.map(BrainDetection.init), into: &reference, now: F.t0, window: "inbox", keys: BrainIdentities().keys)
        let loaded = try #require(try await memory.load())
        #expect(loaded == reference)
        #expect(loaded.objects.map(\.label) == ["", "", "Send"])
        #expect(loaded.objects.allSatisfy { $0.window == "inbox" })
        #expect(loaded.ingestEpoch == 1 && loaded.windowEpochs == ["inbox": 1])
        #expect(try await memory.texts("SELECT coalesce(label_source, '<null>') FROM brain_anchors ORDER BY insertion_order") == ["<null>", "<null>", "<null>"],
                "a fresh anchor has no label source until a refresh observes its label")
        await memory.store.close()
    }

    @Test("small ingests do not tick the clock; an empty label, a nil source and a nil window are stored as what they are, apart from empty text")
    func smallIngestsAndEmptyValues() async throws {
        let twin = try await F.Twin()
        try await twin.ingest(F.scene(["A", "B", "C"]), at: F.t0)
        for i in 1...50 { try await twin.ingest([det(.control, "Lone", x: 0.9, y: 0.9)], at: try F.block(i)) }
        for i in 51...60 { try await twin.ingest([det(.text, "just text", x: 0.9, y: 0.9)], at: try F.block(i)) }
        #expect(twin.reference.ingestEpoch == 1 && twin.reference.objects.count == 4)
        try await twin.ingest([det(.icon, "", x: 0.2, y: 0.2, w: 0.02, h: 0.02)], at: F.t1)
        try await twin.ingest([det(.control, "Framed", x: 0.4, y: 0.4)], at: F.t1, window: "")
        let rows = try await twin.memory.query(
            "SELECT label, coalesce(label_source, '<null>'), coalesce(window_family, '<null>') FROM brain_anchors ORDER BY insertion_order"
        ) { row in [try row.text(0) ?? "", try row.text(1) ?? "", try row.text(2) ?? ""] }
        #expect(rows.last == ["Framed", "<null>", ""])
        #expect(rows[4] == ["", "<null>", "<null>"])
        #expect(twin.reference.objects[5].window == "" && twin.reference.objects[4].window == nil)
        await twin.close()
    }

    @Test("the 600 s tick and the 365-day backstop decide the same on the canonical clock, at the boundary and one millisecond beyond")
    func clockBoundaries() async throws {
        let twin = try await F.Twin()
        try await twin.ingest(F.scene(["A", "B", "C"]), at: try F.clock(0))
        #expect(twin.reference.ingestEpoch == 1)
        try await twin.ingest(F.scene(["A", "B", "C"]), at: try F.clock(599.999))
        #expect(twin.reference.ingestEpoch == 1, "one millisecond short of the block")
        try await twin.ingest(F.scene(["A", "B", "C"]), at: try F.clock(600))
        #expect(twin.reference.ingestEpoch == 2)
        #expect(twin.reference.lastEpochAdvance == (try F.clock(600)))
        #expect(try await twin.memory.integers("SELECT last_epoch_advance_ms FROM brain_apps") == [try BrainClock.milliseconds(of: try F.clock(600))])

        let old = try await F.Twin()
        try await old.ingest([det(.control, "Old", x: 0.1, y: 0.1)], at: F.t0)
        let year = 365.0 * 86400
        try await old.decay(at: try F.clock(year))
        let atBoundary = old.reference.objects.count
        try await old.decay(at: try F.clock(year + 0.001))
        #expect(old.reference.objects.isEmpty)
        #expect(atBoundary == 1, "lastSeen equal to the backstop is not before it")
        #expect(try await old.memory.texts("SELECT retirement_cause FROM brain_anchors") == ["backstop"])
        await twin.close()
        await old.close()
    }

    @Test("an explicit decay retires with the rule the algorithm applied: transient, stale, backstop, cap; members, stale, backstop; anchor, coincidence, stale, backstop")
    func retirementCauses() async throws {
        let twin = try await F.Twin()
        let trio = (0..<3).map { det(.control, "P\($0)", x: 0.2, y: 0.1 + Double($0) * 0.1) }
        try await twin.ingest(trio + [det(.control, "Twice", x: 0.6, y: 0.6), det(.control, "Once", x: 0.7, y: 0.7)], at: try F.block(0))
        for label in ["P0", "P1", "P2"] {
            try await twin.setName("\(label) taught", anchorKey: try #require(twin.anchor(labeled: label)?.anchorKey), at: try F.block(0))
        }
        try await twin.record(F.element("c|p0", "P0", x: 0.2, y: 0.1), effect: .menuOpened(labels: ["Go"]), at: try F.block(0))
        try await twin.ingest([det(.control, "Twice", x: 0.6, y: 0.6)], at: try F.block(0))
        for i in 1...150 { try await twin.ingest(F.scene(["X", "Y", "Z"], x: 0.9), at: try F.block(i)) }
        let stale = try await twin.decay(at: try F.block(150))
        #expect(stale.isEmpty, "the ingests already decayed; nothing is left to retire")
        #expect(try await twin.memory.texts("SELECT retirement_cause FROM brain_anchors WHERE label = 'Once'") == ["transient"])
        #expect(try await twin.memory.texts("SELECT retirement_cause FROM brain_anchors WHERE label = 'Twice'") == ["stale"])
        #expect(try await twin.memory.texts("SELECT retirement_cause FROM brain_groups WHERE retired_at_ms IS NOT NULL") == ["stale"])
        #expect(twin.reference.groups.count == 1, "the X, Y, Z column of the later scenes is alive")
        #expect(twin.reference.transitions.count == 1, "a menu reveal on a protected anchor survives 150 observations")

        let far = try await F.Twin()
        try await far.ingest(trio + [det(.control, "Plain", x: 0.6, y: 0.6)], at: try F.block(0))
        for label in ["P0", "P1", "P2"] {
            try await far.setName("\(label) taught", anchorKey: try #require(far.anchor(labeled: label)?.anchorKey), at: try F.block(0))
        }
        try await far.record(F.element("c|p0", "P0", x: 0.2, y: 0.1), effect: .menuOpened(labels: ["Go"]), at: try F.block(0))
        let report = try await far.decay(at: try F.clock(400 * 86400))
        #expect(report.anchors.values.map { $0 } == [.backstop])
        #expect(report.groups.values.map { $0 } == [.backstop])
        #expect(report.transitions.values.map { $0 } == [.backstop])
        #expect(far.reference.objects.count == 3)
        #expect(try await far.memory.texts("SELECT retirement_cause FROM brain_anchors WHERE label = 'Plain'") == ["backstop"])
        #expect(try await far.memory.texts("SELECT retirement_cause FROM brain_groups") == ["backstop"])
        #expect(try await far.memory.texts("SELECT retirement_cause FROM brain_transitions") == ["backstop"])
        await twin.close()
        await far.close()
    }

    @Test("record keeps BrainMemory's rules: no effect teaches nothing, an unknown or ambiguous element teaches nothing unless it revealed a menu")
    func recordSemantics() async throws {
        let twin = try await F.Twin()
        let export = F.element("c|export", "Export", x: 0.1, y: 0.1)
        let outcome = try await twin.memory.brain.record(
            ActionRecord(bundleID: F.bundle, element: export, verb: .click, effect: nil, windowTitleAfter: nil), now: F.t0
        )
        #expect(outcome == .noEffect)
        #expect(try await twin.memory.load() == nil, "no effect, no application row")
        #expect(try await twin.record(export, effect: .stateFlip(from: .off, to: .on), at: F.t0) == .noAnchor)
        #expect(twin.reference.objects.isEmpty && twin.reference.transitions.isEmpty)
        #expect(try await twin.memory.load() == UIBrain(), "the application exists, the brain is empty")
        let reveal = try await twin.record(export, effect: .menuOpened(labels: ["Queue", "Export"]), at: F.t0)
        guard case .recorded(let key, 1) = reveal else {
            Issue.record("expected a recorded reveal, got \(reveal)")
            return
        }
        #expect(twin.reference.objects.map(\.anchorKey) == [key])
        #expect(twin.reference.transitions.first?.isTrusted == true)
        #expect(try await twin.record(export, effect: .menuOpened(labels: ["Queue", "Export"]), at: F.t1) == .recorded(anchorKey: key, evidence: 2))
        #expect(try await twin.record(export, effect: .stateFlip(from: .off, to: .on), at: F.t1) == .recorded(anchorKey: key, evidence: 1))
        #expect(expectedEffect(of: .click, on: export, in: twin.reference) == .menuOpened(labels: ["Queue", "Export"]))

        try await twin.ingest([det(.control, "Mute", x: 0.6, y: 0.30), det(.control, "Mute", x: 0.6, y: 0.33), det(.control, "Solo", x: 0.7, y: 0.30)], at: F.t1)
        let between = F.element("c|mute", "Mute", x: 0.6, y: 0.315)
        #expect(try await twin.record(between, effect: .stateFlip(from: .off, to: .on), at: F.t1) == .noAnchor)
        #expect(try await twin.record(between, effect: .menuOpened(labels: ["Unmute"]), at: F.t1) == .noAnchor,
                "an ambiguous pair is marked present and no anchor is invented")
        #expect(twin.reference.objects.count == 4)
        await twin.close()
    }

    @Test("setName keeps the old observed label as an alias and the llm source; an unknown anchor or an empty name changes nothing")
    func setNameSemantics() async throws {
        let twin = try await F.Twin()
        try await twin.ingest([det(.control, "wavafarm", x: 0.3, y: 0.3)], at: F.t0)
        let key = try #require(twin.reference.objects.first?.anchorKey)
        #expect(try await twin.setName("waveform view selector", anchorKey: key, at: F.t1))
        #expect(twin.reference.objects[0].label == "waveform view selector" && twin.reference.objects[0].aliases == ["wavafarm"])
        #expect(twin.reference.objects[0].labelSource == .llm && twin.reference.objects[0].lastSeen == F.t1)
        #expect(try await twin.setName("ghost", anchorKey: "nobody", at: F.t1) == false)
        #expect(try await twin.setName("   ", anchorKey: key, at: F.t1) == false)
        #expect(try await twin.memory.texts("SELECT label FROM brain_anchors") == ["waveform view selector"])
        await twin.close()
    }

    @Test("the identity-hygiene sequences of UIBrainTests give the same brain through the store: same detection, jitter, a unique label moving, the size gate, a conflicting label, slivers, no group, switch slots, a dormant application")
    func identityHygieneSequences() async throws {
        func run(_ steps: [(detections: [BrainDetection], at: Date)], decayAt: Date? = nil) async throws -> UIBrain {
            let twin = try await F.Twin()
            for step in steps { try await twin.ingest(step.detections, at: step.at) }
            if let decayAt { try await twin.decay(at: decayAt) }
            let result = twin.reference
            await twin.close()
            return result
        }
        let same = try await run([([det(.control, "Export", x: 0.1, y: 0.1)], F.t0), ([det(.control, "Export", x: 0.1, y: 0.1)], F.t1)])
        #expect(same.objects.count == 1 && same.objects[0].seenCount == 2)
        let jitter = try await run([([det(.control, "X", x: 0.30, y: 0.41)], F.t0), ([det(.control, "X X", x: 0.304, y: 0.412)], F.t1)])
        #expect(jitter.objects.count == 2)
        let spaced = try await run([([det(.control, "Media File", x: 0.30, y: 0.41)], F.t0), ([det(.control, "media  file", x: 0.304, y: 0.412)], F.t1)])
        #expect(spaced.objects.count == 1 && spaced.objects[0].seenCount == 2)
        let moved = try await run([([det(.control, "Export", x: 0.1, y: 0.1)], F.t0), ([det(.control, "Export", x: 0.7, y: 0.8)], F.t1)])
        #expect(moved.objects.count == 1 && moved.objects[0].boundsTypical.x == 0.7)
        let sized = try await run([
            ([det(.control, "Facebook", x: 0.211, y: 0.30, w: 0.025, h: 0.017, state: .off)], F.t0),
            ([det(.control, "Facebook", x: 0.05, y: 0.30, w: 0.073, h: 0.02)], F.t1),
        ])
        #expect(sized.objects.count == 2 && sized.objects[0].statesSeen == ["off": 1])
        let conflicting = try await run([
            (F.switchColumn(states: Array(repeating: .off, count: 8)), F.t0),
            ([det(.control, "Downloads", x: 0.236, y: 0.18 + 3 * 0.036)], F.t1),
        ])
        #expect(conflicting.objects.count == 9)
        #expect(conflicting.objects.first { $0.label == "TikTok" }.map { $0.seenCount == 1 && $0.aliases.isEmpty } == true)
        let slivers = try await run([([
            det(.icon, "", x: 0.968, y: 0.2, w: 0.004, h: 0.009), det(.icon, "", x: 0.968, y: 0.4, w: 0.004, h: 0.009),
            det(.icon, "", x: 0.968, y: 0.6, w: 0.004, h: 0.009),
        ], F.t0)])
        #expect(slivers.objects.isEmpty && slivers.groups.isEmpty)
        let pair = try await run([([det(.control, "A", x: 0.2, y: 0.1), det(.control, "B", x: 0.2, y: 0.2)], F.t0)])
        #expect(pair.groups.isEmpty)
        let slots = try await run([
            (F.switchColumn(states: Array(repeating: .off, count: 8)), F.t0),
            ([det(.icon, "a", x: 0.8, y: 0.1), det(.icon, "b", x: 0.8, y: 0.2), det(.icon, "c", x: 0.8, y: 0.3)], F.t1),
        ])
        #expect(slots.switchMemberSlots().count == 8 && slots.groups.count == 2)
        let dormant = try await run([(F.scene(["Bounce", "Mix", "Edit"]), F.t0)], decayAt: try F.clock(45 * 86400))
        #expect(dormant.objects.count == 3, "an application nobody looked at forgets nothing")
    }

    /// `BrainMemory.expectedEffect` on a brain already loaded: the strongest trusted transition of
    /// the element's anchor under the verb's trigger.
    private func expectedEffect(of verb: ActionVerb, on element: SceneElement, in brain: UIBrain) -> SceneEffect? {
        guard case .found(let key) = BrainMatcher.match(BrainDetection(element), in: brain) else { return nil }
        let trigger = TransitionTrigger(verb)
        return brain.transitions
            .filter { $0.anchorKey == key && $0.trigger == trigger && $0.isTrusted }
            .max { $0.evidence < $1.evidence }?
            .sceneEffect
    }
}
