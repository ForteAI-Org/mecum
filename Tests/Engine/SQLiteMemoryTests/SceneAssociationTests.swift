//
//  SceneAssociationTests.swift
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

/// The fifteen structure-v3 fixtures of the S0 specification, each a fake tree taken through the
/// producer, the merge, the pipeline and the store, and the acceptance criteria of the first S2
/// increment: no arbitrary confirmation, idempotent re-association, the app scope never a
/// candidate, one scene for two concurrent complete captures, and the signature rebuilt from SQL.
@Suite("Scene association, structure-v3")
struct SceneAssociationTests {

    private typealias F = SceneFixtures

    private func scenes(in memory: F.Memory) async throws -> Int64 {
        try await count("SELECT count(*) FROM brain_scenes WHERE scene_kind <> 'app'", in: memory.store)
    }

    private func observations(of scene: String, in memory: F.Memory) async throws -> Int64 {
        try await memory.store.read { snapshot in
            try snapshot.query("SELECT observation_count FROM brain_scenes WHERE scene_id = ?", [.text(scene)]) { $0.integer(0) ?? -1 }
                .first ?? -1
        }
    }

    /// F1 and F2 need a stable control outside the rows: a table of people alone is an empty
    /// skeleton, and an empty skeleton never creates a scene. The precondition is the fixture's.
    private func inbox(_ rows: [String], title: String = "Inbox") -> PerceivedWindow {
        F.perceive(F.window(title, [F.table("People", rows: rows), F.button("Compose", y: 700)]))
    }

