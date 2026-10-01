import AutomationMCP
import EngineCore
import Foundation
import LocalMCP
import Memory
import Testing

@Suite("Recall across changing contexts", .serialized)
@MainActor
struct TurnMemoryContextTests {
    let request = "Seleziona Output Busses nel filtro"

    func seed(_ store: InMemoryLivingMemoryStore, app: String, time: Double) async throws -> ExperienceRecord {
        let proof = DropdownEvidence(
            bundleID: app, windowTitle: "Synthetic Routing", control: "All Busses",
            controlRole: "AXPopUpButton", section: nil, valueBefore: "All Busses",
            requestedItem: "Output Busses", readback: .window("Output Busses"), menuClosedByChoice: true
        )
        let context = try #require(WindowContext(bundleID: app, windowTitle: "Synthetic Routing"))
        let draft = try #require(ExperienceDraft(phrase: request, step: ExperienceStep(proof), context: context))
        let result = try await store.record(ExperienceEvent(
            id: UUID().uuidString, subject: .step(draft), outcome: .verified(.dropdown(proof)),
            at: Date(timeIntervalSince1970: time)
        ))
        guard case .applied(let record?) = result else {
            throw NSError(domain: "TurnMemoryContextTests", code: 1)
        }
        return record
    }

    @Test func freshRefusalMustBeAvailableInInspectorHistory() async throws {
        let store = InMemoryLivingMemoryStore()
        let record = try await seed(store, app: "test.synthetic.mixer", time: 1)
        let memory = TurnMemory(store: store)
        let start = await memory.begin(request: request, turnID: UUID(), sessionIsOpen: false)
        #expect(start.briefing?.status == "suggested")
        let session = EvidenceSession()
        session.sceneBundleID = "test.synthetic.editor"
        session.sceneLabels = ["All Busses"]
        let fresh = await memory.observed(try await session.observe())
        #expect(fresh?["status"].string == "refused")
        let decisions = await store.decisions(about: record.id)
        #expect(decisions.last?.verdict == .refused)
    }

    @Test func freshSuggestionMustReceiveItsContradiction() async throws {
        let store = InMemoryLivingMemoryStore()
        let current = try await seed(store, app: "test.synthetic.mixer", time: 1)
        let other = try await seed(store, app: "test.synthetic.editor", time: 2)
        let session = EvidenceSession()
        session.sceneLabels = ["All Busses"]
        session.readback = .window("Internal Busses")
        let tools = AutomationTools(session: session)
        let cycle = TurnCycle(tools: tools, livingMemory: store)
        let start = try await cycle.begin(request, sessionIsOpen: false)
        #expect(start.memory?.followed?.id == other.id)
        let id = JSONValue.string(try #require(session.id).uuidString)
        let observation = try await tools.call("observe", .object(["session": id]))
        #expect(observation["structuredContent"]["memory"]["remembered"]["experienceID"].string == current.id.rawValue)
        _ = try await tools.call("select", .object([
            "session": id, "control": .string("All Busses"), "item": .string("Output Busses")
        ]))
        let end = await cycle.end(.completed)
        #expect(end?.report.decision.reason == .contradictsFollowedExperience)
        let after = try #require(await store.experiences(in: ["test.synthetic.mixer"]).first)
        #expect(after.failureCount == 1)
    }

    @Test func unrelatedRecentMemoriesMustNotHideCurrentContext() async throws {
        let store = InMemoryLivingMemoryStore()
        let current = try await seed(store, app: "test.synthetic.mixer", time: 1)
        for index in 0..<20 {
            _ = try await seed(store, app: "test.synthetic.other\(index)", time: Double(index + 2))
        }
        let session = EvidenceSession()
        session.sceneLabels = ["All Busses"]
        let scene = try await session.observe()
        let all = await store.candidates(for: request, in: nil)
        let correct = Recall.suggest(input: request, in: Recall.World(
            records: all, sightings: [], context: Recall.Context(freshScene: scene)
        ))
        guard case .suggest(let suggestion, _) = correct else {
            Issue.record("Uncapped recall failed unexpectedly")
            return
        }
        #expect(suggestion.record.id == current.id)
        let memory = TurnMemory(store: store)
        _ = await memory.observed(scene)
        let start = await memory.begin(request: request, turnID: UUID(), sessionIsOpen: true)
        #expect(start.followed?.id == current.id)
        #expect(await memory.observed(scene)?["status"].string == "suggested")
    }
    @Test func aPostActionObservationCannotReassignTheActionsContradiction() async throws {
        let store = InMemoryLivingMemoryStore()
        let current = try await seed(store, app: "test.synthetic.mixer", time: 1)
        let other = try await seed(store, app: "test.synthetic.editor", time: 2)
        let session = EvidenceSession()
        session.sceneLabels = ["All Busses"]
        session.readback = .window("Internal Busses")
        let tools = AutomationTools(session: session)
        let cycle = TurnCycle(tools: tools, livingMemory: store)
        _ = try await cycle.begin(request, sessionIsOpen: false)
        let id = JSONValue.string(try #require(session.id).uuidString)
        _ = try await tools.call("observe", .object(["session": id]))
        session.sceneBundleID = "test.synthetic.editor"
        _ = try await tools.call("select", .object([
            "session": id, "control": .string("All Busses"), "item": .string("Output Busses")
        ]))
        let end = await cycle.end(.completed)
        #expect(end?.report.decision.reason == .contradictsFollowedExperience)
        #expect(await store.experiences(in: ["test.synthetic.mixer"]).first?.failureCount == 1)
        #expect(await store.experiences(in: ["test.synthetic.editor"]).first?.failureCount == 0)
        #expect(await store.history(of: current.id).count == 2)
        #expect(await store.history(of: other.id).count == 1)
    }

}
