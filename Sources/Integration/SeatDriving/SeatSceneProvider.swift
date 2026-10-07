//
//  SeatSceneProvider.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import CoreGraphics
import EngineCore
import Foundation
import Perception
import PerceptionCore
#if MECUM_PHASES
import PhaseSignposts
#endif
import SeatCapture
import SeatCore
import SeatSession

/// SeatSceneProvider is `SceneProviding` for a window adopted on the Seat: a still of the window
/// through the Seat's capture, the scene pipeline on top, and the frame the still's own geometry
/// reports, so a pixel the model names maps back to the point the Seat will route.
///
/// While a pop-up is open beside the window, the still is of the whole virtual display, cropped to
/// the union of the window and the pop-up: the scene then holds the pop-up's rows and the returned
/// frame is that union. Accessibility geometry is never mixed in; the augmenter's trust rule drops
/// frames that do not intersect the captured rectangle, and on the Seat the application's own child
/// frames still point at the window's old place.
///
/// A window still whose pixels are byte for byte those the last scene was read from, of the same
/// window with the same census facts, answers that scene again without the pipeline (ADR 0034), so
/// the layer above answers "Unchanged since revision N." through its own baseline. The trade-off,
/// accepted by the owner: a change that draws nothing (an accessibility value or focus) is not seen.
/// Every call still takes a fresh observation, so a reused scene is bound to pixels taken after the
/// last Command. The display path never reuses.
public struct SeatSceneProvider: SceneProviding {

    private let target: SeatTarget
    private let pipeline: ScenePipeline
    private let windows: any WindowListing
    private let identity: @Sendable (pid_t) -> ApplicationIdentity?
    private let lastScene = LastScene()

    public init(
        target  : SeatTarget,
        pipeline: ScenePipeline,
        windows : any WindowListing,
        identity: @escaping @Sendable (pid_t) -> ApplicationIdentity?
    ) {
        self.target   = target
        self.pipeline = pipeline
        self.windows  = windows
        self.identity = identity
    }

    public func currentScene(of processID: pid_t) async throws -> PerceivedWindow {
        #if MECUM_PHASES
        let perception = PhaseInterval.begin("perception")
        defer { perception.end() }
        // Ended only when the kept scene is answered, so the table counts and times the reuses alone.
        let reusing = PhaseInterval.begin("perception.reused")
        #endif
        let application = identity(processID)
            ?? ApplicationIdentity(bundleID: "pid.\(processID)", name: "pid \(processID)")
        // Only the windows on the seat's display: one left on the person's display is not in this scene.
        let seatBounds = await target.displayID.map(CGDisplayBounds) ?? .null
        let onSeat = try windows.windows(ownedBy: processID).filter { $0.frame.intersects(seatBounds) }
        let popups = WindowSurfaceClassifier.classify(onSeat).popups
        let image: CGImage
        let frame: CGRect
        let observedWindow: AdoptedWindow
        var comparable: SeatFrame?
        if popups.isEmpty {
            #if MECUM_PHASES
            let windowStill = PhaseInterval.begin("capture.windowStill")
            #endif
            let still = try await target.windowStill()
            #if MECUM_PHASES
            windowStill.end()
            let conversion = PhaseInterval.begin("capture.makeCGImage")
            #endif
            guard still.geometry.isValid, let pixels = still.makeCGImage() else {
                throw SeatDrivingFailure.frameUnusable
            }
            #if MECUM_PHASES
            conversion.end()
            #endif
            image = pixels
            frame = still.geometry.screenRect
            comparable = still
            guard let captured = await target.lastCapturedWindow else { throw SeatDrivingFailure.frameUnusable }
            observedWindow = captured
        } else {
            #if MECUM_PHASES
            let displayStill = PhaseInterval.begin("capture.displayStill")
            #endif
            let still = try await target.displayStill()
            #if MECUM_PHASES
            displayStill.end()
            #endif
            guard still.geometry.isValid, let pixels = still.makeCGImage() else {
                throw SeatDrivingFailure.frameUnusable
            }
            let display = still.geometry.screenRect
            let scale = still.geometry.scaleFactor
            let windowFrame = try await target.currentFrame()
            let union = popups.reduce(windowFrame) { $0.union($1) }.intersection(display)
            let crop = CGRect(
                x     : (union.minX - display.minX) * scale,
                y     : (union.minY - display.minY) * scale,
                width : union.width * scale,
                height: union.height * scale
            ).integral
            guard let cropped = pixels.cropping(to: crop) else { throw SeatDrivingFailure.frameUnusable }
            image = cropped
            frame = union
            observedWindow = try await target.currentWindow()
        }
        // Adoption keeps a recovery title; only a fresh census can name the document now displayed.
        let matchingRows = try windows.windows(ownedBy: processID).filter { $0.number == observedWindow.id }
        let currentTitle = matchingRows.count == 1 ? matchingRows[0].title ?? "" : ""
        let window = ScenePipeline.Window(
            bundleID    : application.bundleID,
            appName     : application.name,
            title       : currentTitle,
            processID   : processID,
            frame       : frame,
            windowNumber: observedWindow.id
        )
        // ADR 0034: the same window and census over byte-identical pixels is the scene already read.
        if let comparable, let kept = await lastScene.kept, kept.window == window,
           kept.frame.showsSameContent(as: comparable) {
            #if MECUM_PHASES
            reusing.end()
            #endif
            await MainActor.run { target.lastSceneImage = image }
            return PerceivedWindow(scene: kept.scene, frame: frame)
        }
        #if MECUM_PHASES
        let perceiving = PhaseInterval.begin("pipeline")
        #endif
        let scene = try await pipeline.perceive(image, of: window)
        #if MECUM_PHASES
        perceiving.end()
        #endif
        await MainActor.run {
            target.lastSceneImage = image
            if let comparable { lastScene.kept = LastScene.Kept(frame: comparable, window: window, scene: scene) }
        }
        return PerceivedWindow(scene: scene, frame: frame)
    }

    /// LastScene keeps the window still the last scene was built from, with the window facts and the
    /// scene, so the next still can be compared to it. Only the latest is kept, and replacing it
    /// releases the Frame, which owns its surface (a stopped Still's, or a detached copy).
    @MainActor
    private final class LastScene {

        struct Kept: Sendable {
            let frame : SeatFrame
            let window: ScenePipeline.Window
            let scene : SceneSnapshot
        }

        var kept: Kept?
    }
}

/// ApplicationIdentity is the bundle id and name a scene is stamped with, asked for by process id
/// through a closure supplied at composition, so this module never imports AppKit.
public struct ApplicationIdentity: Sendable, Equatable {

    public var bundleID: String
    public var name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name     = name
    }
}
