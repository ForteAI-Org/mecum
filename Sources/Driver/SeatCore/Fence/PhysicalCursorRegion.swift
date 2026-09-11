//
//  PhysicalCursorRegion.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics

/// PhysicalCursorRegion is the union of the person's physical displays,
/// border pixels included, because the Dock and the hot corners live there and
/// a fence that shaved them off would break the person's own machine. The upper
/// bound stays excluded, so a virtual display attached next to a physical one
/// is never reachable by the physical cursor.
public struct PhysicalCursorRegion: Sendable, Equatable {

    /// The accepted display bounds, in Quartz coordinates.
    public let bounds: [CGRect]

    /// Returns nil when no display bound survives validation: a fence with no
    /// region would confine the cursor to nowhere, so the caller must fail
    /// closed instead of installing it.
    public init?(displayBounds: [CGRect]) {
        bounds = displayBounds.filter {
            !$0.isNull       && !$0.isInfinite   &&
            !$0.isEmpty      && $0.minX.isFinite &&
            $0.minY.isFinite && $0.maxX.isFinite &&
            $0.maxY.isFinite && $0.width > 1     &&
            $0.height > 1
        }
        
        if bounds.isEmpty { return nil }
    }

    /// contains is the fence's admission test: a non finite coordinate is never
    /// inside, so a broken cursor reading is clamped rather than trusted.
    public func contains(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite &&
        bounds.contains { $0.contains(point) }
    }

    /// nearestPoint returns the closest point still inside the region. The half
    /// point pulled off the far edges keeps the result strictly inside the
    /// rectangle, since `CGRect.contains` excludes its own upper bound.
    public func nearestPoint(to point: CGPoint) -> CGPoint {
        
        if contains(point) { return point }
        
        guard point.x.isFinite && point.y.isFinite else {
            return bounds[0].origin
        }
        
        var nearest  = bounds[0].origin
        var distance = CGFloat.infinity
        
        for rect in bounds {
            let candidate = CGPoint(
                x: min(max(point.x, rect.minX), rect.maxX - 0.5),
                y: min(max(point.y, rect.minY), rect.maxY - 0.5)
            )
            
            let candidateDistance = hypot(candidate.x - point.x, candidate.y - point.y)
            if candidateDistance < distance {
                nearest  = candidate
                distance = candidateDistance
            }
        }
        
        return nearest
    }
}
