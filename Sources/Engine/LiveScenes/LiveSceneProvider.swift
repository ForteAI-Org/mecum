//
//  LiveSceneProvider.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import CoreGraphics
import EngineCore
import Foundation
import Perception
import PerceptionCore
import ScreenCapture

/// LiveSceneProvider is `SceneProviding` for a window on the real screen: it takes the window
/// census, chooses the interaction window, captures it, and runs the scene pipeline. Every call is a
/// fresh perception, never a cache.
///
/// A pop-up is a window of its own beside the one being driven, so while one is open the capture
/// covers the union of both frames and the returned frame is that union: the scene then holds the
/// pop-up's rows, and every element still maps back to a global point through the frame.
public struct LiveSceneProvider: SceneProviding {

    private let pipeline: ScenePipeline
    private let windows: any WindowListing
    private let capturer: StillCapturer
    private let identity: @Sendable (pid_t) -> ApplicationIdentity?

    /// - Parameters:
    ///   - pipeline: the scene pipeline over its recognition roles.
    ///   - windows: the window census.
    ///   - capturer: the foreground eye.
    ///   - identity: the bundle id and name of a process, or nil when it is not an application.
    public init(
        pipeline: ScenePipeline,
        windows : any WindowListing,
        capturer: StillCapturer,
        identity: @escaping @Sendable (pid_t) -> ApplicationIdentity?
    ) {
        self.pipeline = pipeline
        self.windows  = windows
        self.capturer = capturer
        self.identity = identity
    }

    public func currentScene(of processID: pid_t) async throws -> PerceivedWindow {
        guard let application = identity(processID) else {
            throw LiveSceneFailure.unknownApplication(processID: processID)
        }
        let rows = try windows.windows(ownedBy: processID)
        let surfaces = WindowSurfaceClassifier.classify(rows)
        guard let target = surfaces.interaction else {
            throw LiveSceneFailure.noInteractionWindow(processID: processID, rows: rows.count)
        }
        let frame: CGRect
        let image: CGImage
        if surfaces.hasOpenPopup {
            frame = surfaces.popups.reduce(target.frame) { $0.union($1) }
            image = try await capturer.captureRegion(frame)
        } else {
            frame = target.frame
            image = try await capturer.captureWindow(number: target.number, frame: frame)
        }
        let window = ScenePipeline.Window(
            bundleID : application.bundleID,
            appName  : application.name,
            title    : target.title ?? "",
            processID: processID,
            frame    : frame
        )
        let capture = try await pipeline.capture(image, of: window)
        // The union with an open pop-up is two windows in one picture, not a structural surface.
        let surface = surfaces.hasOpenPopup
            ? CaptureSurface.popupUnion
            : CaptureSurface.classified(role: capture.quality.windowRole, subrole: capture.quality.windowSubrole)
        return PerceivedWindow(scene: capture.scene, frame: frame, capture: capture.quality, surface: surface)
    }
}
