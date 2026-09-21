import Foundation
import AppKit
import CoreGraphics
import AXSupport
import CaptureSupport
import LocatorCore

/// Scroll a PANE without hunting for anything — the primitive `reach` was missing.
///
/// `reach` answers "bring THIS text into view", which is useless for "show me what's further down":
/// the caller must already know a target. Watching a real session, the agent guessed plausible app
/// names to reach for (After Effects, Lightroom, Animate — none present) and burned ~34s per guess.
/// Exploration needs a verb of its own.
///
/// Delivery reuses the discipline the opaque driver paid for: activate, warp + JIGGLE to establish
/// hover (a mouseMoved with no delta gets dropped and the app ignores the wheel), `.line` units
/// (Pro Tools and friends ignore pixel/continuous scrolls), `.maskNonCoalesced`, then settle.
///
/// The wheel's SIGN is not assumed. A wheel line has no absolute meaning — natural scrolling inverts
/// it, and it is on by default — so which lines get posted comes from `WheelPolarity`, and the burst
/// reports back both the sign it used and which way the pixels say the view went. The caller decides
/// what to learn from that, because the caller has the better witness: a scene's named rows, which
/// evenly spaced pixels cannot be read for direction (`ScrollProbe.contentSlidePx`).
public enum PaneScroller {
    public struct Outcome: Sendable {
        public let moved: Bool
        /// False when either capture failed. Missing evidence is not a stationary pane or an end stop.
        public let verified: Bool
        public let paneName: String
        public let ticks: Int
        /// Image pixels the content slid per wheel tick, measured on THIS burst where the slide was
        /// coherent enough to align. A real burst is a better sample than the micro-probe's nudge, and
        /// it costs nothing: the two frames the movement verdict already compares are the two frames the
        /// alignment needs. `reach` spends it to pick a tick count instead of blind-stepping.
        public let pxPerTick: Double?
        /// Which way the PIXELS say the view went, when they could say: true = up, false = down, nil =
        /// no trustworthy reading (see `ScrollProbe.contentSlidePx` — evenly spaced rows are refused).
        /// The caller checks this against what it asked for; that is how the wheel's sign gets learned.
        public let viewWentUp: Bool?
        /// The up-sign this burst was actually posted with, so the caller can name the sign its own
        /// (stronger) direction witness just proved or disproved.
        public let postedUpSign: Int
        public init(moved: Bool, paneName: String, ticks: Int, pxPerTick: Double? = nil,
                    viewWentUp: Bool? = nil, postedUpSign: Int = WheelPolarity.assumedUpSign,
                    verified: Bool = false) {
            self.moved = moved; self.paneName = paneName; self.ticks = ticks
            self.verified = verified
            self.pxPerTick = pxPerTick; self.viewWentUp = viewWentUp; self.postedUpSign = postedUpSign
        }
    }

