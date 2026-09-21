import CoreGraphics
import Foundation
import LocatorCore

/// Reads a toggle SWITCH's on/off state from pixels alone — for zero-AX apps (Premiere's Export
/// destinations, section toggles) where no API exposes control state. A switch is a wide pill with a light
/// knob at one end: knob on the RIGHT half ⇒ on, LEFT ⇒ off (macOS + Adobe convention). We compare mean
/// luminance of the two halves; a flat/ambiguous crop returns nil ("unknown") rather than a guess.
public enum ToggleStateReader: Sendable {
    /// Is this box switch-shaped? Wide-but-not-elongated pill, in the size range real toggles render at
    /// (1x and retina). Deliberately loose — the state read (nil on ambiguity) is the real filter.
    public static func isToggleShaped(_ r: CGRect) -> Bool {
        // Height cap 56: a retina macOS switch is 44px, Premiere's 34. Measured false positives above it
        // were thumbnails and buttons (a 161×86 browser box shape-passed and became a stateless toggle).
        guard r.height >= 12, r.height <= 56, r.width >= 16 else { return false }
        let aspect = r.width / r.height
        return aspect >= 1.5 && aspect <= 2.3   // real switches run ~1.6–2.0; chevrons (~1.4) and
                                                // ellipsis "…" buttons (~2.7) stay out
    }

    /// Raw half-luminance + color metrics — exposed so real-world thresholds are tunable against
    /// `debug-segment --group` output on actual screenshots instead of guessed.
    public struct Metrics: Sendable {
        public let left: Double        // mean luma, left half (0…255)
        public let right: Double       // mean luma, right half
        public let saturation: Double  // mean (max-min)/255 chroma spread (0…1) — accent fill reads high
        public let knobX: Double       // edge-energy centroid x (0…1) over interior columns — the knob's
                                       // arcs dominate, so this tracks knob SIDE even on dim achromatic
                                       // toggles where luminance polarity flips (measured on Premiere)
    }

    public static func metrics(of crop: CGImage) -> Metrics? {
        let w = crop.width, h = crop.height
        guard w >= 8, h >= 4,
              let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
        let stride = ctx.bytesPerRow
        var left = 0.0, right = 0.0, sat = 0.0
        let half = w / 2
        for y in 0..<h {
            for x in 0..<w {
                let p = y * stride + x * 4
                let r = Double(px[p]), g = Double(px[p + 1]), b = Double(px[p + 2])
                // Rec. 601 luma — integer-ish weights are plenty for a two-way comparison.
                let lum = 0.299 * r + 0.587 * g + 0.114 * b
                if x < half { left += lum } else { right += lum }
                sat += (max(r, g, b) - min(r, g, b)) / 255
            }
        }
        let n = Double(half * h)
        guard n > 0 else { return nil }
        // Edge-energy centroid: Sobel column sums over interior columns (outer 15% excluded — the
        // pill's end-caps put symmetric edge mass at both ends; the knob's arcs are interior).
        let edges = ImageOps.sobelMagnitude(ImageOps.grayscale(crop))
        var eSum = 0.0, exSum = 0.0
        let x0 = max(1, Int(0.15 * Double(w))), x1 = min(w - 1, Int(0.85 * Double(w)))
        for x in x0..<x1 {
            var col = 0.0
            for y in 0..<h { col += Double(edges.pixels[y * edges.width + x]) }
            eSum += col; exSum += col * Double(x)
        }
        let knobX = eSum > 0 ? (exSum / eSum) / Double(w) : 0.5
        return Metrics(left: left / n, right: right / (Double(w - half) * Double(h)),
                       saturation: sat / Double(w * h), knobX: knobX)
    }

    /// Is this square crop a PLAIN switch knob (uniform filled disc) rather than a logo/glyph icon?
    /// A knob's center is flat; a logo's center carries glyph edges. Judged on the center half-region's
    /// luma variance — gate for column-inferred switches with no anchoring pill.
    public static func isPlainKnob(_ crop: CGImage) -> Bool {
        guard let v = centerVariance(of: crop) else { return false }
        return v <= 1500   // measured: real knob centers ≈ 505 (disc edge + AA); logo glyphs ≥ 5700
    }

