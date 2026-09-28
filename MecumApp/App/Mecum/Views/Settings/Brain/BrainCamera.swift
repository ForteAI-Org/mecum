//
//  BrainCamera.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import SwiftUI

/// BrainCamera is where the Brain's graph is looked at from: the graph point
/// in the middle of the view and how many points one unit of the graph takes.
/// It animates, so framing the graph again glides there.
struct BrainCamera: Equatable {

    var centre: CGPoint
    var scale : CGFloat

    /// Close enough to read a control's name, far enough to see a large graph whole.
    private static let scales: ClosedRange<CGFloat> = 0.1...6

    /// The camera that shows all of `bounds` inside `size` with a margin for the controls
    /// over the graph, never closer than twice.
    init(
        fitting bounds: CGRect,
        in size       : CGSize
    ) {
        let width  = max(size.width - 128, 1) / max(bounds.width, 1)
        let height = max(size.height - 128, 1) / max(bounds.height, 1)
        centre     = CGPoint(
            x: bounds.midX,
            y: bounds.midY
        )
        scale      = min(max(min(width, height, 2), Self.scales.lowerBound), Self.scales.upperBound)
    }

    var animatableData: AnimatablePair<CGPoint.AnimatableData, CGFloat> {
        get {
            AnimatablePair(
                centre.animatableData,
                scale
            )
        }
        set {
            centre.animatableData = newValue.first
            scale                 = newValue.second
        }
    }

    // MARK: Space

    func screen(
        _ point: CGPoint,
        in size: CGSize
    ) -> CGPoint {
        CGPoint(
            x: size.width / 2 + (point.x - centre.x) * scale,
            y: size.height / 2 + (point.y - centre.y) * scale
        )
    }

    func graph(
        _ point: CGPoint,
        in size: CGSize
    ) -> CGPoint {
        CGPoint(
            x: centre.x + (point.x - size.width / 2) / scale,
            y: centre.y + (point.y - size.height / 2) / scale
        )
    }

    /// How large a node of `radius` is drawn: it grows with the camera, but less, so a far
    /// graph stays legible and a near one does not turn into discs.
    func radius(_ radius: CGFloat) -> CGFloat { radius * min(max(scale, 0.6), 2) }

    // MARK: Moves

    func panned(by translation: CGSize) -> BrainCamera {
        var camera = self
        camera.centre.x -= translation.width / scale
        camera.centre.y -= translation.height / scale
        return camera
    }

    /// Closer by `factor`, keeping the graph point under `anchor` where it is.
    func zoomed(
        by factor   : CGFloat,
        about anchor: CGPoint,
        in size     : CGSize
    ) -> BrainCamera {
        let fixed = graph(
            anchor,
            in: size
        )

        var camera = self
        camera.scale  = min(max(scale * factor, Self.scales.lowerBound), Self.scales.upperBound)
        camera.centre = CGPoint(
            x: fixed.x - (anchor.x - size.width / 2) / camera.scale,
            y: fixed.y - (anchor.y - size.height / 2) / camera.scale
        )
        return camera
    }
}
