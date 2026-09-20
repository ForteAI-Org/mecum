import AutomationRuntime
//
//  WindowsCommand.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import AppKit
import CoreGraphics
import PerceptionCore
import WindowServerListing

/// WindowsCommand prints the window census the engine would drive from: every row front to back,
/// its verdict and why, then which one is the interaction window and how many pop-ups are open.
enum WindowsCommand {

    static func run(_ invocation: Invocation) async throws {
        let application = try ApplicationLookup.running(try invocation.positional(0, "<app>"))
        let rows = try WindowServerWindowListing().windows(ownedBy: application.processIdentifier)
        let surfaces = WindowSurfaceClassifier.classify(rows)
        let name = application.localizedName ?? "?", bundle = application.bundleIdentifier ?? "?"
        print("\(name) (\(bundle), pid \(application.processIdentifier))")
        print("windows, front to back:")
        for verdict in surfaces.verdicts {
            let frame = verdict.row.frame
            let size = "\(Int(frame.width))×\(Int(frame.height)) @ \(Int(frame.minX)),\(Int(frame.minY))"
            let row = verdict.row
            let head = "  #\(row.number) layer \(row.layer) \(verdict.kind.rawValue) \(size)"
            print("\(head) \"\(row.title ?? "")\": \(verdict.why)")
        }
        if let target = surfaces.interaction {
            print("driving: #\(target.number) \"\(target.title ?? "")\", open pop-ups: \(surfaces.popups.count)")
        } else {
            print("driving: nothing, no interaction window among \(rows.count) rows")
        }
    }
}
