//
//  PremiereSceneBoundaryTests.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import AccessibilityFacts
import CoreGraphics
import Foundation
import Perception
import PerceptionCore
import ScreenCaptureKit
import Testing
import VisionText
import WindowServerListing

/// The adapters are proven at their boundary, on a Mac with the app running. Named apart from the
/// Driver layer's Live tier on purpose: `make live-tests` filters on `LiveTests` and asserts a count. Prerequisites: Adobe
/// Premiere open with a window on screen, Screen Recording and Accessibility granted to the process
/// that runs the tests, and `MECUM_LIVE_TESTS=1` in the environment. Without the variable the suite is
/// skipped, so a headless run stays green and never pretends it saw a screen.
@Suite("Boundary: Premiere scene", .enabled(if: ProcessInfo.processInfo.environment["MECUM_LIVE_TESTS"] == "1"))
struct PremiereSceneBoundaryTests {

    private func premiereProcessID() -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        return list.first { ($0[kCGWindowOwnerName as String] as? String)?.hasPrefix("Adobe Premiere") == true }
            .flatMap { $0[kCGWindowOwnerPID as String] as? pid_t }
    }

    /// One still of the window through ScreenCaptureKit, at the window's own pixel size. A capture
    /// adapter proper arrives with the Seat's capture; this is the boundary check's own eye.
    private func capture(windowNumber: Int, frame: CGRect) async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { Int($0.windowID) == windowNumber }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(max(1, filter.pointPixelScale))
        let configuration = SCStreamConfiguration()
        configuration.width = Int(frame.width * scale)
        configuration.height = Int(frame.height * scale)
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    @Test("the pipeline perceives Premiere's interaction window with Vision and accessibility")
    func perceivePremiere() async throws {
        let processID = try #require(premiereProcessID(), "Adobe Premiere is not running with a window on screen")
        let rows = try WindowServerWindowListing().windows(ownedBy: processID)
        let surfaces = WindowSurfaceClassifier.classify(rows)
        let target = try #require(surfaces.interaction, "no interaction window among \(rows.count) rows")
        print("windows (front to back):")
        for verdict in surfaces.verdicts {
            print("  #\(verdict.row.number) layer \(verdict.row.layer) \(verdict.kind.rawValue) \(Int(verdict.row.frame.width))×\(Int(verdict.row.frame.height)) @ \(Int(verdict.row.frame.minX)),\(Int(verdict.row.frame.minY)) \"\(verdict.row.title ?? "")\": \(verdict.why)")
        }
        print("driving: #\(target.number) \"\(target.title ?? "")\" popups: \(surfaces.popups.count)")

        let image = try #require(
            try await capture(windowNumber: target.number, frame: target.frame), "capture failed (Screen Recording?)"
        )
        print("captured \(image.width)×\(image.height) px for a \(Int(target.frame.width))×\(Int(target.frame.height)) pt window")

        let started = ContinuousClock.now
        let harvested = try await AccessibilityAugmenter().augmentation(for: processID, windowFrame: target.frame)
        let axDuration = started.duration(to: .now)
        print("accessibility harvest: \(harvested.count) elements in \(axDuration)")
        for element in harvested.prefix(40) {
            let state = element.state.map { " [\($0.rawValue)]" } ?? ""
            print("  \(element.role ?? "?") \(element.label)\(state) @ \(String(format: "%.3f,%.3f", element.bounds.x, element.bounds.y))")
        }

        let pipeline = ScenePipeline(text: VisionTextRecognizer(), augmentation: AccessibilityAugmenter())
        let window = ScenePipeline.Window(
            bundleID : "com.adobe.PremierePro",
            appName  : "Adobe Premiere",
            title    : target.title ?? "",
            processID: processID,
            frame    : target.frame
        )
        let perceiveStart = ContinuousClock.now
        let scene = try await pipeline.perceive(image, of: window)
        print("perceived \(scene.elements.count) elements in \(perceiveStart.duration(to: .now)) token \(scene.token)")
        print(scene.text())

        #expect(!scene.elements.isEmpty, "a live Premiere window must yield elements")
        #expect(scene.viewportPixelSize.width == image.width)
        let untrusted = harvested.filter { !AccessibilityFrameTrust.isTrustworthy($0.bounds.pixelBox(in: CGSize(width: 1, height: 1)), in: CGRect(x: 0, y: 0, width: 1, height: 1)) }
        #expect(untrusted.isEmpty, "every harvested element is normalized inside the window by construction")
    }
}
