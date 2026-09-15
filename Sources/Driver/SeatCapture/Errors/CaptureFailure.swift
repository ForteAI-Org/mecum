//
//  CaptureFailure.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import Foundation
import SeatCore

/// CaptureStep names the ScreenCaptureKit call that did not answer, so a
/// timeout says which one instead of carrying a sentence.
///
/// The list exists because more than one of these calls has been observed not
/// to call back at all: the Ledger records `SCScreenshotManager` completion
/// handlers that never arrive, and `SCShareableContent` is the first call a
/// missing Screen Recording grant blocks. Every one of them is therefore
/// wrapped in a gate with a deadline, and the deadline reports the step.
nonisolated public enum CaptureStep: Sendable, Equatable {

    /// `SCShareableContent.getExcludingDesktopWindows`.
    case shareableContent

    /// `SCScreenshotManager.captureSampleBuffer`, the one-shot Still.
    case still

    /// `SCStream.startCapture`.
    case streamStart

    /// `SCStream.stopCapture`.
    case streamStop

    /// `SCStream.updateConfiguration`, the quality change.
    case configurationUpdate

}

/// CaptureFailure is everything the Capture Facility refuses: listing what can
/// be shared, starting a stream on the Virtual Display or on an Adopted Window,
/// taking a Still, changing quality.
///
/// It carries fields, never prose, like every other Facility error in the kit:
/// the consumer writes the sentence and a report reads the codes. An underlying
/// `NSError` is reduced to its domain and code for the same reason, and because
/// an `Error` payload would make the whole type unequatable and untestable.
nonisolated public enum CaptureFailure: Error, Sendable, Equatable {

    /// A call did not come back inside its deadline. The step says which one.
    case timedOut(CaptureStep)

    /// The bounded process-wide framework coordinator has no admission or
    /// waiter capacity for this request. The named step was never admitted by
    /// this refusal.
    case frameworkCallLimitReached(CaptureStep)

    /// This stream already has one configuration mutation awaiting its real
    /// framework callback. A second, potentially out-of-order mutation is not
    /// sent.
    case configurationUpdateInProgress

    /// A configuration callback arrived only after every valid waiter was
    /// retired. The stream is stopped because its applied configuration can no
    /// longer be reported as the caller's fresh result.
    case configurationStateUnknown

    /// Screen Recording is not granted. The kit never prompts on its own:
    /// `Permissions.request(.screenRecording)` is the consumer's call.
    case screenRecordingPermissionMissing

    /// The Virtual Display is not in `SCShareableContent.displays`. It happens
    /// while the display is still being published, which is why the caller
    /// waits for the `NSScreen` before starting a Monitor (ADR 0007).
    case displayNotShareable(CGDirectDisplayID)

    /// The Adopted Window is not in `SCShareableContent.windows`, so either it
    /// is gone or it is off screen.
    case windowNotShareable(windowNumber: Int)

    /// The Window ID no longer belongs to the attested process lifetime and
    /// owner connection. A replacement is never stamped with the old identity.
    case windowIdentityChanged(expected: WindowIdentity, observed: WindowIdentity?)

    /// `start` was called on a stream that is already running. There is no
    /// implicit restart: the resource costs, and a second start would leave the
    /// first stream running with nobody owning it.
    case alreadyStarted

    /// A quality change or a Still was asked of a stream that was never
    /// started.
    case notStarted

    /// The sample buffer carried no image buffer, no `IOSurface`, or no complete
    /// geometry attachments. The sample cannot become a trustworthy frame and
    /// is never retried.
    case frameUnavailable

    /// ScreenCaptureKit refused, with the domain and code of its own error.
    case captureFailed(domain: String, code: Int)

    /// The requested frame rate needs a display that cannot deliver it: the 120
    /// level requires a 120 Hz display, and asking for it on a 60 Hz one would
    /// measure 60 and call it 120.
    case frameRateUnsupported(requested: Int, displayRefreshRate: Double)
}

nonisolated extension CaptureFailure {

    /// Reduces any error ScreenCaptureKit hands back to the two fields a report
    /// needs, and keeps a `CaptureFailure` that came from the kit itself
    /// unchanged so a timeout does not turn into a domain and a code.
    static func wrapping(_ error: any Error) -> CaptureFailure {
        if let failure = error as? CaptureFailure { return failure }
        let nsError = error as NSError
        return .captureFailed(domain: nsError.domain, code: nsError.code)
    }
}