    @Test("F1: two captures of a people table with different rows are one scene; rows and their buttons stay under the collection")
    func f1Rows() async throws {
        let memory = try await F.open()
        let first  = inbox(["Alice", "Bruno"])
        let firstSkeleton = SceneSkeleton(sample: F.sample("x", of: first))
        #expect(firstSkeleton.collections == ["People"])
        #expect(firstSkeleton.rolesByPath == ["": ["AXButton"]])
        #expect(firstSkeleton.captionsByPath == ["": [SceneSkeleton.Caption(role: "AXButton", label: "Compose")]])
        #expect(first.scene.elements.filter { $0.collectionPath == "People" }.count == 4)
        #expect(first.scene.elements.contains { $0.label == "Reply" && $0.container == "People / Alice" },
                "the model still addresses the button through its row")
        let one = try await F.observe(memory, "e1", first)
        #expect(one.decision == .newScene)
        #expect(one.createdSceneID == "scene-1")
        let two = try await F.observe(memory, "e2", inbox(["Carla", "Dino"]))
        #expect(two.decision == .confirmed(sceneID: "scene-1"))
        #expect(try await scenes(in: memory) == 1)
        #expect(try await observations(of: "scene-1", in: memory) == 2)
        #expect(try await count("SELECT count(*) FROM brain_scene_elements WHERE label LIKE '%Alice%' OR element_key LIKE '%Alice%'", in: memory.store) == 0,
                "no person in the structure")
        #expect(try await count("SELECT count(*) FROM brain_scene_elements WHERE element_scope = 'collection'", in: memory.store) == 1)
        #expect(try await count("SELECT count(*) FROM brain_scene_elements WHERE element_scope = 'item_template'", in: memory.store) == 1)
        await memory.store.close()
    }

    @Test("F2: scrolling the same table changes the rows and nothing structural")
    func f2Scroll() async throws {
        let memory = try await F.open()
        _ = try await F.observe(memory, "e1", inbox((1...5).map { "Person \($0)" }))
        let scrolled = try await F.observe(memory, "e2", inbox((4...9).map { "Person \($0)" }))
        #expect(scrolled.decision == .confirmed(sceneID: "scene-1"))
        #expect(try await scenes(in: memory) == 1)
        await memory.store.close()
    }

    @Test("F3: two documents with different window titles and the same tree are one scene; the title is a bucket hint only")
    func f3Titles() async throws {
        let memory = try await F.open()
        func document(_ title: String) -> PerceivedWindow {
            F.perceive(F.window(title, [F.button("Save", y: 700), F.textField(value: "body", y: 300, title: "Text")]))
        }
        _ = try await F.observe(memory, "e1", document("Alpha.txt"))
        let beta = try await F.observe(memory, "e2", document("Beta.txt"))
        #expect(beta.decision == .confirmed(sceneID: "scene-1"))
        let bucket = try await memory.store.read { snapshot in
            try snapshot.query("SELECT title_bucket, window_title_pattern FROM brain_scenes WHERE scene_id = 'scene-1'", []) {
                (try $0.text(0) ?? "", try $0.text(1))
            }.first
        }
        #expect(bucket?.0 == "alphatxt")
        #expect(bucket?.1 == nil)
        await memory.store.close()
    }

    @Test("F4: two save dialogs titled after their files are one dialog scene")
    func f4Dialogs() async throws {
        let memory = try await F.open()
        func save(_ file: String) -> PerceivedWindow {
            F.perceive(F.dialog("Save \(file)?", [F.button("Cancel", y: 700, x: 500), F.button("Save", y: 700)]))
        }
        let alpha = save("Alpha.txt")
        #expect(alpha.surface == .dialog)
        #expect(alpha.capture.windowSubrole == "AXDialog")
        _ = try await F.observe(memory, "e1", alpha)
        let beta = try await F.observe(memory, "e2", save("Beta.txt"))
        #expect(beta.decision == .confirmed(sceneID: "scene-1"))
        #expect(try await count("SELECT count(*) FROM brain_scenes WHERE scene_kind = 'dialog'", in: memory.store) == 1)
        await memory.store.close()
    }

    @Test("F5: a checkbox on and then off is one scene, and each sample keeps the state it saw")
    func f5State() async throws {
        let memory = try await F.open()
        func settings(on: Bool) -> PerceivedWindow {
            F.perceive(F.window("Settings", [F.checkbox("Track", on: on, y: 300), F.button("Done", y: 700)]))
        }
        _ = try await F.observe(memory, "e1", settings(on: true))
        let off = try await F.observe(memory, "e2", settings(on: false))
        #expect(off.decision == .confirmed(sceneID: "scene-1"))
        let before = try await memory.captures.sample(CaptureSampleKey(eventID: "e1", phase: .current))
        let after  = try await memory.captures.sample(CaptureSampleKey(eventID: "e2", phase: .current))
        #expect(before?.elements.first { $0.role == "AXCheckBox" }?.state == .on)
        #expect(after?.elements.first { $0.role == "AXCheckBox" }?.state == .off)
        #expect(try await count("SELECT count(*) FROM brain_scene_elements WHERE label = 'Track' AND label_origin = 'title'", in: memory.store) == 1)
        await memory.store.close()
    }

    @Test("F6: a walk the deadline stops is partial; it is never different, only a candidate, and never a new scene")
    func f6Deadline() async throws {
        let memory = try await F.open()
        let tree = { F.window("Inbox", [F.button("Compose", y: 700), F.table("People", rows: ["Alice", "Bruno"])]) }
        let cut = F.perceive(tree(), limits: .init(isPastDeadline: CountedDeadline(after: 2).isPast))
        #expect(cut.capture.walkCompleted == false)
        #expect(cut.capture.stoppedBy == .deadline)
        #expect(cut.capture.completeness == .partial)
        let alone = try await F.observe(memory, "e0", cut)
        #expect(alone.decision == .none(.incompleteCapture))
        #expect(try await scenes(in: memory) == 0)
        _ = try await F.observe(memory, "e1", F.perceive(tree()))
        let later = try await F.observe(memory, "e2", F.perceive(tree(), limits: .init(isPastDeadline: CountedDeadline(after: 2).isPast)))
        #expect(later.decision == .candidates(["scene-1"]))
        #expect(later.associations.map(\.status) == [.candidate])
        #expect(try await scenes(in: memory) == 1)
        #expect(try await observations(of: "scene-1", in: memory) == 1, "a candidate counts nothing")
        #expect(try await count("SELECT count(*) FROM brain_scene_elements WHERE scene_id = 'scene-1'", in: memory.store) == 3,
                "the control, the collection and its template: a partial capture removes nothing from the scene it did not see whole")
        await memory.store.close()
    }

    @Test("F7: pixels alone, or a window exposing nothing with a role, create no scene")
    func f7Pixels() async throws {
        let memory = try await F.open()
        let pixels = try await F.observe(memory, "e1", F.pixelsOnly(["7", "8", "9", "AC"]))
        #expect(pixels.decision == .none(.incompleteCapture))
        #expect(try await memory.captures.sample(CaptureSampleKey(eventID: "e1", phase: .current))?.elements.isEmpty == true)
        let textOnly = F.perceive(F.window("Calc", [F.staticText("0", y: 200)]))
        #expect(textOnly.capture.completeness == .complete)
        #expect(textOnly.scene.elements.allSatisfy { $0.kind == .text },
                "static text is harvested as text, which is no structure")
        let empty = try await F.observe(memory, "e2", textOnly)
        #expect(empty.decision == .none(.emptySkeleton))
        #expect(try await scenes(in: memory) == 0)
        #expect(try await count("SELECT count(*) FROM memory_event_scenes", in: memory.store) == 0)
        await memory.store.close()
    }

    @Test("F8: two stored scenes with one skeleton make every later capture a candidate of both, and confirm neither")
    func f8TwoScenes() async throws {
        let memory = try await F.open()
        let tree = { F.perceive(F.window("Modal", [F.button("OK", y: 700), F.button("Cancel", y: 700, x: 500)])) }
        _ = try await F.observe(memory, "e1", tree())
        // The second scene is written from a produced sample through the repository's own row writer:
        // the matcher would have confirmed the first, and the comparison is not altered to make two.
        let twin = F.sample("e2", of: tree())
        _ = try await memory.captures.record(F.event("e2"))
        _ = try await memory.captures.record(twin)
        _ = try await memory.store.write { transaction in
            try SQLiteSceneRows.insertScene(
                transaction, sceneID: "scene-twin", appID: 1, sample: twin, skeleton: SceneSkeleton(sample: twin), nowMS: F.t0
            )
        }
        #expect(try await scenes(in: memory) == 2)
        let third = try await F.observe(memory, "e3", tree())
        #expect(third.decision == .candidates(["scene-1", "scene-twin"]))
        #expect(third.associations.map(\.status) == [.candidate, .candidate])
        #expect(try await count("SELECT count(*) FROM memory_event_scenes WHERE match_status = 'confirmed'", in: memory.store) == 1)
        #expect(try await scenes(in: memory) == 2)
        await memory.store.close()
    }

    @Test("F9: buttons titled after people differ in caption: uncertain, a candidate kept, no new scene")
    func f9Captions() async throws {
        let memory = try await F.open()
        _ = try await F.observe(memory, "e1", F.perceive(F.window("Chat", [F.button("Reply to Alice", y: 700)])))
        let bruno = try await F.observe(memory, "e2", F.perceive(F.window("Chat", [F.button("Reply to Bruno", y: 700)])))
        #expect(bruno.decision == .candidates(["scene-1"]))
        #expect(try await scenes(in: memory) == 1)
        #expect(try await count("SELECT count(*) FROM brain_scene_labels WHERE label_token = 'replytoalice'", in: memory.store) == 1,
                "the declared limit: a title that is a name is a caption of the first scene")
        await memory.store.close()
    }

    @Test("F10: a capture with a pop-up open is a union and is never associated; a menu capture is kept and never associated")
    func f10Popup() async throws {
        let memory = try await F.open()
        let union = F.perceive(F.window("Export", [F.button("Format", y: 300), F.button("Export", y: 700)]), popupOpen: true)
        #expect(union.surface == .popupUnion)
        let outcome = try await F.observe(memory, "e1", union)
        #expect(outcome.decision == .none(.popupUnion))
        #expect(try await memory.captures.sample(CaptureSampleKey(eventID: "e1", phase: .current))?.surface == .popupUnion)
        _ = try await memory.captures.record(F.event("e2"))
        _ = try await memory.captures.record(F.sample("e2", phase: .menu, of: F.perceive(F.window("Export", [F.button("Export", y: 700)]))))
        let menu = try await memory.scenes.associate(CaptureSampleKey(eventID: "e2", phase: .menu), at: F.t0)
        #expect(menu.decision == .none(.menuPhase))
        #expect(try await memory.captures.sample(CaptureSampleKey(eventID: "e2", phase: .menu)) != nil)
        #expect(try await scenes(in: memory) == 0)
        await memory.store.close()
    }

    @Test("F11: a field without a title is labeled by its value, which is not a caption: two names, one scene")
    func f11Value() async throws {
        let memory = try await F.open()
        func form(_ name: String) -> PerceivedWindow {
            F.perceive(F.window("Form", [F.textField(value: name, y: 300), F.button("Submit", y: 700)]))
        }
        let mario = form("Mario")
        #expect(mario.scene.elements.first { $0.role == "AXTextField" }?.labelOrigin == .value)
        _ = try await F.observe(memory, "e1", mario)
        let luigi = try await F.observe(memory, "e2", form("Luigi"))
        #expect(luigi.decision == .confirmed(sceneID: "scene-1"))
        #expect(try await count("SELECT count(*) FROM brain_scene_elements WHERE role = 'AXTextField' AND label IS NULL AND label_origin = 'value'", in: memory.store) == 1,
                "the field's origin is kept, its content is not")
        await memory.store.close()
    }

    @Test("F12: groups titled after people give different paths: uncertain, no new scene")
    func f12Paths() async throws {
        let memory = try await F.open()
        func chat(_ name: String) -> PerceivedWindow {
            F.perceive(F.window("Chat", [F.group("Chat with \(name)", y: 200, [F.button("Send", y: 300)])]))
        }
        _ = try await F.observe(memory, "e1", chat("Alice"))
        let bruno = try await F.observe(memory, "e2", chat("Bruno"))
        #expect(bruno.decision == .candidates(["scene-1"]))
        #expect(try await scenes(in: memory) == 1)
        await memory.store.close()
    }

    @Test("F13: a window whose subrole was not read has an unknown surface: candidates only, no new scene")
    func f13Unknown() async throws {
        let memory = try await F.open()
        let unknown = F.perceive(F.window("Panel", subrole: nil, [F.button("Apply", y: 700)]))
        #expect(unknown.surface == .unknown)
        #expect(unknown.capture.completeness == .complete)
        let alone = try await F.observe(memory, "e1", unknown)
        #expect(alone.decision == .none(.surfaceUnknown))
        _ = try await F.observe(memory, "e2", F.perceive(F.window("Panel", [F.button("Apply", y: 700)])))
        let again = try await F.observe(memory, "e3", unknown)
        #expect(again.decision == .candidates(["scene-1"]))
        #expect(try await scenes(in: memory) == 1)
        await memory.store.close()
    }

    @Test("F14: a modal with one button is a different scene from the main window, with no minimum of controls")
    func f14Modal() async throws {
        let memory = try await F.open()
        let main = F.perceive(F.window("QtProbe", [
            F.button("Open modal", y: 300), F.textField(value: "", y: 350, title: "Search"), F.checkbox("Option", on: false, y: 400),
        ]))
        _ = try await F.observe(memory, "e1", main)
        let modal = try await F.observe(memory, "e2", F.perceive(F.dialog("Probe Modal", [F.button("Cancel modal", y: 700)])))
        #expect(modal.decision == .newScene)
        #expect(modal.createdSceneID == "scene-2")
        #expect(try await scenes(in: memory) == 2)
        let kinds = try await memory.store.read { snapshot in
            try snapshot.query("SELECT scene_kind FROM brain_scenes WHERE scene_kind <> 'app' ORDER BY scene_id", []) { try $0.text(0) ?? "" }
        }
        #expect(kinds == ["window", "dialog"])
        await memory.store.close()
    }

    @Test("F15: the skeleton of F1 written to the file and read back after reopening is the produced one, structural key included")
    func f15RoundTrip() async throws {
        let memory = try await F.open()
        let window = inbox(["Alice", "Bruno"])
        let produced = SceneSkeleton(sample: F.sample("e1", of: window))
        _ = try await F.observe(memory, "e1", window)
        await memory.store.close()
        let reopened = try await F.open(at: memory.url)
        let stored = try await reopened.scenes.scenes(of: F.app.bundleID)
        #expect(stored.count == 1)
        #expect(stored.first?.skeleton == produced)
        #expect(stored.first?.structuralKey == produced.structuralKey)
        #expect(stored.first?.surface == .window)
        #expect(stored.first?.observationCount == 1)
        #expect(try await reopened.scenes.scenes(of: "nobody.app").isEmpty)
        await reopened.store.close()
    }

    /// A chat window titled after its conversation: the list of conversations and the open conversation's messages
    /// are collections, the message field and its button the structure that stays.
    private func chat(_ title: String, conversations: [String], messages: [String]) -> PerceivedWindow {
        let thread = FakeNode("AXTable", title: "Messages", frame: CGRect(x: 640, y: 120, width: 440, height: 560))
        for (index, message) in messages.enumerated() {
            thread.adding(FakeNode("AXRow", value: message, frame: CGRect(x: 645, y: 130 + CGFloat(index) * 30, width: 430, height: 26)))
        }
        return F.perceive(F.window(title, [
            F.table("Conversations", rows: conversations, y: 120, withReply: false), thread,
            F.textField(value: "", y: 720, title: "Message"), F.button("Send", y: 720, x: 920),
        ]))
    }

    @Test("two conversations over one chat structure: different conversations, titles and messages are one scene, and the two events, their samples and their traces stay distinct")
    func twoConversationsOverOneStructure() async throws {
        let memory = try await F.open()
        let first  = chat("Alice", conversations: ["Alice", "Bruno", "Carla"], messages: ["Ciao, ci vediamo alle 5?", "Va bene"])
        let second = chat("Bruno", conversations: ["Bruno", "Alice", "Dino", "Carla"], messages: ["Hai letto il resoconto?"])
        #expect(first.scene.elements.filter { $0.collectionPath == "Conversations" }.count == 3, "the rows are read")
        #expect(second.scene.elements.filter { $0.collectionPath == "Messages" }.count == 1)
        #expect(Set(SceneSkeleton(sample: F.sample("x", of: first)).collections) == ["Conversations", "Messages"])
        #expect(SceneSkeleton(sample: F.sample("x", of: first)) == SceneSkeleton(sample: F.sample("y", of: second)),
                "the variable contents leave the skeleton alone")
        var outcomes: [SceneAssociationOutcome] = []
        for (id, trace, window) in [("c1", "conversation-1", first), ("c2", "conversation-2", second)] {
            let event = MemoryEventRecord(eventID: id, source: .cli, streamID: "fixtures", sourceKey: id, traceID: trace,
                                          kind: .observation, app: F.app, occurredAtMS: F.t0 + (id == "c1" ? 0 : 1_000))
            #expect(try await memory.captures.record(event) == .committed)
            #expect(try await memory.captures.record(F.sample(id, of: window)) == .committed)
            outcomes.append(try await memory.scenes.associate(CaptureSampleKey(eventID: id, phase: .current), at: event.occurredAtMS))
        }
        #expect(outcomes[0].decision == .newScene)
        #expect(outcomes[1].decision == .confirmed(sceneID: "scene-1"))
        #expect(try await scenes(in: memory) == 1)
        #expect(try await observations(of: "scene-1", in: memory) == 2)
        #expect(try await count("""
            SELECT count(*) FROM brain_scene_elements
            WHERE label LIKE '%Alice%' OR label LIKE '%Bruno%' OR label LIKE '%resoconto%' OR element_key LIKE '%Alice%' OR element_key LIKE '%Ciao%'
            """, in: memory.store) == 0, "no conversation and no message in the structure")
        #expect(try await count("SELECT count(*) FROM memory_events", in: memory.store) == 2)
        #expect(try await count("SELECT count(*) FROM memory_event_observations WHERE observation_kind = 'capture'", in: memory.store) == 2)
        let traces = try await SQLiteTraceRepository(store: memory.store).traces(before: nil, limit: 10)
        #expect(traces.map(\.traceID) == ["conversation-2", "conversation-1"])
        #expect(traces.allSatisfy { $0.events == 1 })
        await memory.store.close()
    }

    @Test("the role set and the caption labels of a scene are projections of its skeleton, written once when the scene is created: equal to what the elements rebuild, presence only, nothing from inside a collection")
    func derivedRolesAndLabels() async throws {
        let memory = try await F.open()
        let window = F.perceive(F.window("Inbox", [
            F.table("People", rows: ["Alice", "Bruno"]), F.button("Compose", y: 700), F.checkbox("Flagged", on: true, y: 650),
            F.textField(value: "Ciao", y: 600, title: "Subject"), F.staticText("Unread: 3", y: 560),
            F.group("Filters", y: 400, [F.button("Today", y: 420)]),
        ]))
        let first = try await F.observe(memory, "e1", window)
        let scene = try #require(first.createdSceneID)
        _ = try await F.observe(memory, "e2", F.perceive(F.window("Inbox", [
            F.table("People", rows: ["Carla"]), F.button("Compose", y: 700), F.checkbox("Flagged", on: false, y: 650),
            F.textField(value: "Altro", y: 600, title: "Subject"), F.staticText("Unread: 9", y: 560),
            F.group("Filters", y: 400, [F.button("Today", y: 420)]),
        ])), at: F.t0 + 1)
        #expect(try await observations(of: scene, in: memory) == 2, "the second capture is the same scene")
        await memory.store.close()
        let reopened = try await F.open(at: memory.url)
        let skeleton = try #require(try await reopened.scenes.scenes(of: F.app.bundleID).first { $0.id == scene }).skeleton
        let roles = try await reopened.store.read { try $0.query("SELECT role FROM brain_scene_roles WHERE scene_id = ? ORDER BY role", [.text(scene)]) { try $0.text(0) ?? "" } }
        let labels = try await reopened.store.read { try $0.query("SELECT label_token FROM brain_scene_labels WHERE scene_id = ? ORDER BY label_token", [.text(scene)]) { try $0.text(0) ?? "" } }
        #expect(roles.count > 2 && !labels.isEmpty, "the fixture has something to compare")
        #expect(roles.map { Array($0.utf8) } == skeleton.roles.sorted().map { Array($0.utf8) }, "the role set is the skeleton's, byte for byte")
        #expect(labels.map { Array($0.utf8) } == Set(skeleton.captions.map(\.label)).filter { !$0.isEmpty }.sorted().map { Array($0.utf8) },
                "the labels are the skeleton's captions, byte for byte")
        #expect(!labels.contains("Alice") && !labels.contains("Carla") && !labels.contains("Ciao"), "rows and values are content, not captions")
        #expect(try await count("SELECT count(*) FROM brain_scene_roles WHERE count_bucket IS NOT NULL", in: reopened.store) == 0, "presence only")
        await reopened.store.close()
    }

    // MARK: Acceptance beyond the fixtures

    @Test("associating the same sample again answers the stored decision and moves no count; an unknown sample or an event without app is refused")
    func idempotentAssociation() async throws {
        let memory = try await F.open()
        let window = inbox(["Alice"])
        let first = try await F.observe(memory, "e1", window)
        let again = try await memory.scenes.associate(CaptureSampleKey(eventID: "e1", phase: .current), at: F.t0 + 5)
        #expect(again.receipt == .alreadyApplied)
        #expect(first.decision == .newScene)
        #expect(again.decision == .confirmed(sceneID: "scene-1"), "a stored decision reads back as its rows: the creation is not re-reported")
        #expect(again.associations == first.associations)
        #expect(try await observations(of: "scene-1", in: memory) == 1)
        #expect(try await count("SELECT count(*) FROM memory_event_scenes", in: memory.store) == 1)
        await #expect(throws: ObservationContractError.missingSample(CaptureSampleKey(eventID: "e1", phase: .after))) {
            _ = try await memory.scenes.associate(CaptureSampleKey(eventID: "e1", phase: .after), at: F.t0)
        }
        _ = try await memory.captures.record(F.event("noapp", app: nil))
        _ = try await memory.captures.record(F.sample("noapp", of: window))
        await #expect(throws: ObservationContractError.eventWithoutApp(eventID: "noapp")) {
            _ = try await memory.scenes.associate(CaptureSampleKey(eventID: "noapp", phase: .current), at: F.t0)
        }
        #expect(try await scenes(in: memory) == 1)
        await memory.store.close()
    }

    @Test("the app scope row is never a candidate and never confirmed, whatever the capture")
    func appScope() async throws {
        let memory = try await F.open()
        _ = try await memory.captures.record(F.event("seed"))
        _ = try await memory.store.write { transaction in
            try transaction.execute(
                """
                INSERT INTO brain_scenes (scene_id, app_id, title_bucket, scene_kind, first_seen_ms, last_seen_ms, observation_count)
                VALUES ('app-scope', 1, '#app', 'app', 0, 0, 0)
                """
            )
        }
        let empty = try await F.observe(memory, "e1", F.perceive(F.window("Calc", [F.staticText("0", y: 200)])))
        #expect(empty.decision == .none(.emptySkeleton))
        let full = try await F.observe(memory, "e2", inbox(["Alice"]))
        #expect(full.decision == .newScene)
        #expect(try await memory.scenes.scenes(of: F.app.bundleID).map(\.id) == ["scene-1"])
        #expect(try await count("SELECT count(*) FROM memory_event_scenes WHERE scene_id = 'app-scope'", in: memory.store) == 0)
        #expect(try await count("SELECT observation_count FROM brain_scenes WHERE scene_id = 'app-scope'", in: memory.store) == 0)
        await memory.store.close()
    }

    @Test("two stores on one file associating two complete captures of one skeleton at once create one scene, with no unique key on the digest")
    func concurrentWriters() async throws {
        let ids = SceneIDs()
        let one = try await F.open(ids: ids)
        let two = try await F.open(at: one.url, ids: ids)
        let window = inbox(["Alice"])
        _ = try await one.captures.record(F.event("e1"))
        _ = try await one.captures.record(F.sample("e1", of: window))
        _ = try await two.captures.record(F.event("e2"))
        _ = try await two.captures.record(F.sample("e2", of: window))
        async let first  = one.scenes.associate(CaptureSampleKey(eventID: "e1", phase: .current), at: F.t0)
        async let second = two.scenes.associate(CaptureSampleKey(eventID: "e2", phase: .current), at: F.t0)
        let outcomes = try await [first, second]
        #expect(outcomes.filter { $0.decision == .newScene }.count == 1)
        #expect(outcomes.filter { if case .confirmed = $0.decision { return true } else { return false } }.count == 1)
        #expect(try await scenes(in: one) == 1)
        #expect(try await count("SELECT count(*) FROM memory_event_scenes WHERE match_status = 'confirmed'", in: two.store) == 2)
        let unique = try await one.store.read { snapshot in
            try snapshot.query("SELECT sql FROM sqlite_schema WHERE type = 'index' AND tbl_name = 'brain_scenes'", []) { try $0.text(0) ?? "" }
        }
        #expect(!unique.contains { $0.contains("structural_key") })
        await one.store.close()
        await two.store.close()
    }

    @Test("a confirmed association from an incomplete sample is refused by the file itself, not only by the matcher")
    func confirmationNeedsCompleteness() async throws {
        let memory = try await F.open()
        _ = try await F.observe(memory, "e1", inbox(["Alice"]))
        let partial = F.perceive(F.window("Inbox", [F.button("Compose", y: 700)]),
                                 limits: .init(isPastDeadline: CountedDeadline(after: 1).isPast))
        _ = try await memory.captures.record(F.event("e2"))
        _ = try await memory.captures.record(F.sample("e2", of: partial))
        let refused = await refusal(
            of: """
                INSERT INTO memory_event_scenes (event_id, app_id, phase, sample_ordinal, scene_id, match_status, matched_by, matcher_version)
                VALUES ('e2', 1, 'current', 0, 'scene-1', 'confirmed', 'structure', 'v3')
                """,
            in: memory.store
        )
        #expect(refused?.message.contains("only a complete capture can confirm") == true)
        await memory.store.close()
    }
}
