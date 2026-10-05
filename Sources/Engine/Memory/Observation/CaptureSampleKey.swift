//
//  CaptureSampleKey.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

/// CapturePhase is when, relative to its event, a capture was taken: before the gesture, of the
/// menu it opened, after it, or the current state an observation describes on its own. A menu
/// capture is kept as a sample but never associated with a scene: an open menu is not a surface
/// of the application's structure.
public enum CapturePhase: String, Sendable, Equatable, Hashable, CaseIterable {

    case before
    case menu
    case after
    case current

    /// Whether a sample of this phase may be associated with a structural scene.
    public var isAssociable: Bool { self != .menu }
}

/// CaptureSampleKey is the identity of one sample: the event it belongs to, the phase it was taken
/// in and its ordinal within that phase. Ordinal 0 is the primary sample, the perception the engine
/// actually used in that phase; a re-capture in the same phase takes the next ordinal and is a
/// different sample. Two offers under one key with different content are a conflict, never a
/// second row.
///
/// Two keys are one only when their event ids are the same bytes and their phase and ordinal
/// match: the identity the file's binary TEXT keys hold. Swift's own `String` equality would make
/// two canonically equivalent ids, two events in the file, one key here; the id is never
/// normalized, so the key's equality and hashing read its UTF-8.
public struct CaptureSampleKey: Sendable, Equatable, Hashable {

    public let eventID: String
    public let phase: CapturePhase
    public let ordinal: Int

    public init(eventID: String, phase: CapturePhase, ordinal: Int = 0) {
        self.eventID = eventID
        self.phase   = phase
        self.ordinal = ordinal
    }

    public static func == (lhs: CaptureSampleKey, rhs: CaptureSampleKey) -> Bool {
        lhs.phase == rhs.phase && lhs.ordinal == rhs.ordinal && lhs.eventID.utf8.elementsEqual(rhs.eventID.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(phase)
        hasher.combine(ordinal)
        hasher.combine(eventID.utf8.count)
        for byte in eventID.utf8 { hasher.combine(byte) }
    }

    /// Whether this is the primary sample of its phase.
    public var isPrimary: Bool { ordinal == 0 }
}
