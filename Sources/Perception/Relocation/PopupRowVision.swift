import Foundation
import CoreGraphics
import CaptureSupport
import OCRSupport
import LocatorCore

/// THE OPEN POP-UP, READ AS ITEMS WHEN ACCESSIBILITY HAS NOTHING TO SAY — the zero-AX half of popup
/// enumeration (ticket 07), and the fallback `AXPopupReader` returning `[]` exists to cue.
///
/// A native menu answers `AXPopupReader` with every one of its rows. A custom-drawn list does not:
/// Premiere's export format popup and DaVinci's resolution list are GPU/Qt widgets with no AX children
/// at all, and the scene carried them as ONE RUN-ON BLOB — the agent could see a list was open and
/// could not name a single option in it. So the pop-up is captured as the WINDOW IT IS, at native scale
/// (the same eye `PopupVision` uses to select), and its OCR lines are cut into item rows by row pitch.
///
/// The elements are shaped EXACTLY like the AX half's (`role: "AXMenuItem"`, `kind: "control"`), which
/// is not cosmetic: three downstream rules key on that role — the scene files menu rows under the
/// "open menu" section, spatial memory refuses to remember them as places, and the act path routes a
/// target inside the pop-up through `PopupVision.select` (hover → re-capture → verify → click). One
/// shape, one set of behaviours, whether the rows came from accessibility or from pixels.
///
/// What this deliberately does NOT do: promise rows it cannot see. AX reports a long menu WHOLE; pixels
/// only ever show the painted page, so there are no off-view rows here — items below the fold are found
/// by `PopupVision.select`'s physical scroll, exactly as before.
public enum PopupRowVision {
    /// WHAT THE READ DID — the one line the timing log prints, in EVERY branch, including the branches
    /// that change nothing.
    ///
    /// This exists because of how ticket 07's own live acceptance went wrong: it ran against a deploy 34
    /// minutes OLDER than this file. The scene showed the pre-ticket garble (fragments and one mangled
    /// label), the timing log said nothing about pop-up rows — that binary had no such code — and the
    /// silence was read as "the row cut ran and produced fragments", which cost a live cycle chasing a
    /// segmentation bug that was not there. A branch that only speaks when it succeeds cannot be told
    /// apart from a branch that is not in the binary at all, so every outcome says its own name.
    public enum Outcome: Equatable {
        /// The pop-up's own pixels never arrived: the region capture failed, timed out, or the capture
        /// circuit is open. Indicts the CAPTURE — nothing was segmented, so nothing can be blamed on it.
        case notCaptured
        /// Read, and it is not an enumeration. One row is the same blob wearing a new shape.
        case belowTheBar(rows: Int)
        /// Adopted: this many item elements replaced the window capture's read of the same pixels.
        case adopted(rows: Int)
        /// Accessibility already answered, so the second capture was never paid for — every native menu.
        case axAnswered(rows: Int)
        /// `LOCATOR_NO_POPUP_ROWS`.
        case off

        public var summary: String {
            switch self {
            case .notCaptured:        return "pop-up NOT captured — scene unchanged"
            case .belowTheBar(let n): return "\(n) row(s) read — below the two-row bar, scene unchanged"
            case .adopted(let n):     return "\(n) rows adopted from the pop-up's own pixels"
            case .axAnswered(let n):  return "not needed — accessibility answered \(n) rows"
            case .off:                return "off (LOCATOR_NO_POPUP_ROWS)"
            }
        }
    }

    /// Read the open pop-up's items from its OWN pixels. `popup` comes from
    /// `WindowCaptureService.openPopupFrames(pid:)`; row rects come back in global TOP-LEFT points.
    ///
    /// `nil` is NOT an empty list: it means the pixels never arrived, so there was nothing to segment.
    /// "We never looked" and "we looked and this list has no readable items" fail for different reasons
    /// and are fixed in different places — the caller reports them as different outcomes.
    public static func rows(pid: pid_t, popup: CGRect, ocr: OCREngine = OCREngine(),
                            capture: WindowCaptureService = WindowCaptureService()) async -> [PopupRowSegmenter.Row]? {
        guard let shot = (try? await capture.capturePopupWindow(pid: pid, frameGlobalPt: popup)) ?? nil
        else { return nil }
        return rows(in: shot.image, popupGlobalPt: popup, ocr: ocr)
    }

