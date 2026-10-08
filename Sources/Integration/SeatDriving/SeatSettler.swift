//
//  SeatSettler.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/10/2026.
//

import EngineCore
import Foundation
#if MECUM_PHASES
import PhaseSignposts
#endif
import SeatCapture
import SeatCore
import SeatSession

/// SeatSettler is `Settling` over the running stream of the window the seat targets: the wait after
/// a gesture ends once that window's frames have stopped changing, and never later than the cap.
///
/// ## Settled
///
/// Consecutive frames displayed after the wait began are compared with
/// `SeatFrame.showsSameContent(as:)`, byte for byte. The window is settled once its frames have
/// stayed identical for `stabilityInterval` after the last one that changed. When no frame changes
/// at all it waits the whole cap, the engine's fixed pause: an action whose effect is a new window
/// (a dialog, a sheet, a panel) leaves the target's pixels alone, so silence is not a verdict.
///
/// ## The baseline
///
/// An application that redraws within a few milliseconds of the input has already drawn its effect
/// in the first frame the wait sees, so comparing frames with each other alone reads "no change".
/// `prepare`, which the engine calls right before it delivers a gesture, copies the newest frame
/// of the target window out of the stream's pool. The first frame after the gesture is compared
/// with that copy, so an effect drawn at once counts as the change it is. The copy is used only
/// when it is of the window being settled, was displayed before it was taken, and is younger than
/// `baselineLifetime`; otherwise the wait runs as if there were none. A baseline serves one wait.
///
/// ## When it cannot tell
///
/// With no running stream (a target nobody streams, as on the command line), a stream pinned to
/// the display, recovering or on another window, or a frame it cannot place in time, it waits out
/// the rest of the cap: the fixed pause exactly when the source declines at once.
///
/// ## What it does not see
///
/// Only the target window: a menu or a panel that opens as a window of its own after the target
/// settled is not waited for. The scene an action answers is still taken after this returns,
/// through a new observation, so it is never older than the settle (ADR 0035).
///
/// It reads the frames observation reads, one wait after the other: the act cycle settles and then
/// observes, never both at once. It holds one frame at a time, which keeps one of the stream's pool
/// surfaces for one frame interval.
public struct SeatSettler: Settling {

    /// How long the window's frames must stay byte-identical to count as settled: three frame
    /// intervals of the 30 fps window stream, so a second repaint within two frames of the first
    /// (a highlight, then the content under it) is still waited for. Three intervals read off display
    /// times come to 99.99 ms, so the figure is 90 ms rather than 100, or it would take four.
    package static let stabilityInterval: Duration = .milliseconds(90)

    /// How long `prepare` waits for a frame to copy when the stream has shown none yet. A stream
    /// that delivers about 30 frames a second always has a newest one, which answers at once.
    package static let baselineBound: Duration = .milliseconds(50)

    /// How old a baseline may be when the wait starts: it belongs to the gesture just delivered,
    /// not to one whose wait never came (a refused or failed delivery, a contextual menu).
    package static let baselineLifetime: Duration = .seconds(2)

    /// How a wait ended, which the phase build reports as the detail of `settle`.
    package enum Ending: Equatable, Sendable {

        /// Frames changed, then stayed identical for the stability interval.
        case stable

        /// The first frame after the gesture already differed from the baseline taken before it,
        /// then frames stayed identical for the stability interval.
        case stableAgainstBaseline

        /// No frame changed, and the whole cap was waited.
        case quiet

        /// Frames were still changing, or still on their way, when the cap came.
        case cap

        /// There were no frames to watch, and the rest of the cap was waited out.
        case fallback(LiveFrameFallback)
    }

    /// What `prepare` copied before a gesture: the window's frame, as displayed at `displayedAt`,
    /// copied at `markedAt`, both uptime nanoseconds.
    package struct Baseline: Sendable {
        package let frame      : SeatFrame
        package let identity   : WindowIdentity
        package let displayedAt: UInt64
        package let markedAt   : UInt64

        package init(frame: SeatFrame, identity: WindowIdentity, displayedAt: UInt64, markedAt: UInt64) {
            self.frame       = frame
            self.identity    = identity
            self.displayedAt = displayedAt
            self.markedAt    = markedAt
        }
    }

    /// Holds the baseline between `prepare` and the next wait, on the main actor the target is on.
    @MainActor
    private final class Mark {
        var baseline: Baseline?
    }

    private let target: SeatTarget
    private let sleep : @Sendable (Duration) async -> Void
    private let mark  = Mark()

    public init(target: SeatTarget) {
        self.init(target: target, sleep: { try? await Task.sleep(for: $0) })
    }

    /// `sleep` is how a fallback waits, so a test can record it instead of sleeping.
    package init(target: SeatTarget, sleep: @escaping @Sendable (Duration) async -> Void) {
        self.target = target
        self.sleep  = sleep
    }

    /// Copies the target window's newest frame as the baseline of the wait that follows the gesture.
    public func prepare(in processID: pid_t) async {
        #if MECUM_PHASES
        let phase = PhaseInterval.begin("settle.prepare")
        defer { phase.end() }
        #endif
        await prepared()
    }

