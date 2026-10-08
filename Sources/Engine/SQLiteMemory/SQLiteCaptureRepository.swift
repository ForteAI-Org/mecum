//
//  SQLiteCaptureRepository.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

import Foundation
import Memory

/// SQLiteCaptureRepository is `CaptureStoring` over `SQLiteMemoryStore`: events into
/// `memory_events` with their application and context found or created beside them, samples into
/// `memory_event_observations` as one capture row, eight quality fields and the elements, all in
/// one write transaction. A write answers after its commit and holds its work through contention
/// as the store does; a body that refuses rolls everything back, so no sample is ever half stored.
///
/// Idempotency is decided inside the transaction by identity: an event by its id, or by its
/// source's own key; a sample by (event, phase, ordinal). The content is compared typed and exact
/// (`hasSameImmutableContent(as:)` for an event, `==` for a sample): NULL is not empty text, a
/// bound is the number it is, and a separator inside a value is content. The same content answers
/// `alreadyApplied` and moves no count; other content under the same identity is
/// `MemoryStoreError.identity`, with two digests for the report and nothing written. A sample for
/// an event the store does not hold is refused: no event is invented for it.
public struct SQLiteCaptureRepository: CaptureStoring {

    private let store: SQLiteMemoryStore

    public init(store: SQLiteMemoryStore) {
        self.store = store
    }

    public func record(_ event: MemoryEventRecord) async throws -> MemoryReceipt {
        try event.validate()
        return try await store.write { transaction in try SQLiteEventRows.record(transaction, event) }
    }

    public func record(_ sample: CaptureSample) async throws -> MemoryReceipt {
        try sample.validate()
        return try await store.write { transaction in
            guard try SQLiteEventRows.appID(transaction, eventID: sample.key.eventID) != nil else {
                throw ObservationContractError.missingEvent(eventID: sample.key.eventID)
            }
            if let stored = try SQLiteObservationRows.sample(transaction, key: sample.key) {
                guard stored == sample else {
                    throw MemoryStoreError.identity(MemoryIdentityConflict(
                        identity          : "\(sample.key.eventID):\(sample.key.phase.rawValue):\(sample.key.ordinal)",
                        storedFingerprint : stored.fingerprint,
                        offeredFingerprint: sample.fingerprint
                    ))
                }
                return .alreadyApplied
            }
            try SQLiteObservationRows.insert(transaction, sample)
            try SQLiteEventRows.refreshCaptureStatus(transaction, eventID: sample.key.eventID)
            return .committed
        }
    }

    public func event(_ eventID: String) async throws -> MemoryEventRecord? {
        try await store.read { snapshot in try SQLiteEventRows.read(snapshot, eventID: eventID) }
    }

    public func sample(_ key: CaptureSampleKey) async throws -> CaptureSample? {
        try await store.read { snapshot in try SQLiteObservationRows.sample(snapshot, key: key) }
    }
}
