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
/// its updates, and outlives any one pass of the SwiftUI body. The text size
/// is the one View > Bigger and Smaller set, remembered for the app
/// (`TextSizeCommands`), and a change relays out without reloading.
/// `topInset` and `bottomInset` are the heights a floating header and
/// composer cover at the top and bottom.
struct TranscriptHost: NSViewRepresentable {

    let controller: TranscriptController

    var topInset   : CGFloat = 0
    /// The height of what floats over the transcript's bottom edge, the composer,
    /// which the last message scrolls clear of.
    var bottomInset: CGFloat = 0

    @AppStorage(TextSizeCommands.storageKey)
    private var bodyPointSize = Double(TranscriptStyle.actualSize.bodyPointSize)

    func makeNSView(context: Context) -> NSView {
        applyStyle()
        let view = controller.view
        // Any width the column gives is fine; the transcript never pushes back horizontally.
        view.setContentHuggingPriority(
            .defaultLow,
            for: .horizontal
        )
        view.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        return view
    }

    func updateNSView(
        _ view : NSView,
        context: Context
    ) {
        applyStyle()
    }

    /// Takes what it is offered and asks for no size of its own, so its minimum
    /// is zero whatever width the last layout gave it.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView    : NSView,
        context   : Context
    ) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }

    private func applyStyle() {
        let style = TranscriptStyle(bodyPointSize: CGFloat(bodyPointSize))
        if controller.style != style { controller.style = style }
        if controller.topInset != topInset { controller.topInset = topInset }
        if controller.bottomInset != bottomInset { controller.bottomInset = bottomInset }
    }
}
