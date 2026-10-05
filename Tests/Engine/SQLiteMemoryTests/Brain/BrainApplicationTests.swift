//
//  BrainApplicationTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

import EngineCore
import Foundation
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// Each application of the brain is concluded once per key, durably, in the transaction that ran
/// the algorithm: a retry answers the stored outcome, another command under the key is a conflict,
/// an application that changed nothing is still concluded, the clock of an application never runs
/// backwards, and the evidence names only what the algorithm's own counters moved.
@Suite("Brain applications: once per key, with their input, outcome, clock and evidence")
struct BrainApplicationTests {

    private typealias A = BrainApplicationFixtures

    @Test("the same key applied twice, after reopening and from a second store answers the first outcome and moves nothing again")
    func sameKeyOnce() async throws {
        let memory = try await A.open()
        try await memory.event("e1")
        let sample = try await memory.sample("e1")
        let command = try A.observe(sample, A.controls(["Send", "Draft", "Discard"]))
        let first = try await memory.applications.apply(command)
        #expect(first.receipt == .committed && first.outcome == .observed(created: 3, updated: 0, skippedAmbiguous: 0))
        let again = try await memory.applications.apply(command)
        #expect(again == BrainApplicationResult(receipt: .alreadyApplied, applicationID: first.applicationID, outcome: first.outcome,
                                                requestedAtMS: first.requestedAtMS, effectiveAtMS: first.effectiveAtMS))
        let brain = try #require(try await memory.brain())
        #expect(brain.objects.map(\.seenCount) == [1, 1, 1] && brain.ingestEpoch == 1)
        // Three anchors seen and the column they form: four targets, one support each.
        #expect(try await memory.count("SELECT count(*) FROM brain_evidence") == 4)
        await memory.store.close()

        let reopened = try await A.open(at: memory.url)
        let late = try await reopened.applications.apply(try A.observe(sample, A.controls(["Send", "Draft", "Discard"])))
        #expect(late.receipt == .alreadyApplied && late.outcome == first.outcome && late.applicationID == first.applicationID)
        let second = try await A.open(at: memory.url)
        #expect(try await second.applications.apply(command).receipt == .alreadyApplied)
        #expect(try await reopened.brain() == brain)
        #expect(try await reopened.count("SELECT count(*) FROM brain_applications") == 1)
        #expect(try await reopened.count("SELECT count(*) FROM brain_evidence") == 4)
        let stored = try #require(try await reopened.applications.application(.observe(sample)))
        #expect(stored.command.hasSameInput(as: command) && stored.outcome == first.outcome)
        #expect(stored.contractVersion == 1 && stored.algorithmVersion == BrainApplicationContract.algorithmVersion)
        await reopened.store.close()
        await second.store.close()
    }

    @Test("two stores applying one key at once conclude it once: one commit, one alreadyApplied, one increment, one support per target")
    func concurrentSameKey() async throws {
        let one = try await A.open()
        try await one.event("e1")
        let sample = try await one.sample("e1")
        let two = try await A.open(at: one.url, ids: BrainIdentities())
        let command = try A.observe(sample, A.controls(["Send", "Draft", "Discard"]))
        async let a = one.applications.apply(command)
        async let b = two.applications.apply(command)
        let results = try await [a, b]
        #expect(results.map(\.receipt).sorted { $0 == .committed && $1 != .committed } == [.committed, .alreadyApplied])
        #expect(Set(results.map(\.applicationID)).count == 1 && results[0].outcome == results[1].outcome)
        #expect(try await one.brain()?.objects.map(\.seenCount) == [1, 1, 1])
        #expect(try await one.count("SELECT count(*) FROM brain_evidence") == 4)
        await one.store.close()
        await two.store.close()
    }

    @Test("before, after and two ordinals of one event are distinct applications whose counters move, while each target has one support from the event")
    func distinctSamplesOneSupport() async throws {
        let memory = try await A.open()
        try await memory.event("e1")
        var results: [BrainApplicationResult] = []
        for (phase, ordinal) in [(CapturePhase.before, 0), (.after, 0), (.after, 1)] {
            let sample = try await memory.sample("e1", phase, ordinal: ordinal)
            results.append(try await memory.applications.apply(try A.observe(sample, A.controls(["Send", "Draft", "Discard"]))))
        }
        #expect(results.map(\.receipt) == [.committed, .committed, .committed])
        #expect(results.map(\.outcome) == [.observed(created: 3, updated: 0, skippedAmbiguous: 0),
                                           .observed(created: 0, updated: 3, skippedAmbiguous: 0),
                                           .observed(created: 0, updated: 3, skippedAmbiguous: 0)])
        #expect(try await memory.brain()?.objects.map(\.seenCount) == [3, 3, 3], "the algorithm counts each sample")
        #expect(try await memory.count("SELECT count(*) FROM brain_applications WHERE event_id = 'e1'") == 3)
        #expect(try await memory.count("SELECT count(*) FROM brain_evidence WHERE event_id = 'e1'") == 4,
                "three samples of one event are not three proofs: one support per anchor and for the column")
        await memory.store.close()
    }

    @Test("a record and a naming are keyed by their event alone: NULL phase and ordinal do not let the key in twice")
    func callKeys() async throws {
        let memory = try await A.open()
        try await memory.event("e1")
        try await memory.event("e2")
        let record = try A.record("e2", A.element("Send", index: 0), effect: .stateFlip(from: .off, to: .on))
        let first = try await memory.applications.apply(record)
        #expect(try await memory.applications.apply(record).receipt == .alreadyApplied)
        let name = try BrainApplicationCommand.setName("Send button", anchorKey: "anchor-1", in: A.bundle, eventID: "e2", requestedAt: A.t0)
        #expect(try await memory.applications.apply(name).receipt == .committed)
        #expect(try await memory.applications.apply(name).receipt == .alreadyApplied)
        #expect(first.outcome == .noAnchor)
        #expect(try await memory.count("SELECT count(*) FROM brain_applications WHERE event_id = 'e2'") == 2)
        #expect(try await memory.count("SELECT count(*) FROM brain_applications WHERE phase IS NULL AND sample_ordinal IS NULL") == 2)
        await memory.store.close()
    }

    @Test("no effect, no anchor, an empty ingest and an unknown anchor named are concluded applications, answered again on retry, with no evidence")
    func noOpsAreConcluded() async throws {
        let memory = try await A.open()
        for id in ["e1", "e2", "e3", "e4"] { try await memory.event(id) }
        let commands = [
            try A.record("e1", A.element("Send", index: 0), effect: nil),
            try A.record("e2", A.element("Send", index: 0), effect: .stateFlip(from: .off, to: .on)),
            try A.observe(try await memory.sample("e3"), []),
            try BrainApplicationCommand.setName("Ghost", anchorKey: "no-such-anchor", in: A.bundle, eventID: "e4", requestedAt: A.t0),
        ]
        let outcomes: [BrainApplicationOutcome] = [.noEffect, .noAnchor, .observed(created: 0, updated: 0, skippedAmbiguous: 0), .notNamed]
        for (command, outcome) in zip(commands, outcomes) {
            let first = try await memory.applications.apply(command)
            #expect(first.receipt == .committed && first.outcome == outcome)
            let again = try await memory.applications.apply(command)
            #expect(again.receipt == .alreadyApplied && again.outcome == outcome && again.applicationID == first.applicationID)
        }
        #expect(try await memory.texts("SELECT outcome FROM brain_applications ORDER BY application_id") == ["no_effect", "no_anchor", "observed", "not_named"])
        #expect(try await memory.texts("SELECT text_value FROM memory_operation_arguments WHERE argument_name = 'anchor_key'") == ["no-such-anchor"],
                "the unknown key is kept as a literal, not as a reference to an anchor")
        #expect(try await memory.count("SELECT count(*) FROM brain_evidence") == 0)
        #expect(try await memory.count("SELECT count(*) FROM brain_anchors") == 0)
        #expect(try await memory.brain() == UIBrain())
        await memory.store.close()
    }

    @Test("another command under a concluded key is a conflict, field by field, and nothing moves")
    func conflictsFieldByField() async throws {
        let memory = try await A.open()
        try await memory.event("e1")
        let sample = try await memory.sample("e1")
        let detections = A.controls(["Café", "Draft", "Discard"])
        let base = try A.observe(sample, detections, window: "inbox")
        _ = try await memory.applications.apply(base)
        let brain = try await memory.brain()
        var moved = detections
        moved[1] = BrainDetection(kind: .control, label: "Draft", bounds: NormalizedRect(x: 0.5, y: detections[1].bounds.y.nextUp, width: 0.03, height: 0.017))
        let variants: [(String, BrainApplicationCommand)] = [
            ("window absent", try A.observe(sample, detections, window: nil)),
            ("window empty", try A.observe(sample, detections, window: "")),
            ("decomposed é", try A.observe(sample, A.controls(["Cafe\u{301}", "Draft", "Discard"]), window: "inbox")),
            ("NUL", try A.observe(sample, A.controls(["Café\u{0}", "Draft", "Discard"]), window: "inbox")),
            ("separator", try A.observe(sample, A.controls(["Café|Draft", "Draft", "Discard"]), window: "inbox")),
            ("next REAL", try A.observe(sample, moved, window: "inbox")),
            ("order", try A.observe(sample, [detections[1], detections[0], detections[2]], window: "inbox")),
            ("pixel-only icon", try A.observe(sample, detections + [BrainDetection(kind: .icon, label: "", bounds: NormalizedRect(x: 0.9, y: 0.9, width: 0.02, height: 0.02))], window: "inbox")),
            ("requested time", try A.observe(sample, detections, window: "inbox", at: A.t0.addingTimeInterval(0.001))),
        ]
        for (name, variant) in variants {
            let error = await storeError { _ = try await memory.applications.apply(variant) }
            guard case .identity(let conflict)? = error else {
                Issue.record("\(name): expected a conflict, got \(String(describing: error))")
                continue
            }
            #expect(conflict.identity == "brain:e1:observe:after:0", Comment(rawValue: name))
        }
        let newer = SQLiteBrainApplicationRepository(store: memory.store, algorithmVersion: "brain-updater-2")
        let versioned = await storeError { _ = try await newer.apply(base) }
        guard case .identity(let conflict)? = versioned else {
            Issue.record("a new algorithm version must not re-apply the key, got \(String(describing: versioned))")
            return
        }
        #expect(conflict.storedFingerprint.hasPrefix("v1/brain-updater-1/") && conflict.offeredFingerprint.hasPrefix("v1/brain-updater-2/"))
        try await memory.event("e2")
        let flip = try A.record("e2", A.element("Café", index: 0), effect: .menuOpened(labels: ["A", "B"]))
        _ = try await memory.applications.apply(flip)
        for (name, variant) in [
            ("item order", try A.record("e2", A.element("Café", index: 0), effect: .menuOpened(labels: ["B", "A"]))),
            ("no effect", try A.record("e2", A.element("Café", index: 0), effect: nil)),
            ("empty list", try A.record("e2", A.element("Café", index: 0), effect: .menuOpened(labels: []))),
            ("verb", try A.record("e2", A.element("Café", index: 0), effect: .menuOpened(labels: ["A", "B"]), verb: .rightClick)),
        ] {
            let error = await storeError { _ = try await memory.applications.apply(variant) }
            guard case .identity? = error else {
                Issue.record("\(name): expected a conflict, got \(String(describing: error))")
                continue
            }
        }
        #expect(try await memory.count("SELECT count(*) FROM brain_applications") == 2)
        #expect(try await memory.brain()?.objects.map(\.seenCount) == brain?.objects.map(\.seenCount))
        #expect(try await memory.count("SELECT evidence_count FROM brain_transitions") == 1)
        await memory.store.close()
    }

    @Test("a late command runs at the application's clock, never earlier than what the brain holds: raw fixtures, another store, reopening, retirements; the event's own time stays")
    func effectiveClock() async throws {
        let memory = try await A.open()
        let later = A.t0.addingTimeInterval(3600)
        _ = try await memory.raw.ingest(A.controls(["Send", "Draft", "Discard"]), into: A.bundle, now: later, window: nil)
        try await memory.event("e1", occurredAtMS: try A.milliseconds(A.t0))
        let early = try await memory.applications.apply(try A.observe(try await memory.sample("e1"), A.controls(["Send", "Draft", "Discard"]), at: A.t0))
        let t0MS = try A.milliseconds(A.t0), laterMS = try A.milliseconds(later)
        #expect(early.requestedAtMS == t0MS && early.effectiveAtMS == laterMS)
        #expect(try await memory.integers("SELECT occurred_at_ms FROM memory_events WHERE event_id = 'e1'") == [t0MS])
        #expect(try await memory.brain()?.ingestEpoch == 1, "the same instant as the last tick is no new tick")
        #expect(try await memory.brain()?.objects.map(\.seenCount) == [2, 2, 2])

        let other = try await A.open(at: memory.url, ids: BrainIdentities())
        let latest = A.t0.addingTimeInterval(7200)
        try await other.event("e2")
        _ = try await other.applications.apply(try A.observe(try await other.sample("e2"), A.controls(["Send"]), at: latest))
        await memory.store.close()
        let reopened = try await A.open(at: memory.url, ids: BrainIdentities())
        try await reopened.event("e3")
        let behind = try await reopened.applications.apply(try A.observe(try await reopened.sample("e3"), A.controls(["Draft"]), at: A.t0.addingTimeInterval(60)))
        let latestMS = try A.milliseconds(latest), minuteMS = try A.milliseconds(A.t0.addingTimeInterval(60))
        #expect(behind.effectiveAtMS == latestMS, "the clock of the application, from another store, after reopening")
        let requested = try await reopened.integers("SELECT requested_at_ms FROM brain_applications ORDER BY application_id")
        #expect(requested == [t0MS, latestMS, minuteMS])

        // Retirements at an effective instant: a transient seen once, then eighteen blocks, every third offered
        // late. A late one runs at the application's clock, which is no new tick, so twelve blocks tick.
        try await reopened.event("e4")
        _ = try await reopened.applications.apply(try A.observe(try await reopened.sample("e4"), A.controls(["Send", "Draft", "Discard", "Once"]), at: latest))
        for i in 1...18 {
            let id = "r\(i)"
            try await reopened.event(id)
            let requested = i % 3 == 0 ? A.t0 : latest.addingTimeInterval(Double(i) * 600)
            _ = try await reopened.applications.apply(try A.observe(try await reopened.sample(id), A.controls(["Send", "Draft", "Discard"]), at: requested))
        }
        #expect(try await reopened.texts("SELECT retirement_cause FROM brain_anchors WHERE label = 'Once'") == ["transient"])
        #expect(try await reopened.count("SELECT count(*) FROM brain_anchors WHERE retired_at_ms < last_seen_ms") == 0)
        let effective = try await reopened.integers("SELECT effective_at_ms FROM brain_applications ORDER BY application_id").compactMap { $0 }
        #expect(effective == effective.sorted(), "an application's clock never runs backwards")
        #expect(try await reopened.count("SELECT count(*) FROM brain_applications WHERE effective_at_ms < requested_at_ms") == 0)
        #expect(try await reopened.store.read { try $0.query("PRAGMA foreign_key_check") { _ in () } }.isEmpty)
        await reopened.store.close()
        await other.store.close()
    }

    @Test("a failure inside the transaction leaves no application, argument, evidence or difference, and the same command then applies once")
    func failureLeavesNothing() async throws {
        let memory = try await A.open()
        try await memory.event("e1")
        let sample = try await memory.sample("e1")
        let pages = try await memory.store.read { try $0.query("PRAGMA page_count") { $0.integer(0) ?? 0 }.first ?? 0 }
        _ = try await memory.store.write { try $0.execute("PRAGMA max_page_count = \(pages + 1)") }
        let padding = String(repeating: "x", count: 40)
        let many = A.controls((0..<300).map { "Control \($0) \(padding)" })
        let command = try A.observe(sample, many)
        let error = await storeError { _ = try await memory.applications.apply(command) }
        guard case .failed(let fault)? = error else {
            Issue.record("expected the file to refuse, got \(String(describing: error))")
            return
        }
        #expect(fault.code.primary == 13)
        for table in ["brain_applications", "memory_operation_arguments", "brain_evidence", "brain_anchors"] {
            #expect(try await memory.count("SELECT count(*) FROM \(table)") == 0, Comment(rawValue: table))
        }
        #expect(try await memory.applications.application(.observe(sample)) == nil)
        _ = try await memory.store.write { try $0.execute("PRAGMA max_page_count = 1073741823") }
        let applied = try await memory.applications.apply(command)
        #expect(applied.receipt == .committed && applied.outcome == .observed(created: 300, updated: 0, skippedAmbiguous: 0))
        #expect(try await memory.applications.apply(command).receipt == .alreadyApplied)
        #expect(try await memory.count("SELECT count(*) FROM brain_anchors") == 300)
        await memory.store.close()
    }

    @Test("references the store does not hold, or that name another application, are typed refusals before anything is written")
    func references() async throws {
        let memory = try await A.open()
        await #expect(throws: BrainApplicationError.missingEvent(eventID: "nowhere")) {
            _ = try await memory.applications.apply(try A.observe(CaptureSampleKey(eventID: "nowhere", phase: .after), []))
        }
        try await memory.event("elsewhere", bundle: A.other)
        await #expect(throws: BrainApplicationError.eventOfAnotherApplication(eventID: "elsewhere")) {
            _ = try await memory.applications.apply(try A.observe(CaptureSampleKey(eventID: "elsewhere", phase: .after), []))
        }
        try await memory.event("seen", kind: .observation)
        await #expect(throws: BrainApplicationError.eventIsNotAnAction(eventID: "seen")) {
            _ = try await memory.applications.apply(try A.record("seen", A.element("Send", index: 0), effect: nil))
        }
        await #expect(throws: BrainApplicationError.missingSample(CaptureSampleKey(eventID: "seen", phase: .before))) {
            _ = try await memory.applications.apply(try A.observe(CaptureSampleKey(eventID: "seen", phase: .before), []))
        }
        _ = try await memory.captures.record(MemoryEventRecord(eventID: "global", source: .app, streamID: "w", sourceKey: "global",
                                                               kind: .action, app: nil, occurredAtMS: 1))
        await #expect(throws: BrainApplicationError.eventWithoutApp(eventID: "global")) {
            _ = try await memory.applications.apply(try A.record("global", A.element("Send", index: 0), effect: nil))
        }
        #expect(try await memory.count("SELECT count(*) FROM brain_applications") == 0)
        #expect(try await memory.count("SELECT count(*) FROM memory_operation_arguments") == 0)
        #expect(try await memory.count("SELECT count(*) FROM brain_apps WHERE bundle_id = 'test.fixture.applications'") == 1,
                "the application row is the event's, never invented")
        await memory.store.close()
    }

    @Test("a concluded application's header and input cannot be changed, extended or removed, and its sample keeps its identity")
    func sealedAndKept() async throws {
        let memory = try await A.open()
        try await memory.event("e1")
        let sample = try await memory.sample("e1")
        let applied = try await memory.applications.apply(try A.observe(sample, A.controls(["Send"])))
        let id = applied.applicationID
        for sql in [
            "UPDATE brain_applications SET outcome = 'observed', created_count = 9 WHERE application_id = \(id)",
            "UPDATE brain_applications SET requested_at_ms = 1 WHERE application_id = \(id)",
            "DELETE FROM brain_applications WHERE application_id = \(id)",
            "UPDATE memory_operation_arguments SET text_value = 'Sent' WHERE brain_application_id = \(id) AND argument_name = 'detection_label'",
            "DELETE FROM memory_operation_arguments WHERE brain_application_id = \(id)",
            "INSERT INTO memory_operation_arguments (brain_application_id, app_id, argument_name, position, value_kind, text_value) VALUES (\(id), 1, 'window', 0, 'text', 'late')",
            "UPDATE memory_event_observations SET sample_ordinal = 3 WHERE event_id = 'e1' AND observation_kind = 'capture'",
            "DELETE FROM memory_event_observations WHERE event_id = 'e1' AND observation_kind = 'capture'",
            "INSERT INTO memory_operation_arguments (brain_application_id, event_id, app_id, argument_name, position, value_kind, text_value) VALUES (\(id), 'e1', 1, 'x', 0, 'text', 'x')",
        ] {
            #expect(await refusal(of: sql, in: memory.store) != nil, Comment(rawValue: sql))
        }
        let orphan = await refusal(
            of: "INSERT INTO memory_operation_arguments (brain_application_id, app_id, argument_name, position, value_kind, text_value) VALUES (999, 1, 'verb', 0, 'text', 'click')",
            in: memory.store)
        #expect(orphan?.code.extended == 787, "an argument whose application never comes is refused at the commit")
        #expect(try await memory.applications.application(.observe(sample))?.command.hasSameInput(as: try A.observe(sample, A.controls(["Send"]))) == true)
        await memory.store.close()
    }

    @Test("a stored application another hand wrote is refused on the way out by its shape or version; a version this build cannot read is a conflict, not a re-application")
    func malformedStoredApplications() async throws {
        let memory = try await A.open()
        try await memory.event("e1")
        try await memory.event("e2")
        try await memory.store.write { transaction in
            try transaction.execute(
                "INSERT INTO memory_operation_arguments (brain_application_id, app_id, argument_name, position, value_kind, text_value) VALUES (1, 1, 'mood', 0, 'text', 'x')")
            try transaction.execute(
                """
                INSERT INTO brain_applications (application_id, app_id, event_id, operation, contract_version, algorithm_version,
                    requested_at_ms, effective_at_ms, outcome) VALUES (1, 1, 'e1', 'record', 1, 'brain-updater-1', 0, 0, 'no_effect')
                """)
            try transaction.execute(
                "INSERT INTO memory_operation_arguments (brain_application_id, app_id, argument_name, position, value_kind, text_value) VALUES (2, 1, 'verb', 0, 'text', 'click')")
            try transaction.execute(
                """
                INSERT INTO brain_applications (application_id, app_id, event_id, operation, contract_version, algorithm_version,
                    requested_at_ms, effective_at_ms, outcome) VALUES (2, 1, 'e2', 'record', 2, 'brain-updater-9', 0, 0, 'no_effect')
                """)
        }
        await #expect(throws: BrainApplicationError.malformedApplication(applicationID: 1, malformation: .forbiddenArgument("mood"))) {
            _ = try await memory.applications.application(.record(eventID: "e1"))
        }
        await #expect(throws: BrainApplicationError.malformedApplication(applicationID: 1, malformation: .forbiddenArgument("mood"))) {
            _ = try await memory.applications.apply(try A.record("e1", A.element("Send", index: 0), effect: nil))
        }
        await #expect(throws: BrainApplicationError.unsupportedContractVersion(2)) {
            _ = try await memory.applications.application(.record(eventID: "e2"))
        }
        let error = await storeError { _ = try await memory.applications.apply(try A.record("e2", A.element("Send", index: 0), effect: nil)) }
        guard case .identity? = error else {
            Issue.record("expected a conflict, got \(String(describing: error))")
            return
        }
        #expect(try await memory.count("SELECT count(*) FROM brain_applications") == 2)
        await memory.store.close()
    }

    @Test("the evidence names only what the algorithm's counters moved: anchors seen, groups merged, transitions raised; never an ambiguous candidate, a naming or a record that taught nothing")
    func evidenceSources() async throws {
        let memory = try await A.open()
        try await memory.event("e1")
        let column = (0..<3).map { BrainDetection(kind: .control, label: "S\($0)", bounds: NormalizedRect(x: 0.2, y: 0.1 + Double($0) * 0.05, width: 0.03, height: 0.017)) }
        let mute = [BrainDetection(kind: .control, label: "Mute", bounds: NormalizedRect(x: 0.7, y: 0.30, width: 0.03, height: 0.017)),
                    BrainDetection(kind: .control, label: "Mute", bounds: NormalizedRect(x: 0.7, y: 0.33, width: 0.03, height: 0.017))]
        let applied = try await memory.applications.apply(try A.observe(try await memory.sample("e1"), column + mute))
        #expect(applied.outcome == .observed(created: 5, updated: 0, skippedAmbiguous: 0))
        #expect(try await memory.count("SELECT count(*) FROM brain_evidence WHERE anchor_id IS NOT NULL AND event_id = 'e1'") == 5)
        #expect(try await memory.count("SELECT count(*) FROM brain_evidence WHERE group_id IS NOT NULL AND event_id = 'e1'") == 1)
        #expect(try await SQLiteBrainGraphRepository(store: memory.store).evidence(ofEvent: "e1").count == 6,
                "the register's evidence on the projection's anchors and group is read as valid by the graph's reader: no structural scene is asked for")
        #expect(try await memory.texts("SELECT DISTINCT assessed_by || ' ' || assessment_version FROM brain_evidence") == ["brain.observe brain-updater-1"])
        #expect(try await memory.integers("SELECT DISTINCT assessed_at_ms FROM brain_evidence") == [applied.effectiveAtMS])

        try await memory.event("e2")
        let between = [BrainDetection(kind: .control, label: "Mute", bounds: NormalizedRect(x: 0.7, y: 0.315, width: 0.03, height: 0.017))]
        let ambiguous = try await memory.applications.apply(try A.observe(try await memory.sample("e2"), between, at: A.t0.addingTimeInterval(1)))
        #expect(ambiguous.outcome == .observed(created: 0, updated: 0, skippedAmbiguous: 1))
        #expect(try await memory.count("SELECT count(*) FROM brain_evidence WHERE event_id = 'e2'") == 0, "an ambiguous match proves no identity")

        try await memory.event("e3")
        let s0 = try #require(try await memory.brain()?.objects.first { $0.label == "S0" }).anchorKey
        let named = try await memory.applications.apply(try .setName("First switch", anchorKey: s0, in: A.bundle, eventID: "e3", requestedAt: A.t0))
        #expect(named.outcome == .named(anchorKey: s0))
        try await memory.event("e4")
        #expect(try await memory.applications.apply(try A.record("e4", A.element("Unknown", index: 9), effect: .stateFlip(from: .off, to: .on))).outcome == .noAnchor)
        try await memory.event("e5")
        #expect(try await memory.applications.apply(try A.record("e5", A.element("S1", index: 0), effect: nil)).outcome == .noEffect)
        #expect(try await memory.count("SELECT count(*) FROM brain_evidence WHERE event_id IN ('e3', 'e4', 'e5')") == 0)

        try await memory.event("e6")
        let s1 = SceneElement(id: "s1", kind: .control, label: "S1", bounds: NormalizedRect(x: 0.2, y: 0.15, width: 0.03, height: 0.017))
        let recorded = try await memory.applications.apply(try A.record("e6", s1, effect: .stateFlip(from: .off, to: .on)))
        guard case .recorded(let anchor, let transition, 1) = recorded.outcome else {
            Issue.record("expected a recorded transition, got \(recorded.outcome)")
            return
        }
        #expect(try await memory.texts("SELECT transition_id FROM brain_evidence WHERE event_id = 'e6'") == [transition])
        #expect(try await memory.texts("SELECT anchor_id FROM brain_transitions WHERE transition_id = ?", [.text(transition)]) == [anchor])
        try await memory.event("e7")
        let raised = try await memory.applications.apply(try A.record("e7", s1, effect: .stateFlip(from: .off, to: .on)))
        #expect(raised.outcome == .recorded(anchorKey: anchor, transitionID: transition, evidence: 2))
        #expect(try await memory.count("SELECT count(*) FROM brain_evidence WHERE transition_id = ?", [.text(transition)]) == 2)
        try await memory.event("e8")
        let platform = SceneElement(id: "p", kind: .control, label: "Platform", bounds: NormalizedRect(x: 0.9, y: 0.05, width: 0.05, height: 0.02))
        let reveal = try await memory.applications.apply(try A.record("e8", platform, effect: .menuOpened(labels: ["Desktop", "Web"])))
        guard case .recorded(let revealer, _, 1) = reveal.outcome else {
            Issue.record("expected a reveal, got \(reveal.outcome)")
            return
        }
        #expect(try await memory.texts("SELECT coalesce(anchor_id, transition_id) FROM brain_evidence WHERE event_id = 'e8' ORDER BY evidence_id").first == revealer,
                "the anchor a reveal created is supported, then its transition")
        #expect(try await memory.count("SELECT count(*) FROM brain_evidence WHERE event_id = 'e8'") == 2)
        await memory.store.close()
    }

    @Test("retirement after applications keeps every evidence row and reference; the counters are never recomputed from links")
    func retirementKeepsEvidence() async throws {
        let memory = try await A.open()
        try await memory.event("e0")
        _ = try await memory.applications.apply(try A.observe(try await memory.sample("e0"), A.controls(["Send", "Draft", "Discard", "Once"])))
        let once = try #require(try await memory.brain()?.objects.first { $0.label == "Once" }).anchorKey
        for i in 1...12 {
            try await memory.event("e\(i)")
            _ = try await memory.applications.apply(try A.observe(try await memory.sample("e\(i)"), A.controls(["Send", "Draft", "Discard"]),
                                                                   at: A.t0.addingTimeInterval(Double(i) * 600)))
        }
        #expect(try await memory.texts("SELECT retirement_cause FROM brain_anchors WHERE anchor_id = ?", [.text(once)]) == ["transient"])
        #expect(try await memory.count("SELECT count(*) FROM brain_evidence WHERE anchor_id = ?", [.text(once)]) == 1)
        let send = try #require(try await memory.brain()?.objects.first { $0.label == "Send" })
        let sendLinks = try await memory.count("SELECT count(*) FROM brain_evidence WHERE anchor_id = ?", [.text(send.anchorKey)])
        #expect(send.seenCount == 13 && sendLinks == 13)
        #expect(try await memory.store.read { try $0.query("PRAGMA foreign_key_check") { _ in () } }.isEmpty)
        await memory.store.close()
    }

    @Test("a schema 1 file of the form before the applications register is refused by name and left untouched")
    func formWithoutApplicationsRefused() async throws {
        let url = try temporaryDatabase()
        let raw = try SQLiteConnection(path: url.path)
        try raw.execute(try SQLiteMemorySchema.text())
        try raw.execute("DROP TABLE brain_applications")
        try raw.execute("PRAGMA user_version = 1")
        raw.close()
        let before = try Data(contentsOf: url)
        let error = await storeError { _ = try await SQLiteMemoryStore.open(at: url) }
        #expect(error == .schema(.missingTables(["brain_applications"])))
        #expect(try Data(contentsOf: url) == before)
        #expect(SQLiteMemorySchema.requiredColumns.contains { $0 == ("memory_operation_arguments", "brain_application_id") })
    }

    @Test("an anchor created and dropped by the cap in one ingest has no row, so no evidence names it")
    func createdAndDroppedHasNoEvidence() async throws {
        let memory = try await A.open()
        try await memory.event("e1")
        var detections: [BrainDetection] = []
        for index in 0..<3001 {
            let column = Double(index % 61), row = Double(index / 61)
            let bounds = NormalizedRect(x: column * 0.016, y: row * 0.019, width: 0.012, height: 0.009)
            detections.append(BrainDetection(kind: .icon, label: "icon \(index)", bounds: bounds))
        }
        let applied = try await memory.applications.apply(try A.observe(try await memory.sample("e1"), detections))
        guard case .observed(let created, _, _) = applied.outcome else {
            Issue.record("expected an observation")
            return
        }
        #expect(created == 3001, "the outcome counts what the algorithm did")
        let rows = try await memory.count("SELECT count(*) FROM brain_anchors")
        let links = try await memory.count("SELECT count(*) FROM brain_evidence WHERE anchor_id IS NOT NULL")
        #expect(rows <= 3000 && links == rows, "no row is fabricated for the anchor the cap dropped")
        #expect(try await memory.store.read { try $0.query("PRAGMA foreign_key_check") { _ in () } }.isEmpty)
        await memory.store.close()
    }
}
