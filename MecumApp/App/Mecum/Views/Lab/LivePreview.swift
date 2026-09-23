//
//  LivePreview.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import SeatBroker
import SwiftUI

/// Hosts the kit's AppKit preview view: frames of the adopted window arrive
/// straight into its layer.
struct LivePreview: NSViewRepresentable {

    let session: AgentSession

    func makeNSView(context: Context) -> NSView {
        session.makePreviewView(contentsScale: NSScreen.main?.backingScaleFactor ?? 2)
    }

    func updateNSView(
        _ nsView: NSView,
        context : Context
    ) {}
}
