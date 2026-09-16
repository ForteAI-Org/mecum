//
//  MenuImageChoice.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import CoreGraphics
import Foundation
import ScreenCaptureKit
import SeatCore
import Synchronization
import Vision

/// MenuImageChoice finds a requested label in the actual menu image. It belongs to the
/// test's observation layer: the kit still receives only a point. A missing or
/// ambiguous label refuses the choice, because the middle of a menu can be Print.
@MainActor
enum MenuImageChoice {

    static func point(
        for titles: [String],
        in window : WindowReference
    ) throws -> CGPoint {
        let images = Mutex<Result<CGImage, any Error>?>(nil)
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { value, error in
            guard let target = value?.windows.first(where: {
                $0.windowID == CGWindowID(window.windowNumber)
            }) else {
                images.withLock { $0 = .failure(error ?? MenuImageFailure.captureUnavailable) }
                return
            }
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width)
            config.height = Int(window.frame.height)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: target),
                configuration: config
            ) { image, error in
                images.withLock { result in
                    if let image { result = .success(image) }
                    else { result = .failure(error ?? MenuImageFailure.captureUnavailable) }
                }
            }
        }
        guard LivePump.run(until: { images.withLock { $0 != nil } }, timeout: 3),
              let captured = images.withLock({ $0 })
        else { throw MenuImageFailure.captureUnavailable }
        let image = try captured.get()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "it-IT"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let matches = (request.results ?? []).filter {
            guard let text = $0.topCandidates(1).first, text.confidence >= 0.8 else { return false }
            return titles.contains { $0.lowercased() == text.string.lowercased() }
        }
        guard matches.count == 1, let box = matches.first?.boundingBox else {
            throw MenuImageFailure.itemNotIdentified(titles)
        }
        return CGPoint(x: box.midX * window.frame.width, y: (1 - box.midY) * window.frame.height)
    }
}

nonisolated enum MenuImageFailure: Error {
    case captureUnavailable
    case itemNotIdentified([String])
}
