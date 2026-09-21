import Foundation
import CoreGraphics

/// HORIZONTAL scrolling — the missing axis (Ron, DaVinci Resolve's Deliver page: the render-preset
/// strip scrolls sideways; "we are not capable yet but we should be"). Same physical honesty as the
/// vertical engine: wheel events are delivered AT a point inside the pane (the wheel routes to the
/// window/pane under the cursor), and the CALLER verifies by re-perceiving — never assume movement.
///
/// CGEvent axes: `wheel1` is vertical, `wheel2` horizontal. Positive wheel2 = content moves right
/// (view reveals what is LEFT); negative = reveals what is RIGHT — mirroring vertical's sign flip.
public enum HorizontalScroller {
    /// Find the horizontal SCROLLBAR THUMB inside a pane crop: the widest bright horizontal run in
    /// the bottom band. Measured on Resolve's preset strip — the strip ignores wheel2 AND shift+wheel
    /// entirely; DRAGGING the thumb is what a human does and what actually works. Returns the thumb's
    /// rect in CROP pixels, or nil (no thumb ⇒ the pane isn't horizontally scrollable — honest).
    public static func findThumb(in crop: CGImage) -> CGRect? {
        let w = crop.width, h = crop.height
        guard w > 40, h > 12,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h)
        // The backing buffer is TOP-DOWN (row 0 = top of the image), so the bottom band — where a
        // horizontal scrollbar lives — is the HIGH row indices.
        let bandH = max(4, Int(Double(h) * 0.18))
        var best: (row: Int, start: Int, len: Int) = (0, 0, 0)
        for row in (h - bandH)..<h {
            var vals = [UInt8](repeating: 0, count: w)
            for x in 0..<w { vals[x] = px[row * w + x] }
            let median = vals.sorted()[w / 2]
            let thr = UInt8(min(255, Int(median) + 18))
            var start = -1, runBest = (start: 0, len: 0)
            for x in 0...w {
                let bright = x < w && vals[x] > thr
                if bright { if start < 0 { start = x } }
                else if start >= 0 {
                    if x - start > runBest.len { runBest = (start, x - start) }
                    start = -1
                }
            }
            if runBest.len > best.len { best = (row, runBest.start, runBest.len) }
        }
        let minLen = Int(Double(w) * 0.08), maxLen = Int(Double(w) * 0.85)
        guard best.len >= minLen, best.len <= maxLen else { return nil }
        return CGRect(x: best.start, y: best.row - 2, width: best.len, height: 5)   // row is already top-left
    }

    /// Drag the pane's thumb one "page" toward the requested side. `sectionRectGlobalPt` is the pane
    /// in global points; `crop` is its captured pixels (same rect). Returns false if no thumb.
    public static func dragThumb(sectionRectGlobalPt sec: CGRect, crop: CGImage, revealRight: Bool) -> Bool {
        guard let thumb = findThumb(in: crop) else { return false }
        let sx = sec.width / CGFloat(crop.width)
        let sy = sec.height / CGFloat(crop.height)
        let cx = sec.minX + (thumb.midX * sx)
        let cy = sec.minY + (thumb.midY * sy)
        let thumbW = thumb.width * sx
        // One viewport-ish page: the thumb's own width (thumb:track ratio == view:content ratio),
        // clamped inside the pane.
        let delta = (revealRight ? 1 : -1) * max(24, thumbW * 0.9)
        let toX = min(max(sec.minX + 4, cx + delta), sec.maxX - 4)
        LiveActuator.drag(from: CGPoint(x: cx, y: cy), to: CGPoint(x: toX, y: cy))
        return true
    }

    /// WHICH WAY DID IT SLIDE, in pixels: positive = the content moved RIGHT (so the view revealed
    /// what was on the LEFT), negative = the content moved left (the right-hand side was revealed),
    /// nil = no coherent slide (a repaint, or genuinely nothing moved).
    ///
    /// This is the horizontal verb's polarity evidence. It used to come from two FULL accurate scenes,
    /// diffing the x-centres of elements common to both — 0.7s of OCR to answer a question the pixels
    /// answer for the price of one capture. Same technique as the vertical probe's row alignment
    /// (`ScrollProbe.profileShift`), one axis over.
    ///
    /// Units are DOWNSAMPLED columns (the profile is 512 wide at most), not window pixels — the callers
    /// need the sign and a "did it move at all" magnitude, not a distance.
    public static func contentSlidePx(before: CGImage, after: CGImage) -> Int? {
        guard let lag = ScrollProbe.profileShift(before: ScrollProbe.columnProfile(before),
                                                 after: ScrollProbe.columnProfile(after),
                                                 maxLag: 120) else { return nil }
        return -lag   // profileShift indexes `after` by (x − lag), so its lag is the negated displacement
    }

    /// Deliver `ticks` horizontal wheel lines at `point` (global top-left coords).
    /// direction "right" reveals content to the RIGHT (wheel2 negative), "left" the opposite — on a
    /// machine with natural scrolling OFF. The sign is NOT trustworthy (measured live, both ways on the
    /// same Mac): the caller probes a couple of ticks, measures the slide with `contentSlidePx`, and
    /// finishes with whichever sign actually revealed the requested side.
    public static func scroll(at point: CGPoint, ticks: Int, revealRight: Bool,
                              timing: ScrollTiming = .standard) async {
        // Cursor must be over the pane first — wheel routing follows the pointer, not focus. WARP plus a
        // JIGGLE, the discipline the opaque driver paid for: a mouseMoved with no delta gets dropped and
        // the app then ignores the wheel entirely. (This path used to post one bare mouseMoved and wait
        // 60ms; the warp+jiggle needs 20ms and is what the timings were measured with.)
        let src = CGEventSource(stateID: .hidSystemState)
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: point.x - 5, y: point.y - 5), mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(timing.hoverMs))
        let per: Int32 = revealRight ? -2 : 2
        for _ in 0..<max(1, ticks) {
            guard let e = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState), units: .line,
                                  wheelCount: 2, wheel1: 0, wheel2: per, wheel3: 0) else { continue }
            e.flags.insert(.maskNonCoalesced)
            e.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(timing.burstGapMs))
        }
        try? await Task.sleep(for: .milliseconds(timing.burstSettleMs))   // settle before the caller re-perceives
    }
}
