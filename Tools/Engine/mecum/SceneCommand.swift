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

/// SceneCommand perceives the interaction window once, records it as the call's sample, teaches the
/// brain what it saw, and prints the text map a model would read, or the scene's JSON with `--json`,
/// enriched from memory.
enum SceneCommand {

    static func run(_ invocation: Invocation) async throws {
        let application = try ApplicationLookup.running(try invocation.positional(0, "<app>"))
        let memory = await CLIMemory.open(invocation)
        do {
            if invocation.flags.contains("seat") {
                try await SeatRuntime.withSeat(application, invocation) { seat in
                    try await perceive(application, Runtime(invocation: invocation, seat: seat, memory: memory), invocation)
                }
            } else {
                try await perceive(application, Runtime(invocation: invocation, memory: memory), invocation)
            }
        } catch {
            await memory.close()
            throw error
        }
        await memory.close()
    }

    private static func perceive(_ application: NSRunningApplication, _ runtime: Runtime,
                                 _ invocation: Invocation) async throws {
        let call = CLICall(memory: runtime.memory, request: .observe, context: CLITrace().context(.observe),
                           app: AppContextIdentity(application))
        try await call.begin()
        let started = ContinuousClock.now
        let perceived: PerceivedWindow
        do {
            perceived = try await runtime.scenes.currentScene(of: application.processIdentifier)
        } catch {
            await call.fail(error)
            throw error
        }
        let elapsed = started.duration(to: .now)
        // Every look teaches the brain, as the watcher's did; the map printed is the enriched one.
        let recorder = runtime.recorder(for: call.context, sessionRevision: 1)
        let scene = await recorder.observe(perceived)
        let report = await recorder.report()
        if invocation.flags.contains("json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            print(String(decoding: try encoder.encode(scene), as: UTF8.self))
        } else {
            print(scene.text())
        }
        let frame = perceived.frame
        let size = "\(Int(frame.width))×\(Int(frame.height)) pt"
        let summary = "perceived \(scene.elements.count) elements in \(elapsed), frame \(size), token \(scene.token), "
            + "capture \(perceived.capture.completeness.rawValue)"
        CLIMemory.say(summary)
        call.say(report)
        await call.complete(call.observationResult(from: report))
    }
}