    /// Luma variance of the crop's center half-region (diagnosable via debug-segment --group).
    public static func centerVariance(of crop: CGImage) -> Double? {
        let w = crop.width, h = crop.height
        guard w >= 8, h >= 8,
              let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
        let stride = ctx.bytesPerRow
        var sum = 0.0, sumSq = 0.0, n = 0.0
        for y in (h / 4)..<(3 * h / 4) {
            for x in (w / 4)..<(3 * w / 4) {
                let p = y * stride + x * 4
                let lum = 0.299 * Double(px[p]) + 0.587 * Double(px[p + 1]) + 0.114 * Double(px[p + 2])
                sum += lum; sumSq += lum * lum; n += 1
            }
        }
        guard n > 0 else { return nil }
        let mean = sum / n
        return max(0, sumSq / n - mean * mean)
    }

    /// "on" | "off" | nil (unreadable). Two signals: (1) a saturated accent fill (blue/teal track) means ON
    /// regardless of knob position — the strongest cue on dark pro UIs; (2) otherwise knob-side luminance
    /// (bright knob RIGHT ⇒ on). A flat/ambiguous crop returns nil rather than a guess.
    public static func state(of crop: CGImage) -> String? {
        guard let m = metrics(of: crop) else { return nil }
        if m.saturation >= 0.18 { return "on" }
        // Measured on real Premiere pixels: a DIMMED-on switch shows l−r ≈ 15 (dark knob right) — the same
        // sign as a bright-knob-off switch. Below ~25 the luminance cue is genuinely ambiguous → nil.
        let margin = 25.0
        if m.right - m.left > margin { return "on" }
        if m.left - m.right > margin { return "off" }
        // (3) knob SIDE by edge-energy centroid — the cue that survives DIMMED, achromatic toggles
        // (a disabled Premiere panel: sat 0.00, luma margin ≤14, unreadable by cues 1–2). Measured on
        // that fixture: every true-ON centroids at 0.54, every true-OFF at 0.35–0.39 — clean gap.
        // A zero/weak-edge crop centroids to exactly 0.5 — the dead band below returns nil for it
        // (a flat gray rectangle must never read as a state).
        if m.knobX >= 0.51 { return "on" }
        if m.knobX <= 0.45 { return "off" }
        return nil
    }

    // MARK: - Checkbox / radio ("mark") controls

    /// Is this box CHECK-shaped — a checkbox or radio rather than a switch? Square-ish, at the sizes real
    /// ones render (1x and retina). Deliberately loose like `isToggleShaped`: the pixel read below (nil for
    /// anything that isn't a frame around emptiness) is the real filter.
    public static func isMarkShaped(_ r: CGRect) -> Bool {
        guard r.height >= 10, r.height <= 60, r.width >= 10, r.width <= 60 else { return false }
        let aspect = r.width / r.height
        return aspect >= 0.8 && aspect <= 1.25
    }

    /// Pixel evidence for a CHECKBOX / RADIO. Bands are measured in the control's own half-widths from its
    /// centre, so the read is scale-free (1x and retina alike) and does not care how tightly the segmenter
    /// boxed the thing:
    ///   core  ≤ 0.45      — where a tick or a selected radio's dot lives
    ///   field 0.52…0.80   — the control's own interior, inside its border and outside any mark
    ///   rim   0.82…1.00   — the control's border, where its outline is drawn
    ///   panel ≥ 1.12      — the background AROUND the control (which is why this takes the whole image)
    public struct MarkMetrics: Sendable {
        public let panel: Double         // median luma of the surrounding background (0…255)
        public let field: Double         // median luma of the control's empty interior
        public let ink: Double           // 0…1 of the CORE departing from `panel` in the theme's mark direction
        public let rim: Double           // median luma of the control's border band
        public let isDark: Bool          // panel < 128 → marks are drawn LIGHT here; else DARK (the theme mirror)
    }

