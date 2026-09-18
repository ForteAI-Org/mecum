//
//  InMemoryKnowledgeStore.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

/// InMemoryKnowledgeStore is `KnowledgeStoring` over a dictionary: the store for a test, a dry run,
/// or a session that must leave nothing on disk. Actor isolation is the serialization the role asks for.
public actor InMemoryKnowledgeStore: KnowledgeStoring {

    private var knowledge: [String: AppKnowledge] = [:]

    public init(_ initial: [AppKnowledge] = []) {
        for entry in initial { knowledge[entry.bundleID] = entry }
    }

    public func load(bundleID: String) -> AppKnowledge? {
        knowledge[bundleID]
    }

    public func save(_ value: AppKnowledge) {
        knowledge[value.bundleID] = value
    }

    public func mutate<T: Sendable>(
        bundleID: String,
        _ body  : @Sendable (inout AppKnowledge) throws -> T
    ) throws -> T {
        var value = knowledge[bundleID] ?? AppKnowledge(bundleID: bundleID)
        let result = try body(&value)
        knowledge[bundleID] = value
        return result
    }

    public func bundleIDs() -> [String] {
        knowledge.keys.sorted()
    }
}
