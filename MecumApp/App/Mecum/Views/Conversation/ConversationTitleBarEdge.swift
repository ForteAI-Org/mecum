//
//  ConversationTitleBarEdge.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import SwiftUI

/// The soft edge the messages fade under at the title bar, as a system scroll
/// view gets on its own: the system gives that edge only to SwiftUI's scroll
/// views, and the transcript is an AppKit one. It is the bar's material,
/// solid under the bar and fading out just below it, and it takes no clicks.
struct ConversationTitleBarEdge: View {

    let titleBarHeight: CGFloat

    var body: some View {
        Rectangle()
            .fill(.bar)
            .mask {
                LinearGradient(
                    stops     : [
                        .init(
                            color   : .black,
                            location: 0
                        ),
                        .init(
                            color   : .black,
                            location: 0.6
                        ),
                        .init(
                            color   : .clear,
                            location: 1
                        ),
                    ],
                    startPoint: .top,
                    endPoint  : .bottom
                )
            }
            .frame(height: titleBarHeight + 20)
            .ignoresSafeArea(
                .container,
                edges: .top
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
