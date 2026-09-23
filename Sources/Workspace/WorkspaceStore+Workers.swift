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
    public func workers(includingArchived: Bool = false) throws -> [WorkerSnapshot] {
        let rows = try modelContext.fetch(
            FetchDescriptor<Worker>(sortBy: [SortDescriptor(\.name)])
        )
        let current = try currentConfigurations()
        return rows
            .filter { includingArchived || !$0.isArchived }
            .map { WorkerSnapshot($0, configuration: current[$0.id]) }
    }

    public func worker(_ id: UUID) throws -> WorkerSnapshot? {
        guard let row = try workerRow(id) else { return nil }
        return WorkerSnapshot(row, configuration: try currentConfigurationRow(of: id))
    }

    // MARK: Writing

    /// Creates a worker with no model attached. It is saved and listed, and it
    /// is to configure until `configure(worker:selection:)` is called; nothing
    /// here invents a connection for it.
    @discardableResult
    public func createWorker(
        id          : UUID    = UUID(),
        name        : String,
        role        : String? = nil,
        instructions: String? = nil,
        managerID   : UUID?   = nil,
        appearance  : WorkerAppearance
    ) throws -> WorkerSnapshot {

        if let managerID {
            guard try workerRow(managerID) != nil else {
                throw WorkspaceStoreError.workerNotFound(managerID)
            }
            try refuseCycle(worker: id, under: managerID)
        }

        let worker = Worker(
            id          : id,
            name        : name,
            role        : role,
            instructions: instructions,
            managerID   : managerID,
            appearance  : appearance
        )
        modelContext.insert(worker)
        try saveOrRollBack()
        return WorkerSnapshot(worker, configuration: nil)
    }

    /// Applies one edit. A `.manager` that would close a loop is refused
    /// before anything is written, so the hierarchy on disk is never a cycle,
    /// not even briefly.
    @discardableResult
    public func update(worker id: UUID, _ change: WorkerChange) throws -> WorkerSnapshot {
        guard let worker = try workerRow(id) else { throw WorkspaceStoreError.workerNotFound(id) }

        switch change {
        case .name(let value):         worker.name         = value
        case .role(let value):         worker.role         = value
        case .instructions(let value): worker.instructions = value
        case .appearance(let value):   worker.appearance   = value
        case .archived(let value):     worker.isArchived   = value

        case .manager(let value):
            if let value {
                guard try workerRow(value) != nil else {
                    throw WorkspaceStoreError.workerNotFound(value)
                }
                try refuseCycle(worker: id, under: value)
            }
            worker.managerID = value
        }

        try saveOrRollBack()
        return WorkerSnapshot(worker, configuration: try currentConfigurationRow(of: id))
    }

    /// Writes a new configuration version and returns its number. The previous
    /// versions stay: an execution already recorded keeps pointing at the one
    /// it ran with.
    @discardableResult
    public func configure(worker id: UUID, selection: ModelSelection) throws -> Int {
        guard try workerRow(id) != nil else { throw WorkspaceStoreError.workerNotFound(id) }
        let version = (try currentConfigurationRow(of: id)?.version ?? 0) + 1
        modelContext.insert(WorkerConfiguration(workerID: id, version: version, selection: selection))
        try saveOrRollBack()
        return version
    }

    /// Starts an attempt and freezes the settings into it.
    ///
    /// Throws `workerNotConfigured` when no model is attached: an execution
    /// with an invented configuration would be a lie about what ran.
    @discardableResult
    public func startExecution(
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
        return ExecutionSnapshot(execution)
    }

    public func execution(_ id: UUID) throws -> ExecutionSnapshot? {
        try first(Execution.self, where: #Predicate { $0.id == id }).map(ExecutionSnapshot.init)
    }

    // MARK: Hierarchy

    /// Throws when making `id` report to `manager` would close a loop.
    ///
    /// Walks up from the proposed manager. The step budget is the number of
    /// workers: a hierarchy without a cycle cannot be longer, and a store that
    /// somehow already holds one must not spin here.
    private func refuseCycle(worker id: UUID, under manager: UUID) throws {
        let budget = try modelContext.fetchCount(FetchDescriptor<Worker>())
        var cursor: UUID? = manager
        var steps  = 0

        while let current = cursor {
            if current == id {
                throw WorkspaceStoreError.cycleInHierarchy(workerID: id, managerID: manager)
            }
            steps += 1
            guard steps <= budget else {
                throw WorkspaceStoreError.cycleInHierarchy(workerID: id, managerID: manager)
            }
            cursor = try workerRow(current)?.managerID
        }
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
