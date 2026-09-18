//
//  KnowledgeStoring.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

/// KnowledgeStoring keeps one `AppKnowledge` per application. A conformer serializes its own
/// mutations: two concurrent `mutate` calls on one bundle never lose an update, and a `load` after a
/// `mutate` returns sees what the mutation wrote, whether or not it has reached durable storage yet.
public protocol KnowledgeStoring: Sendable {

    /// The stored knowledge, or nil when nothing has been observed for this application.
    func load(bundleID: String) async throws -> AppKnowledge?

    /// Replaces the stored knowledge for the value's application.
    func save(_ knowledge: AppKnowledge) async throws

    /// Loads (or starts empty), applies the change, and stores the result, as one serialized step.
    func mutate<T: Sendable>(
        bundleID: String,
        _ body  : @Sendable (inout AppKnowledge) throws -> T
    ) async throws -> T

    /// Every application with stored knowledge, sorted.
    func bundleIDs() async throws -> [String]
}
