//
//  BrainStoring.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import EngineCore
import Foundation
import PerceptionCore

/// BrainRecordOutcome is what recording an action's effect did to the brain, as `BrainMemory`
/// decides it today: no effect teaches nothing, an element with no unambiguous anchor teaches
/// nothing unless it revealed a menu, in which case it is anchored first and the reveal recorded.
public enum BrainRecordOutcome: Sendable, Equatable {

    /// The record carried no effect.
    case noEffect

    /// The element matched no anchor, or an ambiguous pair, and the effect was not a menu reveal.
    case noAnchor

    /// The transition was recorded against this anchor, with this evidence after recording.
    case recorded(anchorKey: String, evidence: Int)
}

/// BrainReading is the read side of the stored brain: the active projection of an application, as
/// the seams that answer expectations and enrich scenes need it. A producer in the integration gets
/// this role and `BrainApplicationStoring`, never the raw mutations of `BrainStoring`.
public protocol BrainReading: Sendable {

    /// The active projection of an application's brain, or nil when the store has never seen the
    /// application. Read from one consistent snapshot.
    func brain(of bundleID: String) async throws -> UIBrain?
}

/// BrainStoring keeps one `UIBrain` per application as a stored projection and applies the brain's
/// own mutations to it. A conformer loads the active projection, runs the unchanged pure
/// algorithms (`BrainUpdater`) on it and writes the difference, all inside one serialized
/// transaction with the clock passed in as a value: no cache of a brain outlives the lock, no
/// mutation reads the wall, and no `await` sits between the load and the commit. Rows the algorithm
/// drops are retired with the algorithm's cause, never deleted; identities and orders are kept.
/// A mutation is applied each time it is asked for: the serialized load keeps two writers from
/// losing an update, it does not recognize the retry of one event, which `BrainApplicationStoring`
/// does; its mutations are for tests and low-level tools.
public protocol BrainStoring: BrainReading {

    /// Ingests detections as `BrainUpdater.ingest` does, scoped to a window family, at this clock.
    func ingest(
        _ detections: [BrainDetection],
        into bundleID: String,
        now         : Date,
        window      : String?
    ) async throws -> BrainUpdater.IngestStats

    /// Ingests a scene's elements, every one of them, scoped to the title's letter family as
    /// `BrainMemory.observe` scopes it: the empty family is no scope.
    func observe(_ scene: SceneSnapshot, now: Date) async throws -> BrainUpdater.IngestStats

    /// Records what an action taught, with `BrainMemory.record`'s rules, at this clock.
    func record(_ record: ActionRecord, now: Date) async throws -> BrainRecordOutcome

    /// Names an anchor deliberately as `BrainUpdater.setName` does; false when the anchor is unknown.
    func setName(_ name: String, anchorKey: String, in bundleID: String, now: Date) async throws -> Bool

    /// Runs `BrainUpdater.decay` on the projection and answers what it retired and why.
    func decay(
        in bundleID: String,
        now        : Date,
        maxObjects : Int,
        retention  : BrainRetention
    ) async throws -> DecayReport
}

/// BrainGraphStoring keeps what the brain knows beyond the compatible projection: the elements of
/// structural scenes and their links to anchors, the general arcs (`BrainArc`) and the evidence
/// rows any part of the brain may have. It learns nothing: every arc, link and evidence is given.
/// The projection (`BrainStoring`) never reads, changes or retires what this role writes.
public protocol BrainGraphStoring: Sendable {

    /// The elements of a structural scene, by id.
    func elements(ofScene sceneID: String) async throws -> [SceneElementRecord]

    /// Links a scene element to an anchor of its application, once: the same anchor again is
    /// `alreadyApplied`, another is a conflict.
    func link(element sceneElementID: String, toAnchor anchorID: String) async throws -> MemoryReceipt

    /// Records a general arc once by its id, at the application's next insertion order.
    func record(_ arc: BrainArc) async throws -> MemoryReceipt

    /// Changes an arc's status, count, last sighting and epoch against the arc last read.
    func update(from expected: BrainArc, to updated: BrainArc) async throws -> MemoryReceipt

    func arc(_ transitionID: String) async throws -> BrainArc?

    /// The application's active general arcs, in insertion order; never the projection's transitions.
    func arcs(of bundleID: String) async throws -> [BrainArc]

    /// Records evidence once by (target, event, relation).
    func record(_ evidence: BrainEvidenceRecord) async throws -> MemoryReceipt

    /// The evidence rows naming an event, the projection's applications' included, by id.
    func evidence(ofEvent eventID: String) async throws -> [BrainEvidenceRecord]

    func overview() async throws -> MemoryOverview
}
