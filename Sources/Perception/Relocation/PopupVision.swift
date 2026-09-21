import Foundation
import CoreGraphics
import AppKit
import CaptureSupport
import OCRSupport
import LocatorCore

/// VISION-FIRST pop-up driving (Ron's directive, verbatim intent): "we can physically move the mouse
/// hovering the element and physically press… we can physically calculate how much we need to scroll
/// and where, and then scroll — and the peek can confirm it."
///
/// An open pop-up (dropdown list, context menu, submenu) is a REAL window on a popup layer. This
/// captures THAT window at native scale (which also fixes Premiere: its GPU-drawn dropdown OCR'd as
/// garble only because we captured the main window and the list was tiny), OCRs the items, then acts
/// like a hand with an eye:
///   move the mouse ONTO the item → hover → RE-CAPTURE and verify the text under the cursor is still
///   the target (the peek move) → physically click. Not found? Physically WHEEL inside the pop-up,
///   re-look, repeat; unwind the scroll if the item never appears.
///
/// No keyboard heroics: type-ahead/arrows remain only as the caller's fallback when this path can't
/// even capture the pop-up. AX is consulted by the caller first where it works; measured on Pro Tools
/// and Premiere, pop-up ITEMS expose no AX children, so vision owns them.
public enum PopupVision {
    public struct Item: Sendable {
        public var text: String
        public var rectGlobalPt: CGRect   // top-left global points — a live physical click target
    }

    public enum Outcome: Sendable {
        case clicked(item: String, at: CGPoint, submenuOpened: Bool)
        case notFound(seen: [String], scrolled: Bool)
        case noPopupCapture            // couldn't correlate/capture the popup window → caller falls back
    }

    /// Read one pop-up window's items by capturing IT (not the app's main window) and OCRing at
    /// native scale. `frame` comes from `WindowCaptureService.openPopupFrames(pid:)`.
    static func read(pid: pid_t, frame: CGRect, ocr: OCREngine) async -> [Item]? {
        guard let shot = try? await WindowCaptureService().capturePopupWindow(pid: pid, frameGlobalPt: frame)
        else { return nil }
        if let dir = ProcessInfo.processInfo.environment["LOCATOR_SUPERVISE_DIR"] {
            SuperviseDump.writePNG(shot.image, to: URL(fileURLWithPath: dir).appendingPathComponent("popup-capture.png"))
            FileHandle.standardError.write(Data("🔬 popup capture: \(shot.image.width)x\(shot.image.height) from \(frame)\n".utf8))
        }
        let ctx = WindowCoordinateContext(axWindowOriginGlobalPt: frame.origin,
                                          backingScale: CGFloat(shot.image.width) / max(frame.width, 1),
                                          imagePixelSize: shot.pixelSize)
        let results = ocr.recognizeText(in: shot.image, ctx: ctx, accurate: true)
        let sx = frame.width / CGFloat(shot.image.width)
        let sy = frame.height / CGFloat(shot.image.height)
        return results.map { r in
            Item(text: r.text,
                 rectGlobalPt: CGRect(x: frame.minX + r.boxImagePx.minX * sx,
                                      y: frame.minY + r.boxImagePx.minY * sy,
                                      width: r.boxImagePx.width * sx,
                                      height: r.boxImagePx.height * sy))
        }
    }

