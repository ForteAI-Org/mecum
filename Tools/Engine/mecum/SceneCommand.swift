import AutomationRuntime
//
//  SceneCommand.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import AppKit
import CoreGraphics
import EngineCore
import Foundation
import LiveScenes
import Memory
import PerceptionCore

/// SceneCommand perceives the interaction window once, teaches the brain what it saw, and prints the
/// text map a model would read, or the scene's JSON with `--json`, enriched from memory.
enum SceneCommand {

    static func run(_ invocation: Invocation) async throws {
        let application = try ApplicationLookup.running(try invocation.positional(0, "<app>"))
        if invocation.flags.contains("seat") {
            try await SeatRuntime.withSeat(application, invocation) { seat in
                try await perceive(application, Runtime(invocation: invocation, seat: seat), invocation)
            }
        } else {
            try await perceive(application, Runtime(invocation: invocation), invocation)
        }
    }

    private static func perceive(_ application: NSRunningApplication, _ runtime: Runtime,
                                 _ invocation: Invocation) async throws {
        let started = ContinuousClock.now
        let perceived = try await runtime.scenes.currentScene(of: application.processIdentifier)
        let elapsed = started.duration(to: .now)
        // Every look teaches the brain, as the watcher's did; the map printed is the enriched one.
        let learned = try await runtime.memory.observe(perceived.scene)
        let scene = await runtime.memory.enrich(perceived.scene)
        if invocation.flags.contains("json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            print(String(decoding: try encoder.encode(scene), as: UTF8.self))
        } else {
            print(scene.text())
        }
        let frame = perceived.frame
        let size = "\(Int(frame.width))×\(Int(frame.height)) pt"
        let summary = "perceived \(scene.elements.count) elements in \(elapsed), frame \(size), token \(scene.token); "
            + "brain: \(learned.created) new anchors, \(learned.updated) seen again\n"
        FileHandle.standardError.write(Data(summary.utf8))
        await runtime.finish()
    }
}
