//
//  BrainFixture.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import AutomationRuntime
import CoreGraphics
import EngineCore
import Foundation
import Memory
import PerceptionCore

/// BrainFixture prepares a living memory for the snapshot run and the app's tests in a directory
/// the caller names, through the real APIs a worker's session records with: a `MemoryService`, the
/// Brain's seams over it and a `CallRecorder` per observation, which writes each observation's event,
/// its `current` sample and the Brain's ingest. Nothing is written by hand and no JSON is involved.
/// The person's own memory is never touched: the directory is the caller's, normally temporary.
enum BrainFixture {

    static let bundleID = "com.apple.TextEdit"

    /// Records two observations of a small window of `bundleID` and closes the service; answers the directory.
    @discardableResult
    static func prepare(in directory: URL, bundleID: String = BrainFixture.bundleID) async -> URL {
        let memory = MemoryService(directory: directory)
        let clock  = memory.clock
        let brain  = BrainMemory(brains: memory, applications: memory, clock: { clock.brainNow() })
        let app    = AppContextIdentity(bundleID: bundleID, version: "1.0")
        for (index, labels) in [["Bold", "Italic", "Underline", "Save", "Cancel"],
                                ["Bold", "Italic", "Underline", "Save", "Cancel", "Format"]].enumerated() {
            let context = ActionContext(eventID: "snapshot-observation-\(index)", source: .app, streamID: "snapshot",
                                        traceID: "snapshot-trace", sessionID: "snapshot-session")
            let recorder = CallRecorder(memory: memory, brain: brain, context: context, sessionRevision: Int64(index + 1),
                                        requestedAt: clock.brainNow())
            _ = await recorder.observe(window(labels, bundleID: bundleID), recordingObservationOf: app)
        }
        await memory.close()
        return directory
    }

    private static func window(_ labels: [String], bundleID: String) -> PerceivedWindow {
        let elements = labels.enumerated().map { index, label in
            SceneElement(id: "control|\(label.lowercased())", kind: .control, label: label,
                         bounds: NormalizedRect(x: 0.05 + Double(index) * 0.15, y: 0.1, width: 0.12, height: 0.05),
                         role: "AXButton")
        }
        let scene = SceneSnapshot(bundleID: bundleID, appName: "TextEdit", windowTitle: "Untitled",
                                  viewportPixelSize: ViewportPixelSize(width: 1000, height: 800), elements: elements)
        let quality = CaptureQuality(walkCompleted: true, windowFound: true, isGrantAvailable: true, windowRole: "AXWindow",
                                     nodesVisited: labels.count + 2, elementsEmitted: labels.count)
        return PerceivedWindow(scene: scene, frame: CGRect(x: 0, y: 0, width: 800, height: 600), capture: quality, surface: .window)
    }
}
