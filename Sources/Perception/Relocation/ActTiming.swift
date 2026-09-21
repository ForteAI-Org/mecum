import Foundation
import AppKit
import CoreGraphics
import CaptureSupport
import LocatorCore

/// THE ACT CLOCK — every sleep an `act` round trip pays, in one place, each one carrying the measurement
/// that set it. Same discipline (and the same reason) as `ScrollTiming`: the sleeps were literals spread
/// through the handler, so nobody could see their sum, and the sum was a third of the round trip.
///
/// MEASURED 2026-08-22 with `locator debug-act` (the harness below), release build. It clicks a real
/// window and then captures it back to back; a capture is ~0.11-0.13s, so its resolution is ~120ms and
/// "final at the first sample" is the strongest statement it can make.
///
///   settle after the click   KEPT AT 300ms, because one surface needs nearly all of it. Finder (list
///                            view, a sidebar navigation) was NOT final at the first capture: +169ms
///                            showed only the selection highlight (Δbefore 0.0070) and the loaded
///                            directory arrived by +352ms (Δbefore 0.0706, Δprev 0.0000 after). DaVinci
///                            Resolve's Preferences (Qt, dark, 1892×1600) was final at +134ms and
///                            TextEdit's word-select at +119ms — so 300ms is the max of what the
///                            surfaces need, not the average, and cutting it to fit the fast ones would
///                            hand the agent a half-loaded Finder as "the scene after your click".
///                            An ADAPTIVE wait was measured against this and rejected: proving the
///                            window has STOPPED changing costs two captures (~240ms) on top of the
///                            first, i.e. more than the sleep it replaces, and on the one surface it
///                            would help (Finder) it needs three. Change-not-stability is not a
///                            substitute — Finder's first post-click change is the highlight, 0.0070,
///                            which is the same magnitude as DaVinci's FINAL state (0.0109), so no
///                            threshold separates "it started" from "it finished".
///   activation               Gone in the common case. `act` used to activate the app unconditionally
///                            and then sleep 200ms; measured, that was 0.21s of a 1.66-1.71s Finder
///                            round trip spent raising an app that was ALREADY frontmost (which it
///                            almost always is — the agent just perceived it). `ActivationPolicy` now
///                            skips both when the target app is in front. When a real switch is needed
///                            the 200ms stands: it is the app's own focus + repaint, and clicking into
///                            a window that is still coming up is how a click gets eaten.
///
/// The pop-up keyboard fallback's sleeps are here too, unmeasured and unchanged: that path only runs when
/// the pop-up window cannot be captured at all, it is rare, and its own scars (a Return landing on the
/// dialog behind a closed menu) were bought with those numbers. Anything here that changes must change
/// with a printed `debug-act` run in the commit message.
public struct ActTiming: Sendable {
    /// After the click/double-click/right-click, before the verifying re-perception.
    public var clickSettleMs: Int = 300
    /// After activating an app that was NOT frontmost, before the gesture.
    public var activateSettleMs: Int = 200
    /// Pop-up keyboard fallback: after typing the item's first word.
    public var popupTypeMs: Int = 250
    /// Pop-up keyboard fallback: after the → that probes for a submenu.
    public var popupArrowMs: Int = 250
    /// After the cursor is moved onto a pop-up row, before re-capturing to verify what is under it.
    /// Unmeasured, inherited from the vision pop-up path's own literal — a real hover has to give the
    /// menu time to highlight the row, which is the pixel evidence being read.
    public var popupHoverMs: Int = 180
    /// After the click (or the keyboard fallback's Return) that commits a pop-up selection, before
    /// judging what happened.
    public var popupCommitMs: Int = 350
    /// After Escape dismisses a pop-up whose items don't include the target.
    public var popupDismissMs: Int = 250
    /// How long to keep checking that a SELECTED menu actually went away before judging the outcome.
    /// A dismissed menu fades, and its popup-layer window (and AX frame) outlive the selection —
    /// measured on TextEdit's font menu: the probe 350ms after a successful AX press still saw the
    /// popup and re-read all 88 rows. Polled at 150ms, so this is an upper bound, not a sleep.
    public var popupDismissWaitMs: Int = 600

    public static let standard = ActTiming()

    public init() {}
}

