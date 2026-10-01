//
//  SQLiteLivingMemoryStoreTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import EngineCore
import Foundation
import Memory
import PerceptionCore
@testable import SQLiteLivingMemory
import SQLite3
import Testing

/// Every test uses its own temporary directory and invented records; no real application data.
@Suite("The SQLite living memory store", .serialized)
struct SQLiteLivingMemoryStoreTests {

    private let routing = WindowContext(bundleID: "test.synthetic.mixer", windowTitle: "Synthetic Routing")!
    private let mixer = WindowContext(bundleID: "test.synthetic.mixer", windowTitle: "Synthetic Mix")!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Fixtures

    private func withDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mecum-living-memory-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    private func observation(_ context: WindowContext, _ anchor: String, block: Int = 1) -> SightingObservation {
        SightingObservation(key: SightingKey(context: context, identity: .anchor(anchor)), name: "All Busses",
                            nameSource: .observed, seenAt: t0, observationBlock: block)
    }

    private func evidence(_ readback: DropdownReadback = .window("Output Busses")) -> DropdownEvidence {
        DropdownEvidence(bundleID: "test.synthetic.mixer", windowTitle: "Synthetic Routing", control: "All Busses",
                         controlRole: "AXPopUpButton", section: nil, valueBefore: "All Busses",
                         requestedItem: "Output Busses", readback: readback, menuClosedByChoice: true)
    }

    private var draft: ExperienceDraft {
        ExperienceDraft(phrase: "imposta le uscite su Output Busses", step: ExperienceStep(evidence()),
                        context: routing)!
    }

    private func verified(_ id: String, at seconds: TimeInterval = 0) -> ExperienceEvent {
        ExperienceEvent(id: id, subject: .step(draft), outcome: .verified(.dropdown(evidence())),
                        at: t0.addingTimeInterval(seconds))
    }

    private func sequentialIDs() -> @Sendable () -> ExperienceID {
        { ExperienceID("experience-\(UUID().uuidString)") }
    }

    // MARK: Tests

    @Test("two sightings and an experience are read back by a new instance")
    func rereadByNewInstance() async throws {
        try await withDirectory { directory in
            let file = SQLiteLivingMemoryStore.file(inKnowledgeDirectory: directory)
            var id: ExperienceID?
            do {
                let store = try SQLiteLivingMemoryStore(file: file)
                _ = try await store.recordSightings([observation(routing, "anchor-1"), observation(mixer, "anchor-2")])
                id = try await store.record(verified("e1")).experience?.id
            }
            let reopened = try SQLiteLivingMemoryStore(file: file)
            let sightings = try await reopened.sightings(in: ["test.synthetic.mixer"])
            #expect(sightings.map(\.key.context.windowFamily) == ["syntheticmix", "syntheticrouting"])
            let experiences = try await reopened.experiences(in: ["test.synthetic.mixer"])
            #expect(experiences.count == 1)
            #expect(experiences.first?.id == id)
            #expect(experiences.first?.phrase == "imposta le uscite su Output Busses")
            #expect(experiences.first?.latestProof == .dropdown(evidence()))
            #expect(try await reopened.candidates(for: "uscite", in: nil).count == 1)
        }
    }

    @Test("a new file is created at the current schema, and an older one is migrated in place")
    func creationAndMigration() async throws {
        try await withDirectory { directory in
            let file = SQLiteLivingMemoryStore.file(inKnowledgeDirectory: directory)
            do {
                let store = try SQLiteLivingMemoryStore(file: file)
                _ = try await store.recordSightings([observation(routing, "anchor-1")])
            }
            #expect(try RawDatabase(file).integer("PRAGMA user_version") == 2)
            #expect(try RawDatabase(file).integer("PRAGMA application_id") == SQLiteLivingMemorySchema.applicationID)
            #expect(try RawDatabase(file).text("PRAGMA journal_mode") == "wal")

            let next = SQLiteLivingMemorySchema(migrations: SQLiteLivingMemorySchema.current.migrations + [
                .init(version: 3, statements: "CREATE TABLE synthetic_notes (note TEXT NOT NULL);"),
            ])
            do {
                let migrated = try SQLiteLivingMemoryStore(file: file, access: .readWrite, makeID: sequentialIDs(),
                                                           schema: next)
                #expect(try await migrated.sightings(in: ["test.synthetic.mixer"]).count == 1)
            }
            #expect(try RawDatabase(file).integer("PRAGMA user_version") == 3)
            #expect(try RawDatabase(file).integer("SELECT count(*) FROM synthetic_notes") == 0)
        }
    }

