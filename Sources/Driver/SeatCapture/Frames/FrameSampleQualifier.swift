//
//  FrameSampleQualifier.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import SeatCore

/// QualifiedFrameSample is one sample that passed the whole qualification: the
/// Frame itself, the window geometry its attachments support, and the age of its
/// content.
///
/// It is produced only by `FrameSampleQualifier`. There is no initializer that
/// takes a verdict as a parameter, because a value that could be constructed
/// with `sufficient` written into it would be evidence the caller granted
/// itself.
nonisolated public struct QualifiedFrameSample: Sendable {

    public let frame     : SeatFrame
    public let geometry  : WindowGeometryObservation
    public let contentAge: FrameContentAge

    fileprivate init(
        frame     : SeatFrame,
        geometry  : WindowGeometryObservation,
        contentAge: FrameContentAge
    ) {
        self.frame      = frame
        self.geometry   = geometry
        self.contentAge = contentAge
    }
}

/// FrameSampleQualifier applies one uniform standard to a delivered sample,
/// whether it came from a running stream or from a one shot Still.
///
/// ## Why it is uniform
///
/// The stream path verified completeness and identity in its receiver while the
/// Still path built a `SeatFrame` directly from a successful callback, so the
/// two answered different questions and only one of them was a qualification. A
/// successful callback is not evidence about pixels; this type is the single
/// place that decides, and both paths go through it.
///
/// ## What it refuses to infer
///
/// It does not read the pixels: a black window is a legitimate picture, and no
/// colour test separates it from a blank surface, so colour decides nothing
/// here. It does not treat the arrival of a callback as freshness. It does not
/// accept a geometry that a coordinate transform is undefined on, and it does
/// not accept a reconstructed geometry that is not correlated with the requested
/// window: a sample of a display, or of a compatibility Window ID with no
/// attested lifetime, is absent evidence for a window observation.
nonisolated public struct FrameSampleQualifier: Sendable {

    private let clock: any ContentClockQualifying

    /// Borrows the clock oracle for the lifetime of the qualifier. The shipped
    /// one is `UnqualifiedContentClock`, so an unqualified deployment produces
    /// absent evidence instead of a fabricated age.
    public init(clock: any ContentClockQualifying = UnqualifiedContentClock()) {
        self.clock = clock
    }

    /// True when the clock this qualifier was composed with can measure content
    /// age at all, reported apart from any single sample's verdict.
    public var hasQualifiedContentClock: Bool { clock.isQualified }

    /// Qualifies one sample as an observation of `expected`, or answers what is
    /// missing or wrong with it.
    ///
    /// The checks run in the order a wrong answer would be most misleading:
    /// provenance and identity first, then the geometry a coordinate transform
    /// needs, then the age. `now` is the caller's monotonic reading taken around
    /// the delivery, and it is passed in rather than read here so that the whole
    /// verdict belongs to one instant.
    public func qualify(
        _ frame         : SeatFrame,
        of expected     : WindowIdentity,
        atNanoseconds now: UInt64
    ) -> Result<QualifiedFrameSample, ObservedSampleEvidence> {

        switch frame.source {
            case .display:
                return .failure(.absent(.identityNotAttested))
            case .unverifiedWindow:
                return .failure(.absent(.identityNotAttested))
            case .window(let identity):
                guard identity == expected else { return .failure(.invalid(.identityMismatch)) }
        }

        guard frame.geometry.isValid else { return .failure(.invalid(.geometryMalformed)) }
        guard frame.geometry.capturesFullWindow else {
            return .failure(.absent(.geometryMissing))
        }
        guard let observation = frame.geometry.windowObservation else {
            return .failure(.invalid(.geometryNotUniform))
        }

        let age = clock.contentAge(of: frame, atNanoseconds: now)
        if case .unknown(let doubt) = age {
            switch doubt {
                case .clockNotQualified, .timestampMissing:
                    return .failure(.absent(.contentClockNotQualified))
                case .timestampMalformed, .timestampNotMonotonic:
                    return .failure(.invalid(.timestampsInconsistent))
            }
        }
        return .success(
            QualifiedFrameSample(frame: frame, geometry: observation, contentAge: age)
        )
    }
}