/// Does the gesture need the app RAISED first? Two rules, both scars, and both cheap to get wrong:
///
/// • NEVER while a pop-up menu is open. The activation event cancels menu tracking, the menu closes, and
///   the click that follows lands on the window behind it (measured on Pro Tools: picking "Routing
///   Folder" failed every time this way, and succeeded first try without activating). The menu already
///   owns event focus, so activation buys nothing there.
/// • NEVER when the app is already frontmost. `activate()` is then a no-op — its own front window is
///   already in front — but the settle that follows it is not: 0.21s of every act, in the case that is
///   almost every act, since the agent perceives the app immediately before acting on it.
///
/// Not knowing which app is frontmost is not evidence of being in front: activate.
public enum ActivationPolicy {
    public static func needsActivation(targetPid: pid_t, frontmostPid: pid_t?, popupOpen: Bool) -> Bool {
        if popupOpen { return false }
        return frontmostPid != targetPid
    }
}

/// The harness that produced the numbers above, kept so they can be re-measured instead of re-guessed
/// (the same reason `ScrollLab` and `debug-compare` are kept). Clicks a real window at a real point and
/// reports, sample by sample, how the window settles afterwards.
///
/// It clicks for real, so aim it deliberately: a window-normalized point, at a target the operator picked.
public enum ActLab {
    public struct Sample: Sendable {
        /// Milliseconds after the click that this capture completed.
        public let atMs: Int
        /// Fraction of the watched region's pixels differing from the pre-click frame.
        public let changedVsBefore: Double
        /// …and from the previous sample: this is the one that says "still repainting".
        public let changedVsPrevious: Double
    }

    public struct Run: Sendable {
        public let window: CGRect
        public let pixelSize: CGSize
        public let samples: [Sample]
    }

    /// Click at `aimNorm` and watch `watchNorm` (both window-normalized) settle.
    /// CV-first window resolve (`frontmostWindowFrame`), so the zero-AX apps can be measured too.
    public static func measure(bundleID: String?, aimNorm: CGPoint, watchNorm: CGRect, samples: Int,
                               verb: String = "click", activate: Bool = true,
                               capture: WindowCaptureService = WindowCaptureService()) async -> Run? {
        struct Win: Sendable { let bundle: String; let pid: pid_t; let title: String?; let frame: CGRect }
        let winOpt: Win? = await MainActor.run { () -> Win? in
            // A named bundle that is not running is a MISS, never a silent fall back to whatever is in
            // front: a harness that measures the wrong app teaches the wrong number (ScrollLab's scar).
            let named = bundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
            guard let app = bundleID == nil ? NSWorkspace.shared.frontmostApplication : named,
                  let b = app.bundleIdentifier else { return nil }
            guard let probe = WindowCaptureService().frontmostWindowFrame(pid: app.processIdentifier),
                  probe.frameGlobalPt.width > 1 else { return nil }
            return Win(bundle: b, pid: app.processIdentifier, title: probe.title, frame: probe.frameGlobalPt)
        }
        guard let win = winOpt else { return nil }
        func shoot() async -> (img: CGImage, size: CGSize)? {
            guard let s = try? await capture.captureMatchingWindow(bundleID: win.bundle, title: win.title,
                                                                   axWindowFrameGlobalPt: win.frame) else { return nil }
            return (s.image, s.pixelSize)
        }
        func watched(_ shot: (img: CGImage, size: CGSize)) -> CGImage? {
            shot.img.cropping(to: CGRect(x: watchNorm.minX * shot.size.width, y: watchNorm.minY * shot.size.height,
                                         width: watchNorm.width * shot.size.width,
                                         height: watchNorm.height * shot.size.height).integral)
        }
        guard let first = await shoot(), let before = watched(first) else { return nil }

        let aim = CGPoint(x: win.frame.minX + aimNorm.x * win.frame.width,
                          y: win.frame.minY + aimNorm.y * win.frame.height)
        if activate {
            _ = await MainActor.run { NSRunningApplication(processIdentifier: win.pid)?.activate() }
            try? await Task.sleep(for: .milliseconds(ActTiming.standard.activateSettleMs))
        }
        switch verb {
        case "double_click": LiveActuator.doubleClick(at: aim)
        case "right_click": LiveActuator.rightClick(at: aim)
        default: LiveActuator.click(at: aim)
        }
        let clickEnd = Date()

        var out: [Sample] = []
        var previous = before
        for _ in 0..<max(1, samples) {
            guard let shot = await shoot(), let patch = watched(shot) else { continue }
            out.append(Sample(atMs: Int(Date().timeIntervalSince(clickEnd) * 1000),
                              changedVsBefore: OpaqueScrollDriver.regionChangeFraction(before: before, after: patch),
                              changedVsPrevious: OpaqueScrollDriver.regionChangeFraction(before: previous, after: patch)))
            previous = patch
        }
        return Run(window: win.frame, pixelSize: first.size, samples: out)
    }
}
