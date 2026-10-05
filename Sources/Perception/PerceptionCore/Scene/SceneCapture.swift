//
//  SceneCapture.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

/// SceneCapture is one perceived scene together with the quality of the accessibility read that
/// contributed to it. The scene is what a model reads and what every action depends on; the
/// quality is what a memory needs before it draws a structural conclusion from that scene. They
/// are kept apart so the scene's wire format, token and equality stay what they were.
public struct SceneCapture: Sendable, Equatable {

    public var scene: SceneSnapshot
    public var quality: CaptureQuality

    public init(scene: SceneSnapshot, quality: CaptureQuality) {
        self.scene   = scene
        self.quality = quality
    }
}