    @Test("an unknown schema, a foreign database and a non-database are refused and left untouched")
    func unknownSchemaRefused() async throws {
        try await withDirectory { directory in
            let file = SQLiteLivingMemoryStore.file(inKnowledgeDirectory: directory)
            do { _ = try SQLiteLivingMemoryStore(file: file) }
            try RawDatabase(file).execute("PRAGMA user_version = 99")
            let before = try Data(contentsOf: file)
            let unsupported = SQLiteLivingMemoryError.unsupportedSchemaVersion(path: file.path, found: 99, supported: 2)
            #expect(throws: unsupported) {
                _ = try SQLiteLivingMemoryStore(file: file)
            }
            #expect(try Data(contentsOf: file) == before)

            let foreign = directory.appendingPathComponent("foreign.sqlite")
            try RawDatabase(foreign).execute("CREATE TABLE other (value TEXT)")
            #expect(throws: SQLiteLivingMemoryError.notALivingMemoryStore(path: foreign.path)) {
                _ = try SQLiteLivingMemoryStore(file: foreign)
            }

            let garbage = directory.appendingPathComponent("garbage.sqlite")
            let bytes = Data(repeating: 0x5A, count: 4096)
            try bytes.write(to: garbage)
            #expect {
                _ = try SQLiteLivingMemoryStore(file: garbage)
            } throws: { error in
                if case SQLiteLivingMemoryError.unreadable = error { true } else { false }
            }
            #expect(try Data(contentsOf: garbage) == bytes)
        }
    }

    @Test("an operation that fails part-way is rolled back entirely")
    func incompleteOperationRolledBack() async throws {
        try await withDirectory { directory in
            let file = SQLiteLivingMemoryStore.file(inKnowledgeDirectory: directory)
            let store = try SQLiteLivingMemoryStore(file: file)
            let learned = try await store.record(verified("e1"))
            try RawDatabase(file).execute("""
                CREATE TRIGGER synthetic_sighting_failure BEFORE INSERT ON sightings
                WHEN NEW.identity_key = 'anchor:poison' BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END;
                CREATE TRIGGER synthetic_event_failure BEFORE INSERT ON experience_events
                WHEN NEW.event_id = 'poison' BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END;
                """)
            await #expect(throws: SQLiteLivingMemoryError.self) {
                _ = try await store.recordSightings([observation(routing, "anchor-1"), observation(routing, "poison")])
            }
            #expect(try await store.sightings(in: ["test.synthetic.mixer"]).isEmpty)
            await #expect(throws: SQLiteLivingMemoryError.self) { _ = try await store.record(verified("poison")) }
            let id = try #require(learned.experience?.id)
            #expect(try await store.experiences(in: ["test.synthetic.mixer"]).first?.successCount == 1)
            #expect(try await store.history(of: id).map(\.event.id) == ["e1"])
        }
    }

    @Test("a correction keeps the successes and the whole history on disk")
    func correctionWithHistory() async throws {
        try await withDirectory { directory in
            let file = SQLiteLivingMemoryStore.file(inKnowledgeDirectory: directory)
            let id: ExperienceID
            do {
                let store = try SQLiteLivingMemoryStore(file: file)
                _ = try await store.record(verified("e1"))
                id = try #require(try await store.record(verified("e2", at: 60)).experience?.id)
                _ = try await store.record(ExperienceEvent(id: "e3", subject: .experience(id),
                                                           outcome: .contradicted(.userCorrection),
                                                           at: t0.addingTimeInterval(120)))
                _ = try await store.record(ExperienceEvent(id: "e4", subject: .step(draft),
                                                           outcome: .uncertain(.readbackUnavailable(.nothingAtControl)),
                                                           at: t0.addingTimeInterval(180)))
            }
            let reopened = try SQLiteLivingMemoryStore(file: file)
            let record = try #require(try await reopened.experiences(in: ["test.synthetic.mixer"]).first)
            #expect(record.successCount == 2)
            #expect(record.failureCount == 1)
            #expect(record.lastVerifiedAt == t0.addingTimeInterval(60))
            #expect(try await reopened.history(of: id).map(\.event.id) == ["e1", "e2", "e3", "e4"])
        }
    }

    @Test("two connections to one file serialize their writes and lose nothing")
    func twoConnections() async throws {
        try await withDirectory { directory in
            let file = SQLiteLivingMemoryStore.file(inKnowledgeDirectory: directory)
            let first = try SQLiteLivingMemoryStore(file: file)
            let second = try SQLiteLivingMemoryStore(file: file)
            let sighting = observation(routing, "anchor-1")
            let draft = self.draft
            let proof = evidence()
            let t0 = self.t0
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (name, store) in [("first", first), ("second", second)] {
                    group.addTask {
                        for index in 0..<10 {
                            _ = try await store.recordSightings([sighting])
                            _ = try await store.record(ExperienceEvent(
                                id: "\(name)-\(index)", subject: .step(draft), outcome: .verified(.dropdown(proof)),
                                at: t0.addingTimeInterval(Double(index))
                            ))
                        }
                    }
                }
                try await group.waitForAll()
            }
            #expect(try await first.sightings(in: ["test.synthetic.mixer"]).first?.readCount == 20)
            let experiences = try await second.experiences(in: ["test.synthetic.mixer"])
            #expect(experiences.count == 1)
            #expect(experiences.first?.successCount == 20)
            let shared = verified("shared")
            #expect(try await first.record(shared).experience?.successCount == 21)
            let current = try await second.experiences(in: ["test.synthetic.mixer"]).first
            #expect(try await second.record(shared) == .duplicate(current))
            #expect(try await second.history(of: try #require(experiences.first?.id)).count == 21)
        }
    }

    @Test("a repeated write is applied once, even with a date finer than the stored milliseconds")
    func idempotency() async throws {
        try await withDirectory { directory in
            let store = try SQLiteLivingMemoryStore(file: SQLiteLivingMemoryStore.file(inKnowledgeDirectory: directory))
            let fine = verified("e1", at: 0.123_456)
            let first = try await store.record(fine)
            let again = try await store.record(fine)
            #expect(again == .duplicate(first.experience))
            #expect(again.experience?.successCount == 1)
            await #expect(throws: LivingMemoryError.conflictingEvent(id: "e1")) {
                _ = try await store.record(ExperienceEvent(id: "e1", subject: .step(draft),
                                                           outcome: .contradicted(.userCorrection), at: t0))
            }
            let id = try #require(first.experience?.id)
            let decision = RecallDecisionRecord(id: "d1", at: t0.addingTimeInterval(0.5), phrase: "imposta le uscite",
                                                context: routing, experienceID: id, verdict: .suggested,
                                                reason: "same window, control present in the fresh scene")
            try await store.record(decision)
            try await store.record(decision)
            #expect(try await store.decisions(about: id).count == 1)
        }
    }

    @Test("a read-only store never creates, migrates or writes")
    func readOnlyWritesNothing() async throws {
        try await withDirectory { directory in
            let file = SQLiteLivingMemoryStore.file(inKnowledgeDirectory: directory)
            #expect(throws: SQLiteLivingMemoryError.missingStore(path: file.path)) {
                _ = try SQLiteLivingMemoryStore(file: file, access: .readOnly)
            }
            #expect(!FileManager.default.fileExists(atPath: directory.path))
            do {
                let writer = try SQLiteLivingMemoryStore(file: file)
                _ = try await writer.recordSightings([observation(routing, "anchor-1")])
                _ = try await writer.record(verified("e1"))
            }
            let before = try Data(contentsOf: file)
            let reader = try SQLiteLivingMemoryStore(file: file, access: .readOnly)
            #expect(try await reader.sightings(in: ["test.synthetic.mixer"]).count == 1)
            #expect(try await reader.experiences(in: ["test.synthetic.mixer"]).count == 1)
            await #expect(throws: SQLiteLivingMemoryError.readOnly(path: file.path)) {
                _ = try await reader.recordSightings([observation(routing, "anchor-2")])
            }
            #expect(try Data(contentsOf: file) == before)

            try RawDatabase(file).execute("PRAGMA user_version = 0")
            #expect(throws: SQLiteLivingMemoryError.needsMigration(path: file.path, found: 0, current: 2)) {
                _ = try SQLiteLivingMemoryStore(file: file, access: .readOnly)
            }
            #expect(try RawDatabase(file).integer("PRAGMA user_version") == 0)
        }
    }

    // MARK: Toggles and the version 1 record shape

    /// Rows exactly as the 492264c build (schema 1, selections only) wrote them for an invented
    /// experience, a no-op and an uncertain attempt, copied from a store that build created.
    private enum Legacy {
        static let experienceID = "legacy-experience-1"
        static let naturalKey = "test.synthetic.mixer\nsyntheticiosetup\nbus busses della filtro output scheda seleziona\n"
            + "select|allbusses|outputbusses"
        static let record = #"{"createdAt":"2027-01-15T08:00:00.000Z","draft":{"context":{"bundleID":"test.synthetic.mixer","windowFamily":"syntheticiosetup"},"phrase":"Seleziona Output Busses nel filtro della scheda Bus","step":{"control":"All Busses","item":"Output Busses","tool":"select"}},"failureCount":0,"id":{"rawValue":"legacy-experience-1"},"lastVerifiedAt":"2027-01-15T08:00:00.000Z","latestProof":{"bundleID":"test.synthetic.mixer","control":"All Busses","controlRole":"AXPopUpButton","menuClosedByChoice":true,"readback":{"window":{"_0":"Output Busses"}},"requestedItem":"Output Busses","valueBefore":"All Busses","windowTitle":"Synthetic I\/O Setup"},"successCount":1}"#
        static let entries: [(id: String, experience: String?, entry: String)] = [
            ("turn-legacy-1", experienceID, #"{"event":{"at":"2027-01-15T08:00:00.000Z","id":"turn-legacy-1","outcome":{"verified":{"_0":{"bundleID":"test.synthetic.mixer","control":"All Busses","controlRole":"AXPopUpButton","menuClosedByChoice":true,"readback":{"window":{"_0":"Output Busses"}},"requestedItem":"Output Busses","valueBefore":"All Busses","windowTitle":"Synthetic I\/O Setup"}}},"subject":{"step":{"_0":{"context":{"bundleID":"test.synthetic.mixer","windowFamily":"syntheticiosetup"},"phrase":"Seleziona Output Busses nel filtro della scheda Bus","step":{"control":"All Busses","item":"Output Busses","tool":"select"}}}}},"experienceID":{"rawValue":"legacy-experience-1"}}"#),
            ("turn-legacy-2", nil, #"{"event":{"at":"2027-01-15T08:01:00.000Z","id":"turn-legacy-2","outcome":{"noChange":{"_0":{"bundleID":"test.synthetic.mixer","control":"Output Busses","controlRole":"AXPopUpButton","menuClosedByChoice":true,"readback":{"window":{"_0":"Output Busses"}},"requestedItem":"Output Busses","valueBefore":"Output Busses","windowTitle":"Synthetic I\/O Setup"}}},"subject":{"unattributed":{"_0":{"bundleID":"test.synthetic.mixer","windowFamily":"syntheticiosetup"}}}}}"#),
            ("turn-legacy-3", nil, #"{"event":{"at":"2027-01-15T08:02:00.000Z","id":"turn-legacy-3","outcome":{"uncertain":{"_0":{"readbackUnavailable":{"_0":"severalAtControl"}}}},"subject":{"unattributed":{"_0":{"bundleID":"test.synthetic.mixer","windowFamily":"syntheticiosetup"}}}}}"#),
        ]

        static let schema = SQLiteLivingMemorySchema(migrations: [SQLiteLivingMemorySchema.current.migrations[0]])

        static var evidence: DropdownEvidence {
            DropdownEvidence(bundleID: "test.synthetic.mixer", windowTitle: "Synthetic I/O Setup", control: "All Busses",
                             controlRole: "AXPopUpButton", section: nil, valueBefore: "All Busses",
                             requestedItem: "Output Busses", readback: .window("Output Busses"),
                             menuClosedByChoice: true)
        }

        /// A version 1 store holding the rows above, arranged behind the store's back.
        static func write(to file: URL) throws {
            _ = try SQLiteLivingMemoryStore(file: file, access: .readWrite, makeID: { ExperienceID("unused") },
                                            schema: schema)
            let raw = try RawDatabase(file)
            try raw.insert("INSERT INTO experiences (id, natural_key, bundle_id, record) VALUES (?, ?, ?, ?)",
                           [experienceID, naturalKey, "test.synthetic.mixer", record])
            for row in entries {
                try raw.insert("INSERT INTO experience_events (event_id, experience_id, entry) VALUES (?, ?, ?)",
                               [row.id, row.experience, row.entry])
            }
        }
    }

    @Test("a version 1 store is migrated to 2 without rewriting a row, and its selections read as before")
    func legacyRowsAfterMigration() async throws {
        try await withDirectory { directory in
            let file = SQLiteLivingMemoryStore.file(inKnowledgeDirectory: directory)
            try Legacy.write(to: file)
            #expect(try RawDatabase(file).integer("PRAGMA user_version") == 1)
            let store = try SQLiteLivingMemoryStore(file: file)
            #expect(try RawDatabase(file).integer("PRAGMA user_version") == 2)
            #expect(try RawDatabase(file).text("SELECT record FROM experiences") == Legacy.record)
            #expect(try RawDatabase(file).text("SELECT entry FROM experience_events WHERE event_id = 'turn-legacy-3'")
                    == Legacy.entries[2].entry)

            let record = try #require(try await store.experiences(in: ["test.synthetic.mixer"]).first)
            #expect(record.id == ExperienceID(Legacy.experienceID))
            #expect(record.step == .select(control: "All Busses", item: "Output Busses"))
            #expect(record.latestProof == .dropdown(Legacy.evidence))
            #expect(record.successCount == 1)
            #expect(try await store.history(of: record.id).map(\.event.id) == ["turn-legacy-1"])
            #expect(try await store.candidates(for: "Seleziona Output Busses", in: nil).map(\.id) == [record.id])

            let encoder = KnowledgeCoding.makeEncoder()
            encoder.outputFormatting = [.sortedKeys]
            #expect(String(decoding: try encoder.encode(record), as: UTF8.self) == Legacy.record,
                    "a select is still written in the version 1 shape")
            let again = ExperienceEvent(id: "turn-legacy-1", subject: .step(record.draft),
                                        outcome: .verified(.dropdown(Legacy.evidence)),
                                        at: try #require(record.lastVerifiedAt))
            #expect(try await store.record(again) == .duplicate(record), "a legacy event is still the same event")
            let next = ExperienceEvent(id: "turn-new-1", subject: .step(record.draft),
                                       outcome: .verified(.dropdown(Legacy.evidence)), at: t0)
            let strengthened = try #require(try await store.record(next).experience)
            #expect(strengthened.id == record.id && strengthened.successCount == 2,
                    "a new verification finds the legacy experience by its natural key")
        }
    }

    @Test("a read-only open reads a version 1 store as it is and leaves it at version 1")
    func legacyReadOnly() async throws {
        try await withDirectory { directory in
            let file = SQLiteLivingMemoryStore.file(inKnowledgeDirectory: directory)
            try Legacy.write(to: file)
            let before = try Data(contentsOf: file)
            let reader = try SQLiteLivingMemoryStore(file: file, access: .readOnly)
            let record = try #require(try await reader.experiences(in: ["test.synthetic.mixer"]).first)
            #expect(record.step == .select(control: "All Busses", item: "Output Busses"))
            #expect(record.latestProof == .dropdown(Legacy.evidence))
            #expect(try await reader.history(of: record.id).map(\.event.id) == ["turn-legacy-1"])
            #expect(try RawDatabase(file).integer("PRAGMA user_version") == 1)
            #expect(try Data(contentsOf: file) == before)
            #expect(SQLiteLivingMemorySchema.current.oldestReadableVersion == 1)
        }
    }

    @Test("a migration that changes a table ends what a read-only open accepts without migrating")
    func readableVersionsStopAtATableChange() async throws {
        try await withDirectory { directory in
            let file = SQLiteLivingMemoryStore.file(inKnowledgeDirectory: directory)
            try Legacy.write(to: file)
            let later = SQLiteLivingMemorySchema(migrations: SQLiteLivingMemorySchema.current.migrations + [
                .init(version: 3, statements: "CREATE TABLE synthetic_notes (note TEXT NOT NULL);"),
            ])
            #expect(later.oldestReadableVersion == 3)
            #expect(throws: SQLiteLivingMemoryError.needsMigration(path: file.path, found: 1, current: 3)) {
                _ = try SQLiteLivingMemoryStore(file: file, access: .readOnly, makeID: { ExperienceID("unused") },
                                                schema: later)
            }
            #expect(try RawDatabase(file).integer("PRAGMA user_version") == 1)
        }
    }

    @Test("a toggle experience survives a new instance, and a version 1 build refuses the file cleanly")
    func toggleRecordAndOlderBuild() async throws {
        try await withDirectory { directory in
            let file = SQLiteLivingMemoryStore.file(inKnowledgeDirectory: directory)
            try Legacy.write(to: file)
            let mixer = WindowContext(bundleID: "test.synthetic.mixer", windowTitle: "Synthetic Mixer")!
            let proof = ToggleEvidence(bundleID: "test.synthetic.mixer", windowTitle: "Synthetic Mixer", control: "Mute",
                                       controlRole: "AXCheckBox", section: nil, desiredState: .on,
                                       stateBefore: .read(.off, .resolvedElement), click: .sent,
                                       stateAfter: .read(.on, .sameElement))
            let draft = ExperienceDraft(phrase: "Attiva Mute", step: ExperienceStep(proof, requestedSection: nil),
                                        context: mixer)!
            do {
                let store = try SQLiteLivingMemoryStore(file: file, makeID: { ExperienceID("toggle-1") })
                _ = try await store.record(ExperienceEvent(id: "turn-toggle-1", subject: .step(draft),
                                                           outcome: .verified(.toggle(proof)), at: t0))
                _ = try await store.record(ExperienceEvent(id: "turn-toggle-2", subject: .unattributed(mixer),
                                                           outcome: .uncertain(.toggleStateUnreadable(.severalMatches)),
                                                           at: t0 + 60))
            }
            let reopened = try SQLiteLivingMemoryStore(file: file, access: .readOnly)
            let records = try await reopened.experiences(in: ["test.synthetic.mixer"])
            #expect(records.map(\.step) == [.select(control: "All Busses", item: "Output Busses"),
                                            .setToggle(control: "Mute", section: nil, state: .on)])
            #expect(records.last?.latestProof == .toggle(proof))
            #expect(try await reopened.history(of: ExperienceID("toggle-1")).map(\.event.outcome)
                    == [.verified(.toggle(proof))])
            #expect(try await reopened.candidates(for: "Attiva Mute", in: nil).map(\.id) == [ExperienceID("toggle-1")])
            let stored = try RawDatabase(file).text("SELECT record FROM experiences WHERE id = 'toggle-1'")
            #expect(stored.contains(#""step":{"control":"Mute","state":"on","tool":"set_toggle"}"#))
            #expect(stored.contains(#""latestProof":{"toggle":{"#))

            let older = SQLiteLivingMemoryError.unsupportedSchemaVersion(path: file.path, found: 2, supported: 1)
            #expect(throws: older) {
                _ = try SQLiteLivingMemoryStore(file: file, access: .readWrite, makeID: { ExperienceID("unused") },
                                                schema: Legacy.schema)
            }
        }
    }

    @Test("a click experience survives a new instance beside a legacy select, and one turn counts once")
    func clickRecordAfterReopen() async throws {
        try await withDirectory { directory in
            let file = SQLiteLivingMemoryStore.file(inKnowledgeDirectory: directory)
            try Legacy.write(to: file)
            let mixer = WindowContext(bundleID: "test.synthetic.mixer", windowTitle: "Synthetic Mixer")!
            let proof = ClickEvidence(bundleID: "test.synthetic.mixer", windowTitle: "Synthetic Mixer",
                                      target: "Track 1", targetRole: nil, section: "Mixer", gesture: .rightClick,
                                      delivery: .sent,
                                      effect: .menuOpened(items: ["Delete Track", "Rename"]))
            let step = try #require(ExperienceStep(proof, requestedSection: "Mixer"))
            let draft = ExperienceDraft(phrase: "Fai clic destro su Track 1 nel Mixer", step: step, context: mixer)!
            let event = ExperienceEvent(id: "turn-click-1", subject: .step(draft), outcome: .verified(.click(proof)),
                                        at: t0)
            do {
                let store = try SQLiteLivingMemoryStore(file: file, makeID: { ExperienceID("click-1") })
                _ = try await store.record(event)
                _ = try await store.record(ExperienceEvent(id: "turn-click-2", subject: .unattributed(mixer),
                                                           outcome: .uncertain(.clickEffectUnattributed(.noChange)),
                                                           at: t0 + 60))
            }
            do {
                let again = try SQLiteLivingMemoryStore(file: file, makeID: { ExperienceID("unused") })
                guard case .duplicate(let record?) = try await again.record(event) else {
                    Issue.record("a repeated turn was recorded again"); return
                }
                #expect(record.successCount == 1)
            }
            let reopened = try SQLiteLivingMemoryStore(file: file, access: .readOnly)
            let records = try await reopened.experiences(in: ["test.synthetic.mixer"])
            #expect(Set(records.map(\.step)) == [
                .select(control: "All Busses", item: "Output Busses"),
                .click(.rightClick, target: "Track 1", section: "Mixer", opens: .menu),
            ])
            let click = try #require(records.first { $0.id == ExperienceID("click-1") })
            #expect(click.successCount == 1 && click.latestProof == .click(proof))
            #expect(try await reopened.history(of: ExperienceID("click-1")).map(\.event.outcome)
                    == [.verified(.click(proof))])
            let stored = try RawDatabase(file).text("SELECT record FROM experiences WHERE id = 'click-1'")
            #expect(stored.contains(#""tool":"right_click""#) && stored.contains(#""latestProof":{"click":{"#))
            let select = try RawDatabase(file).text("SELECT record FROM experiences WHERE id != 'click-1'")
            #expect(select.contains(#""step":{"control":"All Busses","item":"Output Busses","tool":"select"}"#),
                    "a select is still stored in its version 1 shape")
        }
    }

    @Test("the reasons added for unattributable proofs are stored as their names, beside a legacy select")
    func newReasonsOnDisk() async throws {
        try await withDirectory { directory in
            let file = SQLiteLivingMemoryStore.file(inKnowledgeDirectory: directory)
            try Legacy.write(to: file)
            let mixer = WindowContext(bundleID: "test.synthetic.mixer", windowTitle: "Synthetic Mixer")!
            let outcomes: [(String, ExperienceEvent.Outcome, String)] = [
                ("turn-r1-1", .uncertain(.clickEffectUnattributed(.originNotListed)),
                 #""uncertain":{"_0":{"clickEffectUnattributed":{"_0":"originNotListed"}}}"#),
                ("turn-r1-2", .uncertain(.clickEffectUnattributed(.originRecreated)),
                 #""uncertain":{"_0":{"clickEffectUnattributed":{"_0":"originRecreated"}}}"#),
                ("turn-r1-3", .uncertain(.clickEffectUnattributed(.menuNotCaptured)),
                 #""uncertain":{"_0":{"clickEffectUnattributed":{"_0":"menuNotCaptured"}}}"#),
                ("turn-r1-4", .uncertain(.clickEffectUnattributed(.outcomeUnverified)),
                 #""uncertain":{"_0":{"clickEffectUnattributed":{"_0":"outcomeUnverified"}}}"#),
                ("turn-r1-5", .uncertain(.toggleStateUnreadable(.notAtPlace)),
                 #""uncertain":{"_0":{"toggleStateUnreadable":{"_0":"notAtPlace"}}}"#),
                ("turn-r1-6", .uncertain(.outcomeNotVerified), #""uncertain":{"_0":{"outcomeNotVerified":{}}}"#),
            ]
            do {
                let store = try SQLiteLivingMemoryStore(file: file, makeID: { ExperienceID("unused") })
                for (id, outcome, _) in outcomes {
                    _ = try await store.record(ExperienceEvent(id: id, subject: .unattributed(mixer), outcome: outcome,
                                                               at: t0))
                }
            }
            for (id, outcome, shape) in outcomes {
                let entry = try RawDatabase(file).text("SELECT entry FROM experience_events WHERE event_id = '\(id)'")
                #expect(entry.contains(shape), "\(id): \(entry)")
                let reopened = try SQLiteLivingMemoryStore(file: file, access: .readOnly)
                guard case .duplicate = try await SQLiteLivingMemoryStore(file: file, makeID: { ExperienceID("unused") })
                    .record(ExperienceEvent(id: id, subject: .unattributed(mixer), outcome: outcome, at: t0)) else {
                    Issue.record("\(id) did not read back as the same event"); continue
                }
                #expect(try await reopened.experiences(in: ["test.synthetic.mixer"]).count == 1)
            }
            #expect(try RawDatabase(file).text("SELECT record FROM experiences") == Legacy.record,
                    "the legacy select row is untouched")
        }
    }
}

/// RawDatabase is a direct connection for arranging and inspecting files behind the store's back.
private final class RawDatabase {
    private var handle: OpaquePointer?

    init(_ file: URL) throws {
        guard sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw SQLiteLivingMemoryError.sqlite(code: -1, message: "raw open failed")
        }
    }

    deinit { sqlite3_close_v2(handle) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteLivingMemoryError.sqlite(code: -1, message: String(cString: sqlite3_errmsg(handle)))
        }
    }

    /// Runs one statement with text bindings; a nil binds NULL.
    func insert(_ sql: String, _ values: [String?]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteLivingMemoryError.sqlite(code: -1, message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            if let value {
                sqlite3_bind_text(statement, Int32(offset + 1), value, -1, transient)
            } else {
                sqlite3_bind_null(statement, Int32(offset + 1))
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteLivingMemoryError.sqlite(code: -1, message: String(cString: sqlite3_errmsg(handle)))
        }
    }

    func integer(_ sql: String) throws -> Int64 {
        try first(sql) { sqlite3_column_int64($0, 0) }
    }

    func text(_ sql: String) throws -> String {
        try first(sql) { String(cString: sqlite3_column_text($0, 0)) }
    }

    private func first<T>(_ sql: String, _ read: (OpaquePointer) -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteLivingMemoryError.sqlite(code: -1, message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteLivingMemoryError.sqlite(code: -1, message: "no row for \(sql)")
        }
        return read(statement)
    }
}
