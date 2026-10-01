//
//  TurnRecorderTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
import SQLiteLivingMemory
import Testing

/// Synthetic turns written to a real SQLite file in a temporary knowledge directory.
@Suite("Persisting a turn's candidate", .serialized)
struct TurnRecorderTests {

    private let request = "Seleziona Output Busses nel filtro e verifica il nuovo valore. "
        + "Fermati se il controllo non è univoco."

    private func withKnowledge(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mecum-turn-recorder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    /// One turn through the real tool adapter: observe, then select.
    @MainActor
    private func turn(
        _ session: EvidenceSession,
        request  : String? = nil,
        control  : String = "All Busses",
        item     : String = "Output Busses",
        ending   : TurnAdmission.Ending = .completed,
        followed : TurnAdmission.FollowedExperience? = nil
    ) async throws -> TurnLedger.Report {
        let tools = AutomationTools(session: session)
        let ledger = TurnLedger()
        tools.onEvent = { ledger.record($0) }
        ledger.begin(request: request ?? self.request, followed: followed)
        let id = JSONValue.string(try #require(session.id).uuidString)
        _ = try await tools.call("observe", .object(["session": id]))
        _ = try await tools.call("select", .object(["session": id, "control": .string(control),
                                                    "item": .string(item)]))
        return try #require(ledger.finish(ending))
    }

    @Test("one verified candidate is saved once and read back by a new instance, without session data")
    @MainActor
    func savedAndReadBack() async throws {
        try await withKnowledge { knowledge in
            let file = SQLiteLivingMemoryStore.file(inKnowledgeDirectory: knowledge)
            let session = EvidenceSession()
            let sessionID = try #require(session.id).uuidString
            do {
                let store = try SQLiteLivingMemoryStore(file: file)
                let outcome = await TurnRecorder(store: store).record(try await turn(session))
                guard case .recorded(.applied(let record?), .admittedSingleSelection) = outcome else {
                    Issue.record("not recorded: \(outcome)"); return
                }
                #expect(outcome.notice?.contains("verified ×1") == true)
                #expect(record.successCount == 1)
            }
            let reopened = try SQLiteLivingMemoryStore(file: file, access: .readOnly)
            let experiences = try await reopened.experiences(in: ["test.synthetic.mixer"])
            #expect(experiences.count == 1)
            let record = try #require(experiences.first)
            #expect(record.phrase == request)
            #expect(record.step == ExperienceStep.select(control: "All Busses", item: "Output Busses"))
            #expect(record.latestProof?.dropdown?.change == .changed)
            #expect(try await reopened.history(of: record.id).count == 1)
            let bytes = try [file, URL(fileURLWithPath: file.path + "-wal")]
                .filter { FileManager.default.fileExists(atPath: $0.path) }
                .map { try Data(contentsOf: $0) }
                .reduce(Data(), +)
            #expect(bytes.range(of: Data(sessionID.utf8)) == nil)
            #expect(bytes.range(of: Data("987654321".utf8)) == nil)
        }
    }

    @Test("the chat's store outlives a released session")
    @MainActor
    func availableAfterRelease() async throws {
        try await withKnowledge { knowledge in
            let store = try SQLiteLivingMemoryStore(file: SQLiteLivingMemoryStore.file(inKnowledgeDirectory: knowledge))
            let session = AutomationSession(knowledgeDirectory: knowledge, livingMemory: store)
            await session.close()
            let outcome = await TurnRecorder(store: store).record(try await turn(EvidenceSession()))
            #expect(outcome.notice?.hasPrefix("memory: remembered") == true)
            #expect(try await store.experiences(in: ["test.synthetic.mixer"]).count == 1)
        }
    }

    @Test("a store failure after the action keeps the action's outcome, repeats nothing, and says so")
    @MainActor
    func storeFailureAfterEffect() async throws {
        let session = EvidenceSession()
        let report = try await turn(session)
        let outcome = await TurnRecorder(store: UnwritableMemory()).record(report)
        guard case .failed(.admittedSingleSelection, let error) = outcome else {
            Issue.record("the failure was hidden: \(outcome)"); return
        }
        #expect(error.contains("Unwritable"))
        #expect(outcome.notice?.contains("nothing was repeated") == true)
        #expect(session.selections == 1)
        guard case .select(_, _, .foundActed, _)? = report.attempts.last else {
            Issue.record("the action's outcome changed"); return
        }
    }

    @Test("delivering a report twice counts once; a new turn counts again")
    @MainActor
    func idempotency() async throws {
        try await withKnowledge { knowledge in
            let store = try SQLiteLivingMemoryStore(file: SQLiteLivingMemoryStore.file(inKnowledgeDirectory: knowledge))
            let recorder = TurnRecorder(store: store)
            let report = try await turn(EvidenceSession())
            _ = await recorder.record(report)
            guard case .recorded(.duplicate(let again?), _) = await recorder.record(report) else {
                Issue.record("a redelivery was not a duplicate"); return
            }
            #expect(again.successCount == 1)
            _ = await recorder.record(try await turn(EvidenceSession()))
            #expect(try await store.experiences(in: ["test.synthetic.mixer"]).first?.successCount == 2)
        }
    }

    @Test("a contradiction of the followed memory keeps its success and its history")
    @MainActor
    func attributedCorrection() async throws {
        try await withKnowledge { knowledge in
            let store = try SQLiteLivingMemoryStore(file: SQLiteLivingMemoryStore.file(inKnowledgeDirectory: knowledge))
            let recorder = TurnRecorder(store: store)
            guard case .recorded(.applied(let learned?), _) = await recorder.record(try await turn(EvidenceSession()))
            else { Issue.record("nothing learned"); return }
            let session = EvidenceSession()
            session.readback = .window("All Busses")
            let followed = TurnAdmission.FollowedExperience(id: learned.id, step: learned.step)
            let outcome = await recorder.record(try await turn(session, followed: followed))
            guard case .recorded(.applied(let corrected?), .contradictsFollowedExperience) = outcome else {
                Issue.record("not attributed: \(outcome)"); return
            }
            #expect(corrected.successCount == 1)
            #expect(corrected.failureCount == 1)
            #expect(outcome.notice?.contains("did not hold") == true)
            let history = try await store.history(of: learned.id)
            #expect(history.map(\.event.outcome).count == 2)
            guard case .verified = history.first?.event.outcome else { Issue.record("history lost"); return }
        }
    }

    @Test("a contradiction in a turn of several steps is recorded once, with its success and history kept")
    @MainActor
    func contradictionAmongSeveralSteps() async throws {
        try await withKnowledge { knowledge in
            let store = try SQLiteLivingMemoryStore(file: SQLiteLivingMemoryStore.file(inKnowledgeDirectory: knowledge))
            let recorder = TurnRecorder(store: store)
            guard case .recorded(.applied(let learned?), _) = await recorder.record(try await turn(EvidenceSession()))
            else { Issue.record("nothing learned"); return }
            let session = EvidenceSession()
            session.readback = .window("All Busses")
            let tools = AutomationTools(session: session)
            let ledger = TurnLedger()
            tools.onEvent = { ledger.record($0) }
            ledger.begin(request: request, followed: TurnAdmission.FollowedExperience(id: learned.id, step: learned.step,
                                                                                    context: learned.context))
            let id = JSONValue.string(try #require(session.id).uuidString)
            _ = try await tools.call("select", .object(["session": id, "control": .string("All Busses"),
                                                        "item": .string("Output Busses")]))
            _ = try await tools.call("act", .object(["session": id, "target": .string("Close"), "verb": .string("click")]))
            let report = try #require(ledger.finish(.completed))
            #expect(report.decision.reason == .contradictsFollowedExperience)
            guard case .recorded(.applied(let corrected?), .contradictsFollowedExperience) = await recorder.record(report)
            else { Issue.record("the contradiction was not recorded"); return }
            #expect(corrected.successCount == 1 && corrected.failureCount == 1)
            guard case .recorded(.duplicate(let again?), _) = await recorder.record(report) else {
                Issue.record("a redelivery was not a duplicate"); return
            }
            #expect(again.failureCount == 1)
            #expect(try await store.history(of: learned.id).count == 2)
        }
    }

    @Test("an uncertain select or an interrupted turn creates no success")
    @MainActor
    func noSuccessFromUncertainty() async throws {
        try await withKnowledge { knowledge in
            let store = try SQLiteLivingMemoryStore(file: SQLiteLivingMemoryStore.file(inKnowledgeDirectory: knowledge))
            let recorder = TurnRecorder(store: store)
            let interrupted = await recorder.record(try await turn(EvidenceSession(), ending: .interrupted))
            #expect(interrupted == .recorded(.applied(nil), .turnInterrupted))
            #expect(interrupted.notice == "memory: nothing learned from this turn (turnInterrupted)")
            let session = EvidenceSession()
            session.readback = .unreadable(.nothingAtControl)
            #expect(await recorder.record(try await turn(session)) == .recorded(.applied(nil), .notVerified))
            #expect(try await store.experiences(in: ["test.synthetic.mixer"]).isEmpty)
        }
    }

    @Test("a negated or compound request teaches nothing, although the select really changed the value")
    @MainActor
    func negatedOrCompoundRequest() async throws {
        try await withKnowledge { knowledge in
            let store = try SQLiteLivingMemoryStore(file: SQLiteLivingMemoryStore.file(inKnowledgeDirectory: knowledge))
            let recorder = TurnRecorder(store: store)
            let requests: [(String, TurnAdmission.Reason)] = [
                ("Non selezionare Headphones nel dropdown Output", .uncertainGoal),
                ("Seleziona Headphones, seleziona Speakers", .compoundGoal),
            ]
            for (request, reason) in requests {
                let session = EvidenceSession()
                let report = try await turn(session, request: request, control: "Speakers", item: "Headphones")
                guard case .select(_, _, .foundActed, let proof?)? = report.attempts.last,
                      proof.change == .changed else {
                    Issue.record("the synthetic select did not change the value: \(report.attempts)"); return
                }
                #expect(session.selections == 1)
                #expect(await recorder.record(report) == .recorded(.applied(nil), reason), "\(request)")
            }
            #expect(try await store.experiences(in: ["test.synthetic.mixer"]).isEmpty)
        }
    }

    @Test("a qualified item or a reversed direction teaches nothing, although the select really changed the value")
    @MainActor
    func qualifiedOrReversedRequest() async throws {
        try await withKnowledge { knowledge in
            let store = try SQLiteLivingMemoryStore(file: SQLiteLivingMemoryStore.file(inKnowledgeDirectory: knowledge))
            let recorder = TurnRecorder(store: store)
            for request in ["Seleziona Output Busses 2 nel filtro della scheda Bus e verifica il nuovo valore",
                            "Cambia il filtro da Output Busses a Mix Busses"] {
                let session = EvidenceSession()
                let report = try await turn(session, request: request, control: "Input")
                #expect(session.selections == 1)
                let outcome = await recorder.record(report)
                if case .recorded(.applied(_?), _) = outcome { Issue.record("learned: \(request) → \(outcome)") }
            }
            #expect(try await store.experiences(in: ["test.synthetic.mixer"]).isEmpty)
        }
    }

    @Test("an avoided, replaced or unrepresented request teaches nothing, although the select changed the value")
    @MainActor
    func avoidedOrReplacedRequest() async throws {
        try await withKnowledge { knowledge in
            let store = try SQLiteLivingMemoryStore(file: SQLiteLivingMemoryStore.file(inKnowledgeDirectory: knowledge))
            let recorder = TurnRecorder(store: store)
            for request in ["Evita di selezionare Output Busses nel filtro", "Seleziona Mix Busses invece di Output Busses",
                            "Cambia Output Busses in Mix Busses", "Seleziona Output Busses nel filtro di Track 2",
                            "Ciao. Non selezionare Output Busses nel filtro"] {
                let session = EvidenceSession()
                let report = try await turn(session, request: request, control: "Input")
                #expect(session.selections == 1)
                let outcome = await recorder.record(report)
                if case .recorded(.applied(_?), _) = outcome { Issue.record("learned: \(request) → \(outcome)") }
            }
            #expect(try await store.experiences(in: ["test.synthetic.mixer"]).isEmpty)
        }
    }

    @Test("a request to leave the item for the value shown teaches nothing, and a new chat never offers or confirms it")
    @MainActor
    func leavingTheItemInProduction() async throws {
        let leaving = ["Seleziona All Busses invece che Output Busses",
                       "Scegli All Busses al posto delle Output Busses",
                       "Seleziona All Busses invece delle Output Busses",
                       "Seleziona All Busses piuttosto di Output Busses",
                       "Switch the filter from the Output Busses"]
        try await withKnowledge { knowledge in
            let file = SQLiteLivingMemoryStore.file(inKnowledgeDirectory: knowledge)
            let store = try SQLiteLivingMemoryStore(file: file)
            let recorder = TurnRecorder(store: store)
            // The dropdown shows All Busses and the select really reaches Output Busses: the proof is verified.
            for request in leaving {
                let session = EvidenceSession()
                let report = try await turn(session, request: request, control: "All Busses")
                guard case .select(_, _, .foundActed, let proof?)? = report.attempts.last, proof.change == .changed,
                      proof.valueBefore == "All Busses" else {
                    Issue.record("the select was not verified: \(report.attempts)"); return
                }
                #expect(report.decision.reason == .itemIsOrigin, "\(request)")
                let outcome = await recorder.record(report)
                if case .recorded(.applied(_?), _) = outcome { Issue.record("learned: \(request) → \(outcome)") }
            }
            #expect(try await store.experiences(in: ["test.synthetic.mixer"]).isEmpty)

            // A memory learned from a valid request, then each request in a new chat over the same file.
            let valid = "Seleziona Output Busses nel filtro e verifica il nuovo valore."
            _ = await recorder.record(try await turn(EvidenceSession(), request: valid, control: "All Busses"))
            let learned = try #require(try await store.experiences(in: ["test.synthetic.mixer"]).first)
            #expect(learned.successCount == 1)
            let restarted = try SQLiteLivingMemoryStore(file: file)
            let memory = TurnMemory(store: restarted)
            let followed = TurnAdmission.FollowedExperience(id: learned.id, step: learned.step,
                                                            context: learned.context)
            for request in leaving {
                let preparation = await memory.begin(request: request, turnID: UUID(), sessionIsOpen: false)
                #expect(preparation.failure == nil)
                #expect(preparation.briefing == nil, "\(request)")
                #expect(preparation.followed == nil, "\(request)")
                #expect(try TurnMemory.prompt(for: request, briefing: preparation.briefing) == request)
                memory.end()
                // Even a model that follows the memory on its own confirms nothing for this request.
                let report = try await turn(EvidenceSession(), request: request, control: "All Busses",
                                            followed: followed)
                #expect(report.decision.reason == .itemIsOrigin, "\(request)")
                if case .confirm = report.decision.action { Issue.record("confirmed: \(request)") }
                _ = await TurnRecorder(store: restarted).record(report)
            }
            let after = try await restarted.experiences(in: ["test.synthetic.mixer"])
            #expect(after.count == 1 && after.first?.successCount == 1 && after.first?.failureCount == 0)

            // The valid request is still offered and confirmed.
            let offered = await memory.begin(request: valid, turnID: UUID(), sessionIsOpen: false)
            #expect(offered.briefing?.status == "suggested")
            let confirmation = try await turn(EvidenceSession(), request: valid, control: "All Busses",
                                              followed: try #require(offered.followed))
            memory.end()
            #expect(confirmation.decision.reason == .confirmsFollowedExperience)
            _ = await TurnRecorder(store: restarted).record(confirmation)
            #expect(try await restarted.experiences(in: ["test.synthetic.mixer"]).first?.successCount == 2)
        }
    }

    @Test("a readback taken from a neighbour grazing the dropdown's place proves nothing and teaches nothing")
    @MainActor
    func grazingNeighbourReadbackTeachesNothing() async throws {
        let opener = NormalizedRect(x: 0.40, y: 0.20, width: 0.20, height: 0.05)
        let neighbour = SceneElement(id: "control|output busses", kind: .control, label: "Output Busses",
                                     bounds: NormalizedRect(x: 0.599, y: 0.20, width: 0.20, height: 0.05))
        func after(_ elements: [SceneElement]) -> SceneSnapshot {
            SceneSnapshot(bundleID: "test.synthetic.mixer", appName: "Synthetic Mixer", windowTitle: "Synthetic Routing",
                          viewportPixelSize: ViewportPixelSize(width: 800, height: 600), elements: elements)
        }
        try await withKnowledge { knowledge in
            let store = try SQLiteLivingMemoryStore(file: SQLiteLivingMemoryStore.file(inKnowledgeDirectory: knowledge))
            // The dropdown operated is not perceived after the menu closes; its neighbour already reads the item.
            let lost = EvidenceSession()
            lost.readback = DropdownReadback.atControl(opener, in: after([neighbour]), windowSizeKept: true)
            let report = try await turn(lost)
            guard case .select(_, _, let kind, let proof?)? = report.attempts.last else {
                Issue.record("no select evidence: \(report.attempts)"); return
            }
            #expect(kind == .actedUnverified)
            #expect(proof.change == .unverified)
            #expect(report.event?.outcome == .uncertain(.readbackUnavailable(.nothingAtControl)))
            #expect(report.decision.reason == .notVerified)
            let outcome = await TurnRecorder(store: store).record(report)
            if case .recorded(.applied(_?), _) = outcome { Issue.record("learned from a neighbour: \(outcome)") }
            #expect(try await store.experiences(in: ["test.synthetic.mixer"]).isEmpty)

            // The control's own value at its place, beside the same neighbour, is learned.
            let seen = EvidenceSession()
            let own = SceneElement(id: "control|output busses", kind: .control, label: "Output Busses", bounds: opener)
            seen.readback = DropdownReadback.atControl(opener, in: after([own, neighbour]), windowSizeKept: true)
            let verified = try await turn(seen)
            #expect(verified.decision.reason == .admittedSingleSelection)
            _ = await TurnRecorder(store: store).record(verified)
            #expect(try await store.experiences(in: ["test.synthetic.mixer"]).count == 1)
        }
    }

    @Test("a transcript that cannot be written after a verified select teaches nothing and repeats nothing")
    @MainActor
    func transcriptFailsAfterTheEffect() async throws {
        struct TranscriptUnwritable: Error {}
        try await withKnowledge { knowledge in
            let store = try SQLiteLivingMemoryStore(file: SQLiteLivingMemoryStore.file(inKnowledgeDirectory: knowledge))
            let session = EvidenceSession()
            let tools = AutomationTools(session: session)
            let ledger = TurnLedger()
            tools.onEvent = { ledger.record($0) }
            tools.record = { line in if line.hasPrefix("← select") { throw TranscriptUnwritable() } }
            ledger.begin(request: request)
            let id = JSONValue.string(try #require(session.id).uuidString)
            await #expect(throws: TranscriptUnwritable.self) {
                _ = try await tools.call("select", .object(["session": id, "control": .string("All Busses"),
                                                            "item": .string("Output Busses")]))
            }
            let report = try #require(ledger.finish(.completed))
            guard case .select(_, _, .foundActed, let proof?)? = report.attempts.dropLast().last,
                  proof.change == .changed else {
                Issue.record("the effect's outcome was lost: \(report.attempts)"); return
            }
            #expect(report.attempts.last == .failed("select"))
            #expect(await TurnRecorder(store: store).record(report) == .recorded(.applied(nil), .toolFailed))
            #expect(try await store.experiences(in: ["test.synthetic.mixer"]).isEmpty)
            #expect(session.selections == 1)
        }
    }

    @Test("sightings and the experience are durable without waiting for the brain's JSON flush")
    @MainActor
    func durableBesideTheBrain() async throws {
        try await withKnowledge { knowledge in
            let file = SQLiteLivingMemoryStore.file(inKnowledgeDirectory: knowledge)
            let store = try SQLiteLivingMemoryStore(file: file)
            // The brain here never reaches disk, which is what an unflushed write-behind looks like.
            let brain = BrainMemory(store: InMemoryKnowledgeStore(),
                                    clock: { Date(timeIntervalSince1970: 1_800_000_000) })
            var scene = SceneSnapshot(
                bundleID: "test.synthetic.mixer", appName: "Synthetic Mixer", windowTitle: "Synthetic Routing",
                viewportPixelSize: ViewportPixelSize(width: 800, height: 600),
                elements: ["All Busses", "Input", "Output"].enumerated().map { index, label in
                    SceneElement(id: "control|\(label)", kind: .control, label: label,
                                 bounds: NormalizedRect(x: 0.05 + Double(index) * 0.2, y: 0.2,
                                                        width: 0.15, height: 0.05))
                }
            )
            scene.coverage = .window
            _ = try await SceneIntake(brain: brain, livingMemory: store).learn(from: scene)
            _ = await TurnRecorder(store: store).record(try await turn(EvidenceSession()))
            let reader = try SQLiteLivingMemoryStore(file: file, access: .readOnly)
            #expect(try await reader.sightings(in: ["test.synthetic.mixer"]).count == 3)
            #expect(try await reader.experiences(in: ["test.synthetic.mixer"]).count == 1)
            let brainFile = knowledge.appendingPathComponent("test.synthetic.mixer.json")
            #expect(!FileManager.default.fileExists(atPath: brainFile.path))
        }
    }
}

/// UnwritableMemory refuses every write, as a full disk or a locked file would.
private struct UnwritableMemory: LivingMemoryStoring {
    struct Unwritable: Error {}

    func recordSightings(_ observations: [SightingObservation]) async throws -> [Sighting] { throw Unwritable() }
    func sightings(in bundleIDs: Set<String>) async throws -> [Sighting] { [] }
    func record(_ event: ExperienceEvent) async throws -> ExperienceRecording { throw Unwritable() }
    func experiences(in bundleIDs: Set<String>) async throws -> [ExperienceRecord] { [] }
    func history(of experience: ExperienceID) async throws -> [ExperienceHistoryEntry] { [] }
    func candidates(for phrase: String, in bundleIDs: Set<String>?) async throws -> [ExperienceRecord] { [] }
    func record(_ decision: RecallDecisionRecord) async throws { throw Unwritable() }
    func decisions(about experience: ExperienceID) async throws -> [RecallDecisionRecord] { [] }
}
