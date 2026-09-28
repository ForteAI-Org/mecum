//
//  WorkspaceStore+Workers.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import ModelTransports
import SwiftData

extension WorkspaceStore {

    // MARK: Reading

    /// Every worker, archived ones included only when asked, by name.
    func workers(includingArchived: Bool = false) throws -> [WorkerSnapshot] {
        let rows = try modelContext.fetch(
            FetchDescriptor<Worker>(sortBy: [SortDescriptor(\.name)])
        )
        let current = try currentConfigurations()
        return rows
            .filter { includingArchived || !$0.isArchived }
            .map { WorkerSnapshot($0, configuration: current[$0.id]) }
    }

    func worker(_ id: UUID) throws -> WorkerSnapshot? {
        guard let row = try workerRow(id) else { return nil }
        return WorkerSnapshot(row, configuration: try currentConfigurationRow(of: id))
    }

    // MARK: Writing

    /// Creates a worker with no model attached. It is saved and listed, and it
    /// is to configure until `configure(worker:selection:)` is called; nothing
    /// here invents a connection for it.
    @discardableResult
    func createWorker(
        id          : UUID    = UUID(),
        name        : String,
        role        : String? = nil,
        instructions: String? = nil,
        appearance  : WorkerAppearance
    ) throws -> WorkerSnapshot {

        let worker = Worker(
            id          : id,
            name        : name,
            role        : role,
            instructions: instructions,
            appearance  : appearance
        )
        modelContext.insert(worker)
        try saveOrRollBack()
        return WorkerSnapshot(worker, configuration: nil)
    }

    /// Applies one edit.
    @discardableResult
    func update(worker id: UUID, _ change: WorkerChange) throws -> WorkerSnapshot {
        guard let worker = try workerRow(id) else { throw WorkspaceStoreError.workerNotFound(id) }

        switch change {
        case .name(let value):         worker.name         = value
        case .role(let value):         worker.role         = value
        case .instructions(let value): worker.instructions = value
        case .appearance(let value):   worker.appearance   = value
        case .archived(let value):     worker.isArchived   = value
        }

        try saveOrRollBack()
        return WorkerSnapshot(worker, configuration: try currentConfigurationRow(of: id))
    }

    /// Writes a new configuration version and returns its number. The previous
    /// versions stay: an execution already recorded keeps pointing at the one
    /// it ran with.
    @discardableResult
    func configure(worker id: UUID, selection: ModelSelection) throws -> Int {
        guard try workerRow(id) != nil else { throw WorkspaceStoreError.workerNotFound(id) }
        let version = (try currentConfigurationRow(of: id)?.version ?? 0) + 1
        modelContext.insert(WorkerConfiguration(workerID: id, version: version, selection: selection))
        try saveOrRollBack()
        return version
    }

    /// Deletes the worker for good, the act that is separate from archiving
    /// (§4.4): its row, every configuration version, its direct conversation
    /// with the messages in it, its executions and what the record holds on
    /// them, in one save or not at all. The record is append-only except for
    /// this (§18.3). A message it wrote where others take part stays,
    /// attributed to it and to no one else.
    ///
    /// Returns the conversations deleted with it, whose working folders the
    /// caller owns.
    @discardableResult
    func deleteWorker(_ id: UUID) throws -> [UUID] {
        guard let worker = try workerRow(id) else { throw WorkspaceStoreError.workerNotFound(id) }

        let conversations = try modelContext.fetch(FetchDescriptor<Conversation>())
            .filter { $0.kind == .direct && $0.participantIDs == [id] }
            .map(\.id)

        for conversation in conversations {
            let recorded: UUID? = conversation
            try modelContext.delete(
                model: Message.self,
                where: #Predicate { $0.conversationID == conversation }
            )
            try modelContext.delete(
                model: WorkspaceEvent.self,
                where: #Predicate { $0.conversationID == recorded }
            )
            try modelContext.delete(
                model: Conversation.self,
                where: #Predicate { $0.id == conversation }
            )
        }

        let worked: UUID? = id
        try modelContext.delete(
            model: WorkspaceEvent.self,
            where: #Predicate { $0.workerID == worked }
        )
        try modelContext.delete(
            model: Execution.self,
            where: #Predicate { $0.workerID == id }
        )
        try modelContext.delete(
            model: WorkerConfiguration.self,
            where: #Predicate { $0.workerID == id }
        )
        modelContext.delete(worker)

        try saveOrRollBack()
        return conversations
    }

    /// Starts an attempt and freezes the settings into it.
    ///
    /// Throws `workerNotConfigured` when no model is attached: an execution
    /// with an invented configuration would be a lie about what ran.
    @discardableResult
    func startExecution(
        worker      : UUID,
        conversation: UUID? = nil,
        at          : Date  = Date()
    ) throws -> ExecutionSnapshot {

        guard try workerRow(worker) != nil else { throw WorkspaceStoreError.workerNotFound(worker) }
        guard let configuration = try currentConfigurationRow(of: worker) else {
            throw WorkspaceStoreError.workerNotConfigured(worker)
        }

        let execution = Execution(
            workerID            : worker,
            conversationID      : conversation,
            startedAt           : at,
            configurationVersion: configuration.version,
            selection           : configuration.selection
        )
        modelContext.insert(execution)
        try saveOrRollBack()
        startedHere.insert(execution.id)
        return ExecutionSnapshot(execution)
    }

    func execution(_ id: UUID) throws -> ExecutionSnapshot? {
        try first(Execution.self, where: #Predicate { $0.id == id }).map(ExecutionSnapshot.init)
    }

    /// The worker's most recently started attempt, or nil before its first.
    func latestExecution(of worker: UUID) throws -> ExecutionSnapshot? {
        var descriptor = FetchDescriptor<Execution>(
            predicate: #Predicate { $0.workerID == worker },
            sortBy   : [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.map(ExecutionSnapshot.init)
    }

    // MARK: Rows

    private func workerRow(_ id: UUID) throws -> Worker? {
        try first(Worker.self, where: #Predicate { $0.id == id })
    }

    private func currentConfigurationRow(of worker: UUID) throws -> WorkerConfiguration? {
        var descriptor = FetchDescriptor<WorkerConfiguration>(
            predicate: #Predicate { $0.workerID == worker },
            sortBy   : [SortDescriptor(\.version, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// The highest version per worker, in one pass. A team is tens of workers,
    /// not tens of thousands, so one fetch beats one query each.
    private func currentConfigurations() throws -> [UUID: WorkerConfiguration] {
        let rows = try modelContext.fetch(
            FetchDescriptor<WorkerConfiguration>(sortBy: [SortDescriptor(\.version, order: .reverse)])
        )
        var latest: [UUID: WorkerConfiguration] = [:]
        for row in rows where latest[row.workerID] == nil { latest[row.workerID] = row }
        return latest
    }
}
