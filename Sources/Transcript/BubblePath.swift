//
//  BubblePath.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit

/// BubblePath is the outline of one bubble, in flipped coordinates: a rounded
/// surface, and for a group's last bubble a tail at its bottom corner, as one
/// continuous path, so fill, focus outline and selection all follow one shape.
///
/// The tail's side comes from where `RowGeometry` put it, so a layout that
/// mirrors the bubble mirrors the tail with it.
enum BubblePath {

    static let cornerRadius: CGFloat = 14

    static func path(surface: CGRect, tail: CGRect?) -> NSBezierPath {
        guard let tail else { return NSBezierPath(roundedRect: surface, xRadius: cornerRadius, yRadius: cornerRadius) }
        let path = rightTailed(surface, tail: tail.width, rise: tail.height)
        guard tail.midX < surface.midX else { return path }
        // A tail on the left is the right one mirrored about the surface's centre.
        let mirror = AffineTransform(m11: -1, m12: 0, m21: 0, m22: 1, tX: 2 * surface.midX, tY: 0)
        path.transform(using: mirror)
        return path
    }

    /// The surface with its bottom right corner drawn out into a tail `width`
    /// wide whose outer edge leaves the side `rise` above the bottom.
    private static func rightTailed(_ surface: CGRect, tail width: CGFloat, rise: CGFloat) -> NSBezierPath {
        let radius = min(cornerRadius, surface.height / 2, surface.width / 2)
        let (minX, minY, maxX, maxY) = (surface.minX, surface.minY, surface.maxX, surface.maxY)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: minX + radius, y: minY))
        path.appendArc(from: CGPoint(x: maxX, y: minY), to: CGPoint(x: maxX, y: maxY), radius: radius)
        path.line(to: CGPoint(x: maxX, y: maxY - rise))
        // The outer edge sweeps out to the tip, and the tail's underside runs back along the bubble's bottom
        // line itself, so the two meet with no step.
        path.curve(to: CGPoint(x: maxX + width, y: maxY), controlPoint1: CGPoint(x: maxX, y: maxY - rise * 0.35),
                   controlPoint2: CGPoint(x: maxX + width * 0.45, y: maxY))
        path.line(to: CGPoint(x: minX + radius, y: maxY))
        path.appendArc(from: CGPoint(x: minX, y: maxY), to: CGPoint(x: minX, y: minY), radius: radius)
        path.appendArc(from: CGPoint(x: minX, y: minY), to: CGPoint(x: maxX, y: minY), radius: radius)
        path.close()
        return path
    }
}
