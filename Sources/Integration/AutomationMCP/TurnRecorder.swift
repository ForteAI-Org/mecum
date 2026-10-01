//
//  TurnRecorder.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import Foundation
import Memory

/// TurnRecorder is the consumer side of learning: it writes the one event a `TurnLedger.Report`
/// yields to the living memory, and says what happened. The rules stay in `TurnAdmission` and the
/// store's `ExperienceEventRule`; this type only delivers and reports.
///
/// The application effect and the memory write are separate results. A write that fails leaves the
/// action's outcome as the tools already reported it: nothing is repeated, no memory success is
/// claimed, and the error is returned to the caller to show. Each report writes under its own
/// idempotency key and end time, so delivering the same report again is a no-op.
public struct TurnRecorder: Sendable {

    private let store: any LivingMemoryStoring

    public init(store: any LivingMemoryStoring) {
        self.store = store
    }

    /// Outcome is what recording one report did.
    public enum Outcome: Sendable, Equatable {
        /// The event was written, or was already written; the experience it belongs to, if any.
        case recorded(ExperienceRecording, TurnAdmission.Reason)
        /// The decision records nothing.
        case nothingToRecord(TurnAdmission.Reason)
        /// The store failed. The action's own outcome stands; the memory did not change.
        case failed(TurnAdmission.Reason, error: String)

        /// One line for the person at the terminal, or nil for a turn without any selection. A turn
        /// whose selection was not learned says why, so a missing memory is never silent.
        public var notice: String? {
            switch self {
                case .recorded(.applied(let record?), let reason) where reason.verifiesStep,
                     .recorded(.duplicate(let record?), let reason) where reason.verifiesStep:
                    "memory: remembered \(record.step.summary), verified ×\(record.successCount)"
                case .recorded(.applied(let record?), .contradictsFollowedExperience),
                     .recorded(.duplicate(let record?), .contradictsFollowedExperience):
                    "memory: \(record.step.summary) did not hold this time; the memory now counts "
                        + "×\(record.successCount) verified, ×\(record.failureCount) contradicted"
                case .recorded(_, .noSelection), .nothingToRecord(.noSelection):
                    nil
                case .recorded(_, let reason), .nothingToRecord(let reason):
                    "memory: nothing learned from this turn (\(reason.rawValue))"
                case .failed(_, let error):
                    "memory: this turn's result could not be saved (\(error)). The action's outcome above "
                        + "stands and nothing was repeated."
            }
        }
    }

    /// Records one ended turn.
    public func record(_ report: TurnLedger.Report) async -> Outcome {
        let reason = report.decision.reason
        guard let event = report.event else { return .nothingToRecord(reason) }
        do {
            return .recorded(try await store.record(event), reason)
        } catch {
            return .failed(reason, error: String(describing: error))
        }
    }
}
