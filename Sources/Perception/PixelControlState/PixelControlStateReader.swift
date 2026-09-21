//
//  PixelControlStateReader.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/09/2026.
//

import CoreGraphics
import PerceptionCore

/// PixelControlStateReader fills `ControlStateReading` from pixels alone: the read for an
/// application that exposes no accessibility state at all, where a switch or a checkbox would
/// otherwise reach the scene named but silent.
///
/// A switch is a wide pill with a light knob at one end, knob on the right meaning on. A checkbox
/// or a radio is a shallow framed well whose mark sits inside it. Both reads answer nil rather
/// than guess, and every threshold below carries the frame it was measured on.
///
/// The reader keeps nothing: each call redraws the pixels it needs and holds no reference to the
/// image afterwards.
public struct PixelControlStateReader: ControlStateReading {

    public init() {}

    // MARK: The role

    public func isToggleShaped(_ box: CGRect) -> Bool { Self.isToggleShaped(box) }

    public func isMarkShaped(_ box: CGRect) -> Bool { Self.isMarkShaped(box) }

    public func state(of candidate: ControlCandidate, in image: CGImage) -> ControlState? {
        switch candidate.shape {
            case .toggle: Self.toggleState(of: image, pill: candidate.box, isAssumed: candidate.isAssumed)
            case .mark  : Self.markState(of: image, control: candidate.box)
        }
    }

    // MARK: Switches

    /// Is this box switch-shaped? Wide-but-not-elongated pill, in the size range real toggles
    /// render at (1x and retina). Deliberately loose: the state read, nil on ambiguity, is the
    /// real filter.
    public static func isToggleShaped(_ box: CGRect) -> Bool {
        // Height cap 56: a retina macOS switch is 44px, Premiere's 34. Measured false positives above it
        // were thumbnails and buttons (a 161x86 browser box shape-passed and became a stateless toggle).
        guard box.height >= 12, box.height <= 56, box.width >= 16 else { return false }
        let aspect = box.width / box.height
        return aspect >= 1.5 && aspect <= 2.3   // real switches run ~1.6 to 2.0; chevrons (~1.4) and
                                                // ellipsis buttons (~2.7) stay out
    }

    /// Raw half-luminance and color metrics of one switch crop, exposed so the thresholds stay
    /// tunable against real screenshots instead of guessed.
    public struct Metrics: Sendable, Equatable {
        /// Mean luma of the left half, 0 to 255.
        public let left: Double
        /// Mean luma of the right half.
        public let right: Double
        /// Mean (max-min)/255 chroma spread, 0 to 1: an accent fill reads high.
        public let saturation: Double
        /// Edge-energy centroid x, 0 to 1, over the interior columns. The knob's arcs dominate, so
        /// this tracks the knob's SIDE even on a dim achromatic toggle whose luminance polarity is
        /// inverted, which is what Premiere draws.
        public let knobX: Double
    }

    public static func metrics(of crop: CGImage) -> Metrics? {
        let width = crop.width, height = crop.height
        guard width >= 8, height >= 4,
              let rgba = ImageOps.renderRGBA(crop, width: width, height: height),
              let gray = ImageOps.grayscale(crop) else { return nil }
        let stride = width * 4
        var left = 0.0, right = 0.0, saturation = 0.0
        let half = width / 2
        for y in 0..<height {
            for x in 0..<width {
                let p = y * stride + x * 4
                let r = Double(rgba[p]), g = Double(rgba[p + 1]), b = Double(rgba[p + 2])
                // Rec. 601 luma: the weights are plenty for a two-way comparison.
                let luma = 0.299 * r + 0.587 * g + 0.114 * b
                if x < half { left += luma } else { right += luma }
                saturation += (max(r, g, b) - min(r, g, b)) / 255
            }
        }
        let leftCount = Double(half * height)
        guard leftCount > 0 else { return nil }
        // Edge-energy centroid: Sobel column sums over the interior columns (the outer 15% excluded,
        // because the pill's end-caps put symmetric edge mass at both ends and the knob's arcs do not).
        let edges = ImageOps.sobelMagnitude(gray)
        var energy = 0.0, moment = 0.0
        let first = max(1, Int(0.15 * Double(width))), last = min(width - 1, Int(0.85 * Double(width)))
        for x in first..<last {
            var column = 0.0
            for y in 0..<height { column += Double(edges.pixels[y * edges.width + x]) }
            energy += column
            moment += column * Double(x)
        }
        let knobX = energy > 0 ? (moment / energy) / Double(width) : 0.5
        return Metrics(
            left      : left / leftCount,
            right     : right / (Double(width - half) * Double(height)),
            saturation: saturation / Double(width * height),
            knobX     : knobX
        )
    }

