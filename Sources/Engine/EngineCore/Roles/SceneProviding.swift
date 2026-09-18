//
//  SceneProviding.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics
import Foundation
import PerceptionCore

/// SceneProviding supplies the current scene of a process's interaction window: a fresh perception
/// at every call, never a cache, because an action is resolved against this instant's positions.
///
/// It also reports the window the scene was taken from, in global points, so the engine can turn a
/// normalized element into the point a gesture is delivered at.
public protocol SceneProviding: Sendable {

    func currentScene(of processID: pid_t) async throws -> PerceivedWindow
}

/// PerceivedWindow is a scene together with the global frame of the window it describes.
public struct PerceivedWindow: Sendable, Equatable {

    public let scene: SceneSnapshot
    public let frame: CGRect

    public init(scene: SceneSnapshot, frame: CGRect) {
        self.scene = scene
        self.frame = frame
    }

    /// The global point at the center of an element of this scene.
    public func globalPoint(of element: SceneElement) -> CGPoint {
        CGPoint(
            x: frame.minX + element.bounds.midX * frame.width,
            y: frame.minY + element.bounds.midY * frame.height
        )
    }
}