    /// How far from the local background a pixel must sit to count as mark ink. Measured on DaVinci's dark
    /// Qt: an empty field departs by at most 13.7, while its DIMMEST checkmark still scores ink 0.33 here.
    private static let markMargin = 30.0

    /// Convenience for a one-off read (tests, the debug harness). A pass over many candidates must use
    /// the `GrayImage` overload and normalize ONCE: cropping per candidate re-decodes the whole source
    /// each time — measured 0.8…5.6 ms per candidate, scaling with the frame, ~190 ms across one screen.
    public static func markMetrics(of image: CGImage, control: CGRect) -> MarkMetrics? {
        markMetrics(in: ImageOps.grayscale(image), control: control)
    }

    public static func markMetrics(in gray: GrayImage, control: CGRect) -> MarkMetrics? {
        let ctrl = control.integral
        guard ctrl.width >= 8, ctrl.height >= 8, gray.width > 0, gray.height > 0 else { return nil }
        // 40% of the control's own size on every side, so the outer band is clear background at any DPI.
        let padded = ctrl.insetBy(dx: -0.4 * ctrl.width, dy: -0.4 * ctrl.height).integral
            .intersection(CGRect(x: 0, y: 0, width: gray.width, height: gray.height))
        guard padded.width >= 8, padded.height >= 8 else { return nil }
        let cx = Double(ctrl.midX), cy = Double(ctrl.midY)
        let hx = Double(ctrl.width) / 2, hy = Double(ctrl.height) / 2
        var panel: [Double] = [], field: [Double] = [], core: [Double] = [], rim: [Double] = []
        for y in Int(padded.minY)..<Int(padded.maxY) {
            let row = y * gray.width
            let ry = abs(Double(y) + 0.5 - cy) / hy
            for x in Int(padded.minX)..<Int(padded.maxX) {
                let rad = max(abs(Double(x) + 0.5 - cx) / hx, ry)
                let lum = Double(gray.pixels[row + x])
                if rad <= 0.45 { core.append(lum) }
                else if rad >= 0.52 && rad <= 0.80 { field.append(lum) }
                else if rad >= 0.82 && rad <= 1.00 { rim.append(lum) }
                else if rad >= 1.12 { panel.append(lum) }
            }
        }
        guard core.count >= 9, field.count >= 9, rim.count >= 9, panel.count >= 24 else { return nil }
        func median(_ a: [Double]) -> Double { a.sorted()[a.count / 2] }
        let pn = median(panel)
        let dark = pn < 128
        func inked(_ v: Double) -> Bool { dark ? v - pn >= markMargin : pn - v >= markMargin }
        return MarkMetrics(panel: pn, field: median(field),
                           ink: Double(core.filter(inked).count) / Double(core.count),
                           rim: median(rim), isDark: dark)
    }

    /// "on" | "off" | nil for a CHECKBOX or RADIO — the zero-AX read for controls whose state lives INSIDE
    /// them (a tick, a selected radio's dot) rather than at a knob's side. Theme-free by construction: the
    /// background AROUND the control gives both the reference level and the polarity (marks are drawn light
    /// on a dark panel, dark on a light one), which is the dark-theme path this exists for. Measured on
    /// DaVinci's dark Qt Project Settings, where the switch reader called the selected "Square" and
    /// "Dual link" radios and the checked "Align Clips" box all [off].
    public static func markState(of image: CGImage, control: CGRect) -> String? {
        markState(in: ImageOps.grayscale(image), control: control)
    }

