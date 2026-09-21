//
//  MonitorPresentation.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

/// MonitorPresentation is what is actually on the Monitor's layers right now,
/// and how much is known about when it was true.
///
/// ## Why the last image may stay and must be marked
///
/// A `CALayer` keeps whatever was assigned to `contents`, so a Monitor whose
/// capture stopped goes on showing its last frame. Blanking it would hide the
/// fact that the preview stopped; presenting it as live would be worse. The
/// contract is therefore that it may stay **only** while it is marked stale, and
/// this value is the mark.
///
/// ## Two different times, and one of them is often unknown
///
/// `receivedAtNanoseconds` is when the kit's callback was handed the sample, on
/// the `mach_absolute_time` clock. It is a fact about delivery and it is not the
/// instant the pixels were visible. `displayTime` is the WindowServer display
/// time attachment, which ScreenCaptureKit may omit; when it is nil the visual
/// instant is **unknown** and is never substituted by the callback time. Neither
/// of them is the age of the agent's observation, which has its own oracle and
/// its own refusal.
nonisolated public struct MonitorPresentation: Sendable, Equatable {

    /// True while the capture is running and frames are arriving.
    public let isLive: Bool

    /// True once any frame has been presented, so an empty layer is told apart
    /// from one holding an old picture.
    public let hasImage: Bool

    /// When the callback delivered the presented sample, in `mach_absolute_time`
    /// ticks, nil when nothing has been presented.
    public let receivedAtNanoseconds: UInt64?

    /// The WindowServer display time of the presented sample, nil when the
    /// attachment was absent. Nil means the visual instant is unknown.
    public let displayTime: UInt64?

    /// True when an image is being shown and the capture is not live. A consumer
    /// showing this must say so to the person.
    public var lastImageIsStale: Bool { hasImage && !isLive }

    /// True when nothing establishes when the presented pixels were visible.
    public var visualTimeIsUnknown: Bool { displayTime == nil }

    public init(
        isLive               : Bool,
        hasImage             : Bool,
        receivedAtNanoseconds: UInt64?,
        displayTime          : UInt64?
    ) {
        self.isLive                = isLive
        self.hasImage              = hasImage
        self.receivedAtNanoseconds = receivedAtNanoseconds
        self.displayTime           = displayTime
    }

    /// The presentation of a Monitor that has never shown anything.
    public static let nothingPresented = MonitorPresentation(
        isLive               : false,
        hasImage             : false,
        receivedAtNanoseconds: nil,
        displayTime          : nil
    )
}
