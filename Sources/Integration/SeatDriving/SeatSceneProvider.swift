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
public struct SeatSceneProvider: SceneProviding {

    private let target: SeatTarget
    private let pipeline: ScenePipeline
    private let windows: any WindowListing
    private let identity: @Sendable (pid_t) -> ApplicationIdentity?

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
        #if MECUM_PHASES
        let perceiving = PhaseInterval.begin("pipeline")
        #endif
        let scene = try await pipeline.perceive(image, of: window)
        #if MECUM_PHASES
        perceiving.end()
        #endif
        await MainActor.run { target.lastSceneImage = image }
        return PerceivedWindow(scene: scene, frame: frame)
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
