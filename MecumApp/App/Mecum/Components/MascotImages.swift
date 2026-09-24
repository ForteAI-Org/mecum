//
//  MascotImages.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import AppKit

/// MascotImages draws a worker's mascot once and keeps the picture.
///
/// The sidebar and the transcript take a static image rather than a live
/// surface (§5.3): there is no Metal layer per worker and no shader here. Only
/// an explicit regenerate changes a `WorkerAppearance`, so an entry stays
/// valid for the life of the process; the cache is keyed by the appearance and
/// the size in points, which is what the drawing depends on.
///
/// The first generator is a coloured ball with soft light and a clean
/// silhouette (§5.1). The silhouette is always a circle, so
/// `MascotDrawing.radiusFraction` is not read here: shape variation belongs to
/// the 2,5D generator, which branches on `generatorVersion`.
///
/// Main actor isolated, which is the rule that protects the dictionary: every
/// caller is a view or the transcript's controller. The drawing itself is
/// nonisolated, because `NSImage` runs its handler wherever it needs the picture.
///
/// The cache is not evicted. A team is tens of workers at two sizes, and an
/// entry is a small bitmap.
/// ponytail: unbounded cache, take a size limit if a workspace ever holds
/// enough workers for it to matter.
@MainActor
enum MascotImages {

    private static var cache: [Key: NSImage] = [:]

    static func image(for appearance: WorkerAppearance, size: CGFloat) -> NSImage {
        let points = max(1, Int(size.rounded()))
        let key    = Key(appearance: appearance, points: points)
        if let cached = cache[key] { return cached }

        let drawing = MascotDrawing(appearance)
        let side    = CGFloat(points)
        let image   = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            draw(drawing, in: rect)
            return true
        }
        cache[key] = image
        return image
    }

    /// Paints the ball: one round silhouette, one soft light, one darker rim.
    ///
    /// When the gradient cannot be made, the flat base colour fills the same
    /// silhouette. That is the intended fallback and not a broken avatar: the
    /// worker keeps its colour and its shape, and only the light is missing.
    private nonisolated static func draw(_ drawing: MascotDrawing, in rect: NSRect) {
        let silhouette = NSBezierPath(ovalIn: rect)

        let base = NSColor(
            hue       : drawing.hue,
            saturation: drawing.saturation,
            brightness: drawing.brightness,
            alpha     : 1
        )
        let light = NSColor(
            hue       : drawing.hue,
            saturation: max(0, drawing.saturation - 0.34 * drawing.highlightSpread),
            brightness: min(1, drawing.brightness + 0.14 + 0.12 * drawing.glow),
            alpha     : 1
        )
        let rim = NSColor(
            hue       : drawing.hue,
            saturation: min(1, drawing.saturation + 0.18),
            brightness: max(0, drawing.brightness - 0.30),
            alpha     : 1
        )

        guard let gradient = NSGradient(colors: [light, base, rim]) else {
            base.setFill()
            silhouette.fill()
            return
        }

        // AppKit's y grows upwards, so the light's vertical position, which
        // is measured from the top, is mirrored here.
        gradient.draw(
            in                    : silhouette,
            relativeCenterPosition: NSPoint(
                x: (drawing.highlightX - 0.5) * 2,
                y: (0.5 - drawing.highlightY) * 2
            )
        )
    }

    private struct Key: Hashable {
        let appearance: WorkerAppearance
        let points    : Int
    }
}
