//
//  FrameContentAge.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

/// ContentAgeDoubt is why the age of a Frame's content could not be established.
///
/// Every case is a refusal to convert, never a fallback. A callback instant, a
/// presentation timestamp and a WindowServer display time are three clocks, and
/// none of them becomes another one because the arithmetic would compile.
nonisolated public enum ContentAgeDoubt: String, Sendable, Equatable {

    /// No qualified oracle relates the sample's clock to the caller's. This is
    /// the shipped answer: the conversion is a native capability that has not
    /// been qualified, so the age stays unknown and the input is refused.
    case clockNotQualified

    /// The sample carried no timestamp attachment at all.
    case timestampMissing

    /// The attachment was present and not a usable number: not finite, not
    /// positive, or outside the range the conversion is defined on.
    case timestampMalformed

    /// The reading is in the future of the instant it is compared against, so
    /// the two values do not belong to one monotonic clock.
    case timestampNotMonotonic
}

/// FrameContentAge is how old the pixels of a Frame are at the moment the
/// question is asked, or why that is not known.
///
/// It is the age of the **content**, and it is deliberately not derivable from
/// the fact that a callback arrived: `receivedAt` says when the kit was handed
/// the sample, which is a fact about the delivery. An unknown age is a first
/// class answer and it refuses input exactly as an expired one does.
nonisolated public enum FrameContentAge: Sendable, Equatable {

    /// The age was measured through a qualified oracle, in nanoseconds.
    case qualified(nanoseconds: UInt64)

    /// The age is not known, with the reason it is not.
    case unknown(ContentAgeDoubt)

    /// The measured age, nil when it is unknown. Callers must treat nil as a
    /// refusal and never as zero.
    public var nanoseconds: UInt64? {
        guard case .qualified(let nanoseconds) = self else { return nil }
        return nanoseconds
    }

    public var isQualified: Bool { nanoseconds != nil }

    /// Whether this age is inside a finite positive limit. An unknown age is
    /// outside every limit, which is the whole point of the distinction.
    public func isWithin(limitNanoseconds: UInt64) -> Bool {
        guard let nanoseconds else { return false }
        return nanoseconds <= limitNanoseconds
    }

    /// Advances a measured age by the time that passed since it was taken, and
    /// leaves an unknown age unknown.
    ///
    /// The elapsed value is validated before it is added: a negative interval
    /// between two readings of one monotonic clock is a clock that is not
    /// monotonic, and adding it would silently make a stale Frame look fresh.
    public func advanced(byNanoseconds elapsed: Int64) -> FrameContentAge {
        guard case .qualified(let nanoseconds) = self else { return self }
        guard elapsed >= 0 else { return .unknown(.timestampNotMonotonic) }
        let (sum, overflowed) = nanoseconds.addingReportingOverflow(UInt64(elapsed))
        guard !overflowed else { return .unknown(.timestampMalformed) }
        return .qualified(nanoseconds: sum)
    }
}
