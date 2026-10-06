//
//  ConversationObservedScreen.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/10/2026.
//

import PerceptionCore
import SwiftUI

/// ConversationObservedScreen is what `/observe` read of the worker's window:
/// the frame the scene was read from, every element outlined and tagged with
/// its label, or its id when it has none, as the agent names it. Controls are
/// orange, everything else cyan; the full label is the tag's tooltip.
struct ConversationObservedScreen: View {

    let scene: SceneSnapshot
    let image: CGImage

    var body: some View {
        Image(
            decorative: image,
            scale     : 1
        )
        .resizable()
        .aspectRatio(contentMode: .fit)
        .overlay {
            GeometryReader { geometry in
                let size = geometry.size
                ZStack(alignment: .topLeading) {
                    ForEach(
                        Array(scene.elements.enumerated()),
                        id: \.offset
                    ) { _, element in
                        let color = element.kind == .control ? Color.orange : Color.cyan
                        let name  = element.isUnlabeled ? element.id : element.label
                        let x     = element.bounds.x * size.width
                        let y     = element.bounds.y * size.height

                        Rectangle()
                            .stroke(
                                color,
                                lineWidth: 1
                            )
                            .frame(
                                width : element.bounds.width * size.width,
                                height: element.bounds.height * size.height
                            )
                            .offset(
                                x: x,
                                y: y
                            )

                        Text(name.count > 24 ? name.prefix(23) + "…" : name)
                            .font(.system(
                                size  : 9,
                                weight: .semibold
                            ))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(
                                .horizontal,
                                3
                            )
                            .background(
                                color.opacity(0.85),
                                in: RoundedRectangle(cornerRadius: 3)
                            )
                            .foregroundStyle(.black)
                            .help(name)
                            .offset(
                                x: x,
                                y: y
                            )
                    }
                }
                .frame(
                    width    : size.width,
                    height   : size.height,
                    alignment: .topLeading
                )
            }
        }
        .frame(
            maxWidth : 900,
            maxHeight: 640
        )
        .padding(8)
        .accessibilityLabel("\(scene.appName), \(scene.windowTitle): \(scene.elements.count) elements")
    }
}