    /// On, off, or nil when the crop is unreadable. Two signals: a saturated accent fill, the blue
    /// or teal track, means on whatever the knob does, which is the strongest cue on a dark pro UI;
    /// otherwise the knob's side by luminance, a bright knob on the right meaning on.
    public static func state(of crop: CGImage) -> ControlState? {
        guard let m = metrics(of: crop) else { return nil }
        if m.saturation >= 0.18 { return .on }
        // Measured on real Premiere pixels: a DIMMED-on switch shows left-right about 15 (a dark knob on
        // the right), the same sign as a bright-knob-off switch. Below 25 the luminance cue is ambiguous.
        let margin = 25.0
        if m.right - m.left > margin { return .on }
        if m.left - m.right > margin { return .off }
        // The knob's SIDE by edge-energy centroid, the cue that survives a dimmed achromatic toggle
        // (a disabled Premiere panel: saturation 0.00, luma margin at most 14, unreadable by the two
        // cues above). Measured on that fixture: every true-on centroids at 0.54, every true-off at
        // 0.35 to 0.39, a clean gap. A zero-edge crop centroids at exactly 0.5 and the dead band below
        // returns nil for it, because a flat gray rectangle must never read as a state.
        if m.knobX >= 0.51 { return .on }
        if m.knobX <= 0.45 { return .off }
        return nil
    }

    /// The state of one switch candidate the grouper placed, confirmed against its ends first: an
    /// assumed switch, the unanchored-column fallback, must show a plain knob disc, and a
    /// shape-passed pill must have one flat end. Nil when the box is not a switch after all.
    public static func toggleState(of image: CGImage, pill: CGRect, isAssumed: Bool) -> ControlState? {
        let frame = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let box   = pill.integral.intersection(frame)
        guard !box.isNull, box.width >= 8, box.height >= 4, let crop = image.cropping(to: box) else { return nil }
        let side      = box.height
        let leftEnd   = image.cropping(to: CGRect(x: box.minX, y: box.minY, width: side, height: side))
        let rightEnd  = image.cropping(to: CGRect(x: box.maxX - side, y: box.minY, width: side, height: side))
        let confirmed = isAssumed
            ? leftEnd.map(isPlainKnob) == true
            : hasFlatEnd(leftEnd: leftEnd, rightEnd: rightEnd)
        guard confirmed else { return nil }
        return state(of: crop)
    }

    /// Is this square crop a PLAIN switch knob, a uniform filled disc, rather than a logo or a
    /// glyph? A knob's center is flat; a logo's center carries glyph edges. The gate for a
    /// column-inferred switch with no anchoring pill.
    public static func isPlainKnob(_ crop: CGImage) -> Bool {
        guard let variance = centerVariance(of: crop) else { return false }
        return variance <= 1500   // measured: a real knob center is about 505 (disc edge and
                                  // antialiasing), a logo glyph 5700 or more
    }