    public static func markState(in gray: GrayImage, control: CGRect) -> String? {
        guard let m = markMetrics(in: gray, control: control) else { return nil }
        // RECESSED — a checkbox/radio is a WELL: its interior sits AWAY from the mark's colour so the mark
        // can stand out (darker than the panel on a dark theme, lighter on a light one). Everything that
        // merely LOOKS square is raised the other way, towards the mark: a toolbar button's plate, a switch
        // knob, a logo's tile. Measured panel→field, dark panels: DaVinci's boxes and radios −3.2…−13.7;
        // Safari's rounded page-settings button +20, Premiere's switch knobs +36…+83, its plated
        // destination logos +170.
        guard (m.isDark ? m.field - m.panel : m.panel - m.field) <= 2 else { return nil }
        // …and a SHALLOW well: measured 3.2…13.7 deep on the real controls. Deeper than that is not a
        // control's interior but a dark region of content (a video thumbnail) that happens to be square.
        guard abs(m.field - m.panel) <= 20 else { return nil }
        // FRAMED — a checkbox/radio is DRAWN: a border runs right around it. A bare glyph icon has none —
        // everything around its strokes is exactly the panel — and that, not the ink, is what tells the two
        // apart. Measured |rim−panel|: DaVinci's boxes and radios 3.2…9.7 (dimmed rows included); every one
        // of the 30 candidates on the Premiere Export frame — its destination logos, its switch knobs, its
        // toolbar glyphs — 0.0…1.0. A featureless patch of panel scores 0 and so reports nothing at all.
        guard abs(m.rim - m.panel) >= 2 else { return nil }
        if m.ink >= 0.06 { return "on" }    // measured ON: 0.327…1.000
        if m.ink <= 0.03 { return "off" }   // measured OFF: 0.000 on all twelve unset DaVinci controls
        return nil                          // in between: honestly unknown
    }

    /// A confirmed checkbox/radio: where it is and what it says.
    public struct MarkControl: Sendable, Equatable {
        public let rect: CGRect
        public let state: String
        public init(rect: CGRect, state: String) { self.rect = rect; self.state = state }
    }

    /// Split raw segments into confirmed CHECKBOX/RADIO controls and the segments still available to the
    /// switch detector. A confirmed mark is REMOVED from `rest`, because the switch machinery would
    /// otherwise read it as a knob — the measured failure: DaVinci's selected "Square" radio got anchored
    /// to an unrelated pill 100px up the column, and its dot sitting left of that phantom pill's centre
    /// declared it [off].
    public static func markControls(segments: [CGRect], in image: CGImage) -> (marks: [MarkControl], rest: [CGRect]) {
        // Kill switch for A/B and safety, like the content suppressor's: with it set the frame is read
        // exactly as it was before checkbox/radio states existed.
        guard ProcessInfo.processInfo.environment["LOCATOR_NO_MARK_STATES"] == nil else { return ([], segments) }
        let candidates = ElementGrouper.markCandidates(segments: segments, isMarkShaped: isMarkShaped)
        guard !candidates.isEmpty else { return ([], segments) }
        let gray = ImageOps.grayscale(image)   // ONE normalization for the whole frame — see markMetrics
        let marks = candidates.compactMap { r in markState(in: gray, control: r).map { MarkControl(rect: r, state: $0) } }
        guard !marks.isEmpty else { return ([], segments) }
        return (marks, segments.filter { s in !marks.contains { $0.rect.insetBy(dx: -1, dy: -1).contains(s) } })
    }

    /// A REAL pill has at least one FLAT end: the knob disc (center variance ≈ 505) or the empty track
    /// (~0). A glyph/logo that merely passes the aspect gate is busy at BOTH ends (measured: the X
    /// social logo — logo arcs left, glyph strokes right, both ≥ 5700) — drop it. Gate for
    /// shape-passed (non-assumed) candidates; assumed ones keep the stricter knob-only gate.
    public static func hasFlatEnd(leftEnd: CGImage?, rightEnd: CGImage?) -> Bool {
        let vl = leftEnd.flatMap(centerVariance(of:))
        let vr = rightEnd.flatMap(centerVariance(of:))
        return min(vl ?? .infinity, vr ?? .infinity) <= 1500
    }
}