    /// Scroll the pane under `sectionRectNorm` (window-normalized) of `bundleID`'s frontmost window.
    /// Negative ticks scroll the view UP, positive DOWN — the CALLER'S direction, not a wheel sign:
    /// which wheel lines that takes is measured (`WheelPolarity`), never assumed.
    /// Returns whether the pixels actually changed, so the caller can report an honest "nothing moved".
    /// Where inside the pane to deliver the wheel, as a fraction of the pane. Default centre; callers
    /// that know where the CONTENT is (rows of text) should aim there instead — macOS scrolls whatever
    /// sits under the cursor, and a pane's geometric centre can easily be a divider, a ruler or empty
    /// canvas, in which case the wheel goes to the wrong view or nowhere.
    public static func scroll(bundleID: String, sectionRectNorm: CGRect, paneName: String,
                              ticks: Int, aimNorm: CGPoint? = nil, ax: AXEngine? = nil,
                              timing: ScrollTiming = .standard,
                              capture: WindowCaptureService = WindowCaptureService()) async -> Outcome {
        let t = StageTimer("paneScroll \(bundleID) \(paneName) \(ticks)")
        let ax = await MainActor.run { ax ?? AXEngine() }
        let winOpt = await MainActor.run { ScrollWindow.resolve(bundleID: bundleID, ax: ax) }
        guard let win = winOpt else { return Outcome(moved: false, paneName: paneName, ticks: 0) }
        t.stamp("window-resolve")

        // Deliver the wheel at the pane's CENTER: macOS scrolls whatever sits under the cursor, so the
        // point decides which pane moves (window-center scrolled the wrong pane — the measured bug that
        // started the section-anchored work).
        let aim = aimNorm ?? CGPoint(x: sectionRectNorm.midX, y: sectionRectNorm.midY)
        let target = CGPoint(x: win.frame.minX + (aim.x * win.frame.width),
                             y: win.frame.minY + (aim.y * win.frame.height))
        let inward = CGPoint(x: target.x + (aim.x < 0.5 ? 6 : -6),
                             y: target.y + (aim.y < 0.5 ? 6 : -6))

        let beforeShot = try? await capture.captureMatchingWindow(bundleID: win.bundle, title: win.title,
                                                                  axWindowFrameGlobalPt: win.frame)
        let beforeCrop = beforeShot.flatMap { $0.image.cropping(to: regionPx(sectionRectNorm, $0.pixelSize)) }
        t.stamp("capture before")

        // WHICH SIGN. A wheel line has no absolute meaning — natural scrolling inverts it, and it is on
        // by default — so the sign comes from `WheelPolarity`: the machine's measured one if anything has
        // measured it, else the measured default. What this burst learns is decided by the CALLER, which
        // has the better direction witness (the pane's named rows); see `Outcome.viewWentUp`.
        let upSign = WheelPolarity.upSign(app: win.bundle, axis: .vertical)
        let perEvent = WheelPolarity.wheel1(requestedTicks: ticks, upSign: upSign)
        await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: win.bundle).first?.activate()
            let src = CGEventSource(stateID: .hidSystemState)
            CGWarpMouseCursorPosition(target)
            CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
            CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: inward, mouseButton: .left)?.post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(for: .milliseconds(timing.hoverMs))
        let events = timing.burstEvents
        for _ in 0..<events {
            await MainActor.run {
                guard let e = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState), units: .line,
                                      wheelCount: 1, wheel1: perEvent, wheel2: 0, wheel3: 0) else { return }
                e.flags.insert(.maskNonCoalesced)
                e.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(for: .milliseconds(timing.burstGapMs))
        }
        t.stamp("burst (\(events)×\(perEvent) lines)")
        try? await Task.sleep(for: .milliseconds(timing.burstSettleMs))   // settle before we judge movement

        var moved = false
        var verified = false
        var shift: Int?
        var viewWentUp: Bool?
        if let before = beforeCrop,
           let shot = try? await capture.captureMatchingWindow(bundleID: win.bundle, title: win.title,
                                                              axWindowFrameGlobalPt: win.frame),
           let after = shot.image.cropping(to: regionPx(sectionRectNorm, shot.pixelSize)) {
            verified = true
            let changed = OpaqueScrollDriver.regionChangeFraction(before: before, after: after)
            moved = changed > 0.004
            if moved {
                // HOW FAR and WHICH WAY are two questions, and they survive different amounts of doubt:
                // an aliased alignment still carries a usable magnitude for `reach`'s seeded jump (what
                // `shift` has always fed), while its sign is a coin toss — so `contentSlidePx` refuses
                // those. Both readings come free: these are the two frames the movement verdict already
                // compared.
                shift = ScrollProbe.profileShift(before: ScrollProbe.rowProfile(before),
                                                 after: ScrollProbe.rowProfile(after), maxLag: 120)
                viewWentUp = ScrollProbe.contentSlidePx(before: before, after: after).map { $0 > 0 }
            }
            t.stamp(String(format: "verdict (%@ %.4f%@)", moved ? "moved" : "still", changed,
                           viewWentUp.map { ", view went \($0 ? "up" : "down")" } ?? ""))
        }
        t.stamp("done")
        return Outcome(moved: moved, paneName: paneName, ticks: ticks,
                       pxPerTick: shift.map { Double(abs($0)) / Double(events) },
                       viewWentUp: viewWentUp, postedUpSign: upSign, verified: verified)
    }

    private static func regionPx(_ norm: CGRect, _ size: CGSize) -> CGRect {
        CGRect(x: norm.minX * size.width, y: norm.minY * size.height,
               width: norm.width * size.width, height: norm.height * size.height).integral
    }
}
