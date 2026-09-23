//
//  TranscriptHost.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import SwiftUI
import Transcript

/// TranscriptHost puts the AppKit transcript in the SwiftUI shell (§12.1).
///
/// It only hosts: the controller owns the collection view, its windows and
/// its updates, and outlives any one pass of the SwiftUI body.
struct TranscriptHost: NSViewRepresentable {

    let controller: TranscriptController

    func makeNSView(context: Context) -> NSView { controller.view }

    func updateNSView(_ view: NSView, context: Context) {}
}
