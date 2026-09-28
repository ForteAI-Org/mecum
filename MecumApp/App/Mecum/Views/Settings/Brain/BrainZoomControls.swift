//
//  BrainZoomControls.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import SwiftUI

/// BrainZoomControls are the graph's camera buttons, stacked in its corner as
/// a map has them: closer, farther, and the whole graph framed again. They
/// are there for a mouse as well, which cannot pinch.
struct BrainZoomControls: View {

    let zoomIn : () -> Void
    let zoomOut: () -> Void
    let fit    : () -> Void

    var body: some View {
        VStack(spacing: 0) {
            button(
                "Zoom In",
                systemImage: "plus",
                action     : zoomIn
            )

            Divider()
                .frame(width: 18)

            button(
                "Zoom Out",
                systemImage: "minus",
                action     : zoomOut
            )

            Divider()
                .frame(width: 18)

            button(
                "Zoom to Fit",
                systemImage: "viewfinder",
                action     : fit
            )
        }
        .padding(
            .vertical,
            4
        )
        .modifier(BrainGlass())
    }

    private func button(
        _ title    : String,
        systemImage: String,
        action     : @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(
                title,
                systemImage: systemImage
            )
            .labelStyle(.iconOnly)
            .fontWeight(.medium)
            .frame(
                width : 34,
                height: 30
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(title)
    }
}
