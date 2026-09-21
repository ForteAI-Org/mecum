import Foundation
import AppKit
import CoreGraphics
import AXSupport
import CaptureSupport
import LocatorCore

/// WHICH WINDOW a scroll drives.
///
/// This used to be `ax.reader.windows(of: appEl).first`, copy-pasted into the pane scroller, the micro
/// probe and the timing harness — and `.first` is not the window the user is looking at. Measured on
/// Finder while it was NOT frontmost: the first AX window is a **157×17pt** phantom (a label/tooltip
/// window). Every consequence follows from that one line: the wheel goes to a point inside a 157pt
/// strip somewhere else on screen, the "did it move" verdict compares two 34px-tall crops where a
/// couple of noisy pixels are 5% of the region — so a burst that scrolled nothing at all reported
/// `moved 0.0529`, and the pane's real end never got named. (Seen live: `scroll(direction:"up")` on a
/// list already at its top answered "scrolled up" three calls out of four.)
///
/// The judgement already existed one module over — `WindowCaptureService.isSubstantialWindow`, which
/// knows that a short-wide sheet counts and a 300×40 tooltip does not. This just applies it.
public enum ScrollWindow {
    public struct Target: Sendable {
        public let bundle: String
        public let title: String
        public let frame: CGRect
        public init(bundle: String, title: String, frame: CGRect) {
            self.bundle = bundle; self.title = title; self.frame = frame
        }
    }

    /// Index of the window to drive among `frames` (AX order, frontmost first): the first SUBSTANTIAL
    /// one, else the largest — a phantom is still better than refusing to scroll when it is all the app
    /// offers, but it must never win over a real window that is merely listed after it.
    static func pick(_ frames: [CGRect]) -> Int? {
        let usable = frames.enumerated().filter { $0.element.width > 1 && $0.element.height > 1 }
        if let substantial = usable.first(where: { WindowCaptureService.isSubstantialWindow($0.element) }) {
            return substantial.offset
        }
        return usable.max(by: { $0.element.width * $0.element.height < $1.element.width * $1.element.height })?.offset
    }

    /// Resolve the window to drive in `bundleID` — or in the frontmost app when it is nil. A NAMED
    /// bundle that is not running is a MISS, never a silent fall back to whatever is in front: a scroll
    /// (or a measurement) aimed at the wrong app is worse than no scroll at all.
    @MainActor public static func resolve(bundleID: String?, ax: AXEngine) -> Target? {
        let named = bundleID.flatMap { KnowledgeHarvester.resolveApp(bundleID: $0) }
        guard let app = bundleID == nil ? NSWorkspace.shared.frontmostApplication : named,
              let bundle = app.bundleIdentifier else { return nil }
        let appEl = ax.reader.applicationElement(pid: app.processIdentifier)
        ax.reader.setMessagingTimeout(appEl, seconds: 2)
        let windows = ax.reader.windows(of: appEl)
        let frames = windows.map { ax.frameGlobalPt($0) ?? .zero }
        guard let i = pick(frames) else { return nil }
        return Target(bundle: bundle, title: ax.title(windows[i]) ?? "", frame: frames[i])
    }
}