    /// The same read from an ALREADY CAPTURED pop-up image — the offline seam the fixture gate and the
    /// unit tests drive. Segmentation happens in IMAGE PIXELS (where the row pitch actually lives) and
    /// the rows are mapped back into `popupGlobalPt`, so a retina capture answers in points like
    /// everything else in a scene.
    public static func rows(in image: CGImage, popupGlobalPt: CGRect,
                            ocr: OCREngine = OCREngine()) -> [PopupRowSegmenter.Row] {
        guard image.width > 1, image.height > 1, popupGlobalPt.width > 1, popupGlobalPt.height > 1 else { return [] }
        let pixelRect = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        let ctx = WindowCoordinateContext(axWindowOriginGlobalPt: popupGlobalPt.origin,
                                          backingScale: CGFloat(image.width) / popupGlobalPt.width,
                                          imagePixelSize: pixelRect.size)
        // ACCURATE, always: this is a scene the agent READS (the fast tier is for comparison loops
        // only, per the spec's one-knob rule), and a pop-up is a small image — the cost is small too.
        let runs = ocr.recognizeText(in: image, ctx: ctx, accurate: true)
            .map { ElementGrouper.TextRun(rect: $0.boxImagePx, text: $0.text) }
        let sx = popupGlobalPt.width / CGFloat(image.width)
        let sy = popupGlobalPt.height / CGFloat(image.height)
        func toPoints(_ r: CGRect) -> CGRect {
            CGRect(x: popupGlobalPt.minX + r.minX * sx, y: popupGlobalPt.minY + r.minY * sy,
                   width: r.width * sx, height: r.height * sy)
        }
        return PopupRowSegmenter.rows(runs, in: pixelRect)
            .map { PopupRowSegmenter.Row(text: $0.text, rect: toPoints($0.rect), textRect: toPoints($0.textRect)) }
    }

    /// The rows as SCENE ELEMENTS, normalized to the frame the scene was perceived from (the frame
    /// `act` computes its click points against — see `SceneBuilder.buildSceneResolved`). Positions are
    /// allowed to leave 0…1: a dropdown routinely hangs outside its window, the transform is linear,
    /// and clamping would aim the click at the wrong pixels.
    public static func elements(from rows: [PopupRowSegmenter.Row], popup: CGRect,
                                windowFrame: CGRect) -> [SceneElement] {
        guard windowFrame.width > 0, windowFrame.height > 0 else { return [] }
        var out: [SceneElement] = []
        for (i, row) in rows.enumerated() {
            let pos = [Double((row.rect.minX - windowFrame.minX) / windowFrame.width),
                       Double((row.rect.minY - windowFrame.minY) / windowFrame.height),
                       Double(row.rect.width / windowFrame.width),
                       Double(row.rect.height / windowFrame.height)]
            // The ROW INDEX is in the identity key for the same reason the AX half puts the order there:
            // two rows reading the same thing are two different things to click.
            let id = ObservedObject.makeIdentityKey(role: "AXMenuItem", identifier: nil,
                                                    text: "\(row.text)#\(i)", boundsNormalized: pos)
            out.append(SceneElement(id: id, kind: "control", label: row.text, pos: pos,
                                    role: "AXMenuItem",
                                    does: "menu item — read from the pop-up's own pixels (no accessibility here)",
                                    section: nil))
        }
        // Ordinal disambiguation, same rule as the AX half: a list with two "Custom" rows stays
        // unique-accept for resolve ("Custom", "Custom #2").
        var seen: [String: Int] = [:]
        for i in out.indices {
            let n = (seen[out[i].label] ?? 0) + 1
            seen[out[i].label] = n
            if n > 1 { out[i].label += " #\(n)" }
        }
        return out
    }

    /// Drop the MAIN CAPTURE's copy of everything inside the pop-up. Those are the same pixels read at
    /// window scale, which is exactly how a GPU-drawn list reached the scene as garble ("Dport",
    /// "MWPLE" — measured on Premiere): left in, they compete with the rows for the same target name
    /// and give the agent phantom labels to act on.
    ///
    /// `rowBands` are the ADOPTED rows, window-normalized — pass them and the unlabeled boxes inside a
    /// band go too. That half was learned from a live report of this very pop-up path: "~30 unlabeled
    /// icon fragments on a grid", which is the window capture's read of the list one BOX PER WORD. A
    /// fragment sitting inside a row the agent can now name by name is that word read worse, and thirty
    /// of them make the map unreadable. Outside every band an unlabeled box is kept, unchanged: a header
    /// strip or the pop-up's scroll arrow is geography the rows never covered, and it is all the agent
    /// has of it.
    public static func dropCVInsidePopup(cv: [SceneElement], popupNormalized: [Double],
                                         rowBands: [[Double]] = []) -> [SceneElement] {
        guard popupNormalized.count == 4, popupNormalized[2] > 0, popupNormalized[3] > 0 else { return cv }
        let box = CGRect(x: popupNormalized[0], y: popupNormalized[1],
                         width: popupNormalized[2], height: popupNormalized[3]).insetBy(dx: -0.005, dy: -0.005)
        let bands = rowBands.filter { $0.count == 4 && $0[2] > 0 && $0[3] > 0 }
            .map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
        return cv.filter { e in
            guard e.pos.count == 4 else { return true }
            let centre = CGPoint(x: e.pos[0] + e.pos[2] / 2, y: e.pos[1] + e.pos[3] / 2)
            guard box.contains(centre) else { return true }
            guard e.unlabeled == true else { return false }   // a name inside the pop-up always goes
            return !bands.contains { $0.contains(centre) }
        }
    }
}
