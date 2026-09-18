//
//  InMemoryKnowledgeStoreTests.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

@testable import Memory
import Testing

@Suite("The in-memory knowledge store")
struct InMemoryKnowledgeStoreTests {

    @Test("mutate creates, loads and saves, and lists bundles")
    func mutate() async throws {
        let store = InMemoryKnowledgeStore()
        #expect(await store.load(bundleID: "com.x.app") == nil)
        let epoch: Int = try await store.mutate(bundleID: "com.x.app") { app in
            app.brain.ingestEpoch = 7
            return app.brain.ingestEpoch
        }
        #expect(epoch == 7)
        #expect(await store.load(bundleID: "com.x.app")?.brain.ingestEpoch == 7)
        try await store.mutate(bundleID: "com.x.app") { $0.brain.ingestEpoch += 1 }
        #expect(await store.load(bundleID: "com.x.app")?.brain.ingestEpoch == 8)
        await store.save(AppKnowledge(bundleID: "com.a"))
        #expect(await store.bundleIDs() == ["com.a", "com.x.app"])
    }

    @Test("concurrent mutations never lose an update")
    func concurrent() async throws {
        let store = InMemoryKnowledgeStore()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<25 { try? await store.mutate(bundleID: "com.x.app") { $0.brain.ingestEpoch += 1 } }
                }
            }
        }
        #expect(await store.load(bundleID: "com.x.app")?.brain.ingestEpoch == 200)
    }

    @Test("a throwing body leaves the store unchanged")
    func throwing() async throws {
        struct Boom: Error {}
        let store = InMemoryKnowledgeStore([AppKnowledge(bundleID: "com.x", brain: UIBrain(ingestEpoch: 3))])
        await #expect(throws: Boom.self) {
            try await store.mutate(bundleID: "com.x") { app in
                app.brain.ingestEpoch = 99
                throw Boom()
            }
        }
        #expect(await store.load(bundleID: "com.x")?.brain.ingestEpoch == 3)
    }
}
