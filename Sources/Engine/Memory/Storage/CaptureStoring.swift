//
//  CaptureStoring.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

/// CaptureStoring persists the facts of the living memory's observation side: events and the
/// samples taken for them. A conformer writes a record whole or not at all, answers a receipt only
/// after the commit, treats the same identity with the same content as already applied and the
/// same identity with other content as a conflict, and reads back exactly what it stored, refusing
/// a stored row whose shape this build does not know rather than reading it as something lesser.
///
/// Identities and application contexts are explicit: a conformer never invents an event for a
/// sample, never guesses an application from a title, and never records a sample for an event it
/// does not hold.
public protocol CaptureStoring: Sendable {

    /// Records an event. Its application and context are found or created in the same transaction.
    func record(_ event: MemoryEventRecord) async throws -> MemoryReceipt

    /// Records a sample, its quality fields and its elements together, for an event already stored.
    func record(_ sample: CaptureSample) async throws -> MemoryReceipt

    /// The stored event, or nil when none has this identity.
    func event(_ eventID: String) async throws -> MemoryEventRecord?

    /// The stored sample with its fields and elements, or nil when none has this identity.
    func sample(_ key: CaptureSampleKey) async throws -> CaptureSample?
}
