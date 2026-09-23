//
//  Shimmer.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI

/// Shimmer is how the app says something is on its way, in place of a
/// spinning wheel: a soft band of light passes over the content's own shape,
/// once every 1.2 seconds. Under Reduce Motion the band stays still and the
/// content alone says it is loading.
struct Shimmer: ViewModifier {

    @Environment(\.accessibilityReduceMotion)
    private var reducesMotion

    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { proxy in
                    let band = max(
                        40,
                        proxy.size.width * 0.5
                    )
                    LinearGradient(
                        colors    : [.clear, .white.opacity(0.55), .clear],
                        startPoint: .leading,
                        endPoint  : .trailing
                    )
                    .frame(width: band)
                    .offset(x: -band + phase * (proxy.size.width + band))
                }
                .mask(content)
                .blendMode(.plusLighter)
                .opacity(reducesMotion ? 0 : 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .onAppear {
                guard !reducesMotion else { return }

                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}