    /// Luma variance of the crop's center half-region.
    public static func centerVariance(of crop: CGImage) -> Double? {
        let width = crop.width, height = crop.height
        guard width >= 8, height >= 8,
              let rgba = ImageOps.renderRGBA(crop, width: width, height: height) else { return nil }
        let stride = width * 4
        var sum = 0.0, sumOfSquares = 0.0, count = 0.0
        for y in (height / 4)..<(3 * height / 4) {
            for x in (width / 4)..<(3 * width / 4) {
                let p = y * stride + x * 4
                let luma = 0.299 * Double(rgba[p]) + 0.587 * Double(rgba[p + 1]) + 0.114 * Double(rgba[p + 2])
                sum += luma
                sumOfSquares += luma * luma
                count += 1
            }
        }
        guard count > 0 else { return nil }
        let mean = sum / count
        return max(0, sumOfSquares / count - mean * mean)
    }

    /// A REAL pill has at least one FLAT end: the knob disc (center variance about 505) or the
    /// empty track (about 0). A glyph or logo that merely passes the aspect gate is busy at BOTH
    /// ends (measured on the X social logo: logo arcs left, glyph strokes right, both 5700 or more).
    public static func hasFlatEnd(leftEnd: CGImage?, rightEnd: CGImage?) -> Bool {
        let left  = leftEnd.flatMap(centerVariance(of:))
        let right = rightEnd.flatMap(centerVariance(of:))
        return min(left ?? .infinity, right ?? .infinity) <= 1500
    }

    // MARK: Checkboxes and radios

    /// Is this box CHECK-shaped, a checkbox or a radio rather than a switch? Square-ish, at the
    /// sizes real ones render. Deliberately loose like `isToggleShaped`: the pixel read below, nil
    /// for anything that is not a frame around emptiness, is the real filter.
    public static func isMarkShaped(_ box: CGRect) -> Bool {
        guard box.height >= 10, box.height <= 60, box.width >= 10, box.width <= 60 else { return false }
        let aspect = box.width / box.height
        return aspect >= 0.8 && aspect <= 1.25
    }

    /// Pixel evidence for a CHECKBOX or RADIO. The bands are measured in the control's own
    /// half-widths from its center, so the read is scale-free (1x and retina alike) and does not
    /// care how tightly the segmenter boxed the thing:
    ///   core  at most 0.45   where a tick or a selected radio's dot lives
    ///   field 0.52 to 0.80   the control's own interior, inside its border and outside any mark
    ///   rim   0.82 to 1.00   the control's border, where its outline is drawn
    ///   panel 1.12 and out   the background AROUND the control, which is why this takes the image
    public struct MarkMetrics: Sendable, Equatable {
        /// Median luma of the surrounding background, 0 to 255.
        public let panel: Double
        /// Median luma of the control's empty interior.
        public let field: Double
        /// 0 to 1 of the CORE departing from `panel` in the theme's mark direction.
        public let ink: Double
        /// Median luma of the control's border band.
        public let rim: Double
        /// True when the panel is under 128, where marks are drawn LIGHT; the theme mirror.
        public let isDark: Bool
    }

    /// How far from the local background a pixel must sit to count as mark ink. Measured on
    /// DaVinci's dark Qt: an empty field departs by at most 13.7, while its dimmest checkmark
    /// still scores ink 0.33 here.
    private static let markMargin = 30.0

    /// A one-off read, for a test or a single candidate. A pass over many candidates must use the
    /// `GrayImage` overload and normalize ONCE: cropping per candidate redraws the whole source
    /// each time, measured at 0.8 to 5.6 ms per candidate and about 190 ms across one screen.
    public static func markMetrics(of image: CGImage, control: CGRect) -> MarkMetrics? {
        ImageOps.grayscale(image).flatMap { markMetrics(in: $0, control: control) }
    }

