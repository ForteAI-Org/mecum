//
//  ObservationKind.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

/// ObservationKind is the registry of the row shapes `memory_event_observations` may hold, each
/// with the contract version this build reads and writes. The registry is closed on purpose: a code
/// or a version it does not list is refused on the way in and on the way out, never mapped to a
/// known kind by default. A later shape is an explicit extension of this registry with its own
/// decoder, not a new string accepted as text.
///
/// Version 1 of every kind is the shape documented in `Documentation/Engine/MemorySchema.md`:
/// which columns a row of that kind must carry, which it must leave NULL, and how it relates to its
/// parent sample.
public enum ObservationKind: String, Sendable, Equatable, Hashable, CaseIterable {

    /// One sample: the capture of one surface, identified by its event, phase and ordinal. Its
    /// status is the capture's completeness, its quality facts are `captureField` children and
    /// its structural elements are `element` children.
    case capture

    /// One quality fact of its parent sample, named by `CaptureField`, with exactly one typed value
    /// when observed and none when not.
    case captureField = "capture_field"

    /// One structural element its parent sample saw: role, label with its origin, structural path.
    case element

    /// The contract version this build writes for every kind, and the only one it reads.
    public static let contractVersion: Int = 1

    /// The versions each kind is readable at in this build.
    public var supportedVersions: Set<Int> { [Self.contractVersion] }

    /// The kind a stored code names at a stored version, or the refusal: an unknown code, or a
    /// version this build has no decoder for.
    public static func resolve(code: String, version: Int) throws -> ObservationKind {
        guard let kind = ObservationKind(rawValue: code) else {
            throw ObservationContractError.unknownObservationKind(code)
        }
        guard kind.supportedVersions.contains(version) else {
            throw ObservationContractError.unsupportedContractVersion(kind: code, version: version)
        }
        return kind
    }
}

/// ObservationStatus is the status vocabulary of the rows that are not samples: a quality field or
/// an element was `observed`, or a quality field was `notObserved` because the producer could not
/// know it. It is distinct from a sample's status, which is its completeness
/// (`CaptureQuality.Completeness`), so a child row can never be mistaken for a sample.
public enum ObservationStatus: String, Sendable, Equatable, Hashable, CaseIterable {

    case observed
    case notObserved = "not_observed"
}

/// CaptureField names the quality facts a sample stores as `captureField` children, one row each,
/// and the storage class every fact must use. Every field of version 1 is written for every sample:
/// with its value when the producer observed it, as `notObserved` without a value when it did not,
/// so a reader can tell "unknown" from "missing row".
public enum CaptureField: String, Sendable, Equatable, Hashable, CaseIterable {

    case walkCompleted   = "walk_completed"
    case stoppedBy       = "stopped_by"
    case windowFound     = "window_found"
    case grantAvailable  = "grant_available"
    case windowRole      = "window_role"
    case windowSubrole   = "window_subrole"
    case nodesVisited    = "nodes_visited"
    case elementsEmitted = "elements_emitted"

    /// ValueKind is the one storage column a field's value lives in.
    public enum ValueKind: Sendable, Equatable {
        case boolean, text, integer
    }

    public var valueKind: ValueKind {
        switch self {
            case .walkCompleted, .windowFound, .grantAvailable: .boolean
            case .stoppedBy, .windowRole, .windowSubrole      : .text
            case .nodesVisited, .elementsEmitted              : .integer
        }
    }
}

/// CaptureFieldValue is one quality fact as it crosses the storage boundary: typed, or absent.
public enum CaptureFieldValue: Sendable, Equatable, Hashable {

    case boolean(Bool)
    case text(String)
    case integer(Int64)
    case notObserved
}
