//
//  WorkerScreenView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import SwiftUI

/// WorkerScreenView hosts the live view of the window a worker drives: the
/// seat's frames arrive straight into its layer, with no copy through SwiftUI.
///
/// The caller mounts it only while `TeamModel.hasScreen` holds and gives it the
/// worker's id as its identity, so another worker, or the same seat given to
/// another worker, always gets a view of its own.
struct WorkerScreenView: NSViewRepresentable {

    let team    : TeamModel
    let workerID: UUID

    func makeNSView(context: Context) -> NSView {
        team.makeScreenView(
            of           : workerID,
            contentsScale: NSScreen.main?.backingScaleFactor ?? 2
        ) ?? NSView()
    }

    func updateNSView(
        _ view : NSView,
        context: Context
    ) {}
}
