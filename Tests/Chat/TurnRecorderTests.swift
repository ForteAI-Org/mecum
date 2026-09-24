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

    private let request = "Seleziona Output Busses nel filtro della scheda Bus e verifica il nuovo valore. "
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
        ending   : TurnAdmission.Ending = .completed,
        followed : TurnAdmission.FollowedExperience? = nil
    ) async throws -> TurnLedger.Report {
        let tools = AutomationTools(session: session)
        let ledger = TurnLedger()
        tools.onEvent = { ledger.record($0) }
        ledger.begin(request: request, followed: followed)
        let id = JSONValue.string(try #require(session.id).uuidString)
        _ = try await tools.call("observe", .object(["session": id]))
        _ = try await tools.call("select", .object(["session": id, "control": .string("All Busses"),
                                                    "item": .string("Output Busses")]))
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
            #expect(record.step == ExperienceStep(tool: .select, control: "All Busses", item: "Output Busses"))
            #expect(record.latestProof?.change == .changed)
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
