import Foundation
import CoreGraphics
import LocatorCore

public extension WindowCaptureService {
    /// EVERY on-screen window this app owns, as identity + title + layer + size — no pixels, no OCR,
    /// one CGWindowList call. Taken before a gesture and again after, its DIFF answers the question an
    /// `acted_unverified` could never answer before: did nothing happen anywhere, or did the effect
    /// land in another window (a dialog that opened, a menu that closed, a retitled window)? The agent
    /// that clicked a phantom four times was choosing between those two worlds with no evidence.
    ///
    /// Cheap enough to pay on the act path unconditionally, and it must stay that way: no capture, no
    /// AX, no filtering by size — the JUDGEMENT about which windows matter lives in `MissGuide`, where
    /// it is testable without a screen.
    ///
    /// The one judgement it does carry over is `isPopup`, and it comes from the SAME classifier the
    /// window choice and the pop-up detector use (ticket 12: three separate walks of this list, three
    /// separate ideas of what a pop-up is — a dropdown on an ordinary window layer was "a new window"
    /// to the guided miss, "the window to drive" to the picker and "nothing" to the detector).
    func windowSignatures(pid: pid_t) -> [MissGuide.WindowSig] {
        surfaces(pid: pid).verdicts.compactMap { v in
            // A window with no usable CGWindowID is dropped, not folded into a shared id 0: identity is
            // the whole basis of the before/after diff, and two windows sharing one would read as "the
            // same window" and hide an appearance.
            guard let id = UInt32(exactly: v.row.number), id != 0 else { return nil }
            return MissGuide.WindowSig(id: id, title: v.row.title,
                                       layer: v.row.layer, size: v.row.frameGlobalPt.size,
                                       isPopup: v.kind == .popupLayer || v.kind == .floatingList)
        }
    }
}