    /// Replaces the baseline with a copy of the newest frame of the target window, or with none
    /// when there is no stream, no frame in `baselineBound`, or no copy to make.
    @MainActor
    package func prepared() async {
        mark.baseline = nil
        guard let liveFrames = target.liveFrames,
              let identity = (try? target.currentWindow())?.reference.identity,
              case .success(let frame) = await liveFrames.liveFrame(
                  of            : identity,
                  displayedAfter: 0,
                  within        : Self.baselineBound
              ),
              let displayedAt = frame.displayTime.flatMap({
                  MachAbsoluteContentClock().displayTimeNanoseconds(fromMachTicks: $0)
              }),
              let copy = frame.detachedCopy()
        else { return }
        mark.baseline = Baseline(
            frame      : copy,
            identity   : identity,
            displayedAt: displayedAt,
            markedAt   : DispatchTime.now().uptimeNanoseconds
        )
    }

    /// `processID` is not read: the seat drives one window, the one it targets.
    public func settle(in processID: pid_t, cap: Duration) async {
        #if MECUM_PHASES
        let phase = PhaseInterval.begin("settle")
        let ending = await settled(cap: cap)
        phase.end(ending.detail)
        #else
        _ = await settled(cap: cap)
        #endif
    }

    @MainActor
    package func settled(cap: Duration) async -> Ending {
        let baseline = mark.baseline
        mark.baseline = nil
        // A target with no window to name (stopped, not adopted) has nothing to watch: the fixed pause.
        guard let liveFrames = target.liveFrames,
              let identity = (try? target.currentWindow())?.reference.identity
        else {
            await sleep(cap)
            return .fallback(.notLive)
        }
        let clock = MachAbsoluteContentClock()
        return await Self.wait(
            cap        : cap,
            baseline   : Self.reference(
                baseline,
                for      : identity,
                startedAt: DispatchTime.now().uptimeNanoseconds
            ),
            next       : { after, bound in
                await liveFrames.liveFrame(of: identity, displayedAfter: after, within: bound)
            },
            displayedAt: { frame in frame.displayTime.flatMap { clock.displayTimeNanoseconds(fromMachTicks: $0) } },
            now        : { DispatchTime.now().uptimeNanoseconds },
            sleep      : sleep
        )
    }

    /// The frame of `baseline` to compare the first frame with, or nil when it may not be used: it
    /// is of another window, was displayed after it was copied, or is older than the lifetime.
    package static func reference(
        _ baseline  : Baseline?,
        for identity: WindowIdentity,
        startedAt   : UInt64
    ) -> SeatFrame? {
        guard let baseline,
              baseline.identity == identity,
              case .window(let source) = baseline.frame.source, source == identity,
              baseline.displayedAt <= baseline.markedAt,
              startedAt >= baseline.markedAt,
              startedAt - baseline.markedAt <= nanoseconds(baselineLifetime)
        else { return nil }
        return baseline.frame
    }

    /// Waits for the frames `next` answers to settle, on the uptime clock `now` reads in nanoseconds.
    ///
    /// With a `baseline`, the first frame is compared with it as later ones are with their
    /// predecessor, so a change already drawn in that frame counts and ends `stableAgainstBaseline`.
    /// Without one the first frame is only the reference, as before.
    ///
    /// `next` answers the first frame displayed after an instant within a bound, as
    /// `LiveWindowFrameSourcing` does, and `displayedAt` places a frame on the same clock. A frame
    /// is never asked for past the cap. A refusal waits out the rest of the cap with `sleep`; a
    /// frame wait that ran to the cap after frames had arrived is the cap (`quiet` if none changed).
    @MainActor
    package static func wait(
        cap        : Duration,
        baseline   : SeatFrame? = nil,
        next       : (_ displayedAfter: UInt64, _ within: Duration) async -> Result<SeatFrame, LiveFrameFallback>,
        displayedAt: (SeatFrame) -> UInt64?,
        now        : () -> UInt64,
        sleep      : (Duration) async -> Void
    ) async -> Ending {

        let start     = now()
        let deadline  = start &+ nanoseconds(cap)
        let stability = nanoseconds(stabilityInterval)
        var after     = start
        var runStart  = start
        var changed   = false
        var previous  : SeatFrame? = baseline
        var hasFrames = false
        var changeWasAgainstBaseline = false

        while true {
            let current = now()
            guard current < deadline else { return changed ? .cap : .quiet }
            let result = await next(after, .nanoseconds(deadline - current))
            guard case .success(let frame) = result, let displayed = displayedAt(frame), displayed > after else {
                let reason: LiveFrameFallback = if case .failure(let reason) = result {
                    reason
                } else {
                    .displayedBeforeInstant
                }
                let waited = now()
                if waited < deadline { await sleep(.nanoseconds(deadline - waited)) }
                if reason == .noFrameInBound, hasFrames { return changed ? .cap : .quiet }
                return .fallback(reason)
            }
            if let previous, !frame.showsSameContent(as: previous) {
                if !changed { changeWasAgainstBaseline = !hasFrames }
                runStart = displayed
                changed  = true
            }
            previous  = frame
            hasFrames = true
            after     = displayed
            if changed, displayed - runStart >= stability {
                return changeWasAgainstBaseline ? .stableAgainstBaseline : .stable
            }
        }
    }

    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        return UInt64(max(0, seconds)) * 1_000_000_000 + UInt64(max(0, attoseconds)) / 1_000_000_000
    }
}

#if MECUM_PHASES
extension SeatSettler.Ending {

    /// The detail the `settle` phase is named with.
    var detail: String {
        switch self {
            case .stable               : "stable"
            case .stableAgainstBaseline: "stable.baseline"
            case .quiet                : "quiet"
            case .cap                  : "cap"
            case .fallback(let reason) : "fallback.\(reason)"
        }
    }
}
#endif