    static func markMetrics(in gray: GrayImage, control: CGRect) -> MarkMetrics? {
        let box = control.integral
        guard box.width >= 8, box.height >= 8, gray.width > 0, gray.height > 0 else { return nil }
        // 40% of the control's own size on every side, so the outer band is clear background at any DPI.
        let padded = box.insetBy(dx: -0.4 * box.width, dy: -0.4 * box.height).integral
            .intersection(CGRect(x: 0, y: 0, width: gray.width, height: gray.height))
        guard padded.width >= 8, padded.height >= 8 else { return nil }
        let centerX = Double(box.midX), centerY = Double(box.midY)
        let halfX = Double(box.width) / 2, halfY = Double(box.height) / 2
        var panel: [Double] = [], field: [Double] = [], core: [Double] = [], rim: [Double] = []
        for y in Int(padded.minY)..<Int(padded.maxY) {
            let row = y * gray.width
            let radiusY = abs(Double(y) + 0.5 - centerY) / halfY
            for x in Int(padded.minX)..<Int(padded.maxX) {
                let radius = max(abs(Double(x) + 0.5 - centerX) / halfX, radiusY)
                let luma   = Double(gray.pixels[row + x])
                if radius <= 0.45 { core.append(luma) }
                else if radius >= 0.52 && radius <= 0.80 { field.append(luma) }
                else if radius >= 0.82 && radius <= 1.00 { rim.append(luma) }
                else if radius >= 1.12 { panel.append(luma) }
            }
        }
        guard core.count >= 9, field.count >= 9, rim.count >= 9, panel.count >= 24 else { return nil }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        let panelLuma = median(panel)
        let dark = panelLuma < 128
        func isInked(_ value: Double) -> Bool {
            dark ? value - panelLuma >= markMargin : panelLuma - value >= markMargin
        }
        return MarkMetrics(
            panel : panelLuma,
            field : median(field),
            ink   : Double(core.filter(isInked).count) / Double(core.count),
            rim   : median(rim),
            isDark: dark
        )
    }

    /// On, off or nil for a CHECKBOX or RADIO: the read for a control whose state lives INSIDE it,
    /// a tick or a selected radio's dot, rather than at a knob's side. Theme-free by construction,
    /// because the background AROUND the control gives both the reference level and the polarity,
    /// marks being light on a dark panel and dark on a light one. Measured on DaVinci's dark Qt
    /// Project Settings, where the switch read called the selected Square and Dual link radios and
    /// the checked Align Clips box all off.
    public static func markState(of image: CGImage, control: CGRect) -> ControlState? {
        ImageOps.grayscale(image).flatMap { markState(in: $0, control: control) }
    }

    static func markState(in gray: GrayImage, control: CGRect) -> ControlState? {
        guard let m = markMetrics(in: gray, control: control) else { return nil }
        // RECESSED: a checkbox or radio is a WELL, its interior sitting AWAY from the mark's color so the
        // mark can stand out, darker than the panel on a dark theme and lighter on a light one. Everything
        // that merely LOOKS square is raised the other way, towards the mark: a toolbar button's plate, a
        // switch knob, a logo's tile. Measured panel to field on dark panels: DaVinci's boxes and radios
        // -3.2 to -13.7; Safari's rounded page-settings button +20, Premiere's switch knobs +36 to +83,
        // its plated destination logos +170.
        guard (m.isDark ? m.field - m.panel : m.panel - m.field) <= 2 else { return nil }
        // And a SHALLOW well: measured 3.2 to 13.7 deep on the real controls. Deeper than that is not a
        // control's interior but a dark region of content, a video thumbnail, that happens to be square.
        guard abs(m.field - m.panel) <= 20 else { return nil }
        // FRAMED: a checkbox or radio is DRAWN, a border running right around it. A bare glyph icon has
        // none, everything around its strokes being exactly the panel, and that, not the ink, is what
        // tells the two apart. Measured |rim-panel|: DaVinci's boxes and radios 3.2 to 9.7, dimmed rows
        // included; every one of the 30 candidates on the Premiere Export frame, its destination logos,
        // its switch knobs, its toolbar glyphs, 0.0 to 1.0. A featureless patch of panel scores 0 and so
        // reports nothing at all.
        guard abs(m.rim - m.panel) >= 2 else { return nil }
        if m.ink >= 0.06 { return .on }    // measured on: 0.327 to 1.000
        if m.ink <= 0.03 { return .off }   // measured off: 0.000 on all twelve unset DaVinci controls
        return nil                         // in between: honestly unknown
    }
}
