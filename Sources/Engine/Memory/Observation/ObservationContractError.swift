//
//  ObservationContractError.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

import PerceptionCore

/// ObservationContractError is what the observation contract answers when a record offered to it
/// or read back from a store does not have a shape this build knows. Every case is a refusal: no
/// code is mapped to a default, no malformed row is read as a lesser row, and nothing is written
/// when the refusal is met on the way in. The cases carry identifiers and column names, never the
/// content of a label or a title.
public enum ObservationContractError: Error, Sendable, Equatable {

    /// `observation_kind` holds a code the registry does not list.
    case unknownObservationKind(String)

    /// A known kind at a version this build has no decoder for.
    case unsupportedContractVersion(kind: String, version: Int)

    /// A status outside the vocabulary of its row's kind.
    case unknownStatus(kind: ObservationKind, status: String)

    /// A closed vocabulary met a value it does not list.
    case unknownCaptureField(String)
    case unknownStopReason(String)
    case unknownSurface(String)
    case unknownLabelOrigin(String)
    case unknownElementKind(String)
    case unknownPhase(String)
    case unknownControlState(String)
    case unknownEventSource(String)
    case unknownEventKind(String)
    case unknownCaptureStatus(String)
    case unknownSceneKind(String)
    case unknownMatchStatus(String)

    /// A stored row has the right kind and version and still breaks the kind's shape.
    case malformedObservation(observationID: Int64, malformation: Malformation)

    /// A stored scene element breaks the structural shape.
    case malformedSceneElement(sceneElementID: String, malformation: Malformation)

    /// A sample was offered for an event the store does not hold.
    case missingEvent(eventID: String)

    /// A sample was asked to associate with scenes, but its event names no application.
    case eventWithoutApp(eventID: String)

    /// An association was asked for a sample the store does not hold.
    case missingSample(CaptureSampleKey)

    /// A record was refused before any transaction began.
    case invalidRecord(Invalidity)

    /// Malformation says which shape rule a stored row breaks.
    public enum Malformation: Sendable, Equatable {

        /// A child row's phase or ordinal differs from its parent sample's.
        case parentMismatch

        /// A child row's parent is not a sample row.
        case nestedUnderChild

        /// A child row without a parent.
        case orphanChild

        /// A sample's status disagrees with the completeness its quality fields add up to.
        case statusContradictsFields

        /// An observed field without its value, or an element without a required column.
        case missingColumn(String)

        /// A column this kind must leave NULL holds a value.
        case forbiddenColumn(String)

        /// A field's value sits in a column of the wrong storage class.
        case valueKindMismatch(String)

        /// The same quality field twice under one sample.
        case duplicateField(String)

        /// Rows of one collection group disagree on their structural path.
        case collectionGroupInconsistent(Int64)

        /// A control row with no role, or a container row with no path.
        case missingRole

        /// A sample's quality fields contradict each other.
        case inconsistentQuality(CaptureQuality.Inconsistency)

        /// An element's bounds hold a value that is not a finite number.
        case nonFiniteBounds
    }

    /// Invalidity says why a record was refused before being written.
    public enum Invalidity: Sendable, Equatable {

        case emptyEventID
        case emptyStreamID
        case emptyBundleID
        case negativeOrdinal
        case emptyLabel
        case emptyRole
        case parentWithoutPosition

        /// An origin on an event that is not an observation: only a session's own observation
        /// names the call it was taken for.
        case originOnNonObservation

        /// An origin that is empty or the event itself.
        case originIsSelf

        /// The sample's quality facts contradict each other: nothing is written for a read that
        /// cannot have happened.
        case inconsistentQuality(CaptureQuality.Inconsistency)

        /// An element's bounds hold NaN or an infinity: the file would keep NULL or an infinity for
        /// it, and no reader could rebuild the geometry.
        case nonFiniteBounds
    }
}