    /// Normalize a pop-up ITEM for matching — lowercase, keep ALPHANUMERICS incl. DIGITS. Pop-up items
    /// are often VALUES ("44.1 kHz", "48 kHz", "1920x1080", "320 kbps") where the NUMBER is the whole
    /// identity — so we must NOT use LocatorMemory.core, which strips leading ≤2-char tokens and
    /// collapsed every sample rate to "khz" (measured: asked for 44.1 kHz, it picked 8 kHz, forever).
    static func norm(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Find `target` among items. Exact normalized match wins (handles all clean value cases). Then
    /// guarded prefix matches for OCR jitter — never the loose `contains` that let "8" hide inside
    /// "48". Number-preserving throughout.
    static func match(_ target: String, in items: [Item]) -> Item? {
        let want = norm(target)
        guard !want.isEmpty else { return nil }
        if let e = items.first(where: { norm($0.text) == want }) { return e }
        // The item extends the target ("44.1 kHz" → "44.1 kHz (recommended)"): item starts with want.
        if let p = items.first(where: { let n = norm($0.text); return n.hasPrefix(want) && n.count <= want.count + 12 }) { return p }
        // The target carried extra words the item doesn't ("44.1 kHz sample" → item "44.1 kHz"): the
        // item is a prefix of the target, but must be a substantial one (≥ most of it) to avoid "8".
        if let p = items.first(where: { let n = norm($0.text); return !n.isEmpty && want.hasPrefix(n) && n.count >= max(3, want.count - 6) }) { return p }
        return nil
    }

    /// LAND ON A ROW AX ALREADY LOCATED (ticket 06): hover the frame accessibility gave us, re-capture
    /// the pop-up, and require our own eye to read the target under the cursor before clicking. This is
    /// the fast half of the AX path — no OCR hunt, no scrolling, because AX already answered "which row
    /// and where"; vision keeps its veto on the LANDING, which is the part AX can be stale about.
    ///
    /// Returns nil when vision could NOT confirm the row (OCR read a run-on blob, the menu moved, the
    /// row is blank): the caller then selects the item semantically (`AXPopupReader.press`) instead of
    /// clicking a spot it cannot see. Never guesses a click.
    public static func clickVerified(pid: pid_t, target: String, at point: CGPoint,
                                     dryRun: Bool = false) async -> Outcome? {
        let capture = WindowCaptureService()
        guard let popup = capture.openPopupFrames(pid: pid).first,
              popup.insetBy(dx: -4, dy: -4).contains(point) else { return nil }
        moveMouse(to: point)
        try? await Task.sleep(for: .milliseconds(ActTiming.standard.popupHoverMs))
        guard let confirm = await read(pid: pid, frame: popup, ocr: OCREngine()) else { return nil }
        let underCursor = confirm.filter { $0.rectGlobalPt.insetBy(dx: -6, dy: -4).contains(point) }
        let stillThere = match(target, in: underCursor) != nil
            || underCursor.contains { LocatorMemory.core($0.text) == LocatorMemory.core(target) }
        guard stillThere else { return nil }
        if dryRun { return .clicked(item: target, at: point, submenuOpened: false) }
        let popupsBefore = capture.openPopupFrames(pid: pid).count
        LiveActuator.click(at: point)
        try? await Task.sleep(for: .milliseconds(ActTiming.standard.popupCommitMs))
        return .clicked(item: target, at: point,
                        submenuOpened: capture.openPopupFrames(pid: pid).count > popupsBefore)
    }

    /// The whole gesture: read → (scroll to find) → hover → verify → click.
    public static func select(pid: pid_t, target: String, dryRun: Bool = false,
                              maxScrollPages: Int = 6) async -> Outcome {
        let capture = WindowCaptureService()
        let ocr = OCREngine()
        // FRONTMOST popup (CGWindowList is front-to-back): with a submenu open there are TWO popup
        // windows, and the backmost is the parent menu — reading it hunts the wrong list (measured:
        // asked for a folder in the submenu, got the context menu's Delete/Duplicate items).
        guard var popup = capture.openPopupFrames(pid: pid).first else { return .noPopupCapture }
        guard var items = await read(pid: pid, frame: popup, ocr: ocr) else { return .noPopupCapture }
        var seen = items.map(\.text)
        var scrolled = 0

        // PHYSICALLY SCROLL the pop-up hunting the item — wheel at the pop-up's center, re-read, and
        // judge by what the eye sees (items changed?). Bounded; unwound on failure.
        while match(target, in: items) == nil, scrolled < maxScrollPages {
            let before = items.map(\.text)
            wheel(at: CGPoint(x: popup.midX, y: popup.midY), lines: -4)
            try? await Task.sleep(for: .milliseconds(280))
            // The pop-up may have grown/moved (some render taller once scrolled) — re-probe its frame.
            guard let fresh = capture.openPopupFrames(pid: pid).first else { return .noPopupCapture }
            popup = fresh
            guard let next = await read(pid: pid, frame: popup, ocr: ocr) else { return .noPopupCapture }
            items = next
            seen.append(contentsOf: items.map(\.text).filter { !seen.contains($0) })
            scrolled += 1
            if items.map(\.text) == before { break }   // nothing moved — the list is at its end
        }
        guard let hit = match(target, in: items) else {
            if scrolled > 0 { wheel(at: CGPoint(x: popup.midX, y: popup.midY), lines: Int32(4 * scrolled)) }
            return .notFound(seen: Array(Set(seen)).sorted(), scrolled: scrolled > 0)
        }
        if dryRun { return .clicked(item: hit.text, at: CGPoint(x: hit.rectGlobalPt.midX, y: hit.rectGlobalPt.midY), submenuOpened: false) }

        // HOVER, then VERIFY with a fresh capture (the peek): the row under the cursor must still read
        // the target — a list that shifted under us re-searches once instead of clicking blind.
        var point = CGPoint(x: hit.rectGlobalPt.midX, y: hit.rectGlobalPt.midY)
        moveMouse(to: point)
        try? await Task.sleep(for: .milliseconds(180))
        if let confirm = await read(pid: pid, frame: popup, ocr: ocr) {
            let underCursor = confirm.filter { $0.rectGlobalPt.insetBy(dx: -6, dy: -4).contains(point) }
            let stillThere = underCursor.contains { LocatorMemory.core($0.text) == LocatorMemory.core(hit.text) }
                || match(target, in: underCursor) != nil
            if !stillThere, let rehit = match(target, in: confirm) {
                point = CGPoint(x: rehit.rectGlobalPt.midX, y: rehit.rectGlobalPt.midY)
                moveMouse(to: point)
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        let popupsBefore = capture.openPopupFrames(pid: pid).count
        LiveActuator.click(at: point)
        try? await Task.sleep(for: .milliseconds(350))
        let popupsAfter = capture.openPopupFrames(pid: pid).count
        return .clicked(item: hit.text, at: point, submenuOpened: popupsAfter > popupsBefore)
    }

    /// A real hover: the cursor physically travels there (menus highlight, tooltips arm) — not just a
    /// click teleport.
    static func moveMouse(to p: CGPoint) {
        CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState),
                mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// Wheel INSIDE the pop-up: position the cursor there first (wheel routes to the window under the
    /// cursor), then line-scroll. Negative = content down (reveal items below).
    static func wheel(at p: CGPoint, lines: Int32) {
        moveMouse(to: p)
        usleep(40_000)
        for _ in 0..<abs(lines) {
            guard let e = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState), units: .line,
                                  wheelCount: 1, wheel1: lines < 0 ? -1 : 1, wheel2: 0, wheel3: 0) else { continue }
            e.flags.insert(.maskNonCoalesced)
            e.post(tap: .cghidEventTap)
            usleep(15_000)
        }
    }
}
