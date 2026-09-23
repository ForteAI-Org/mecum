//
//  ComposerSurface.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI

/// ComposerSurface is what the composer's pill floats on (§3.2): the system's
/// regular material on every macOS version, and an opaque surface when Reduce
/// Transparency is on, so nothing behind the pill shows through. It is never
/// Liquid Glass.
///
/// The material is drawn behind the pill's content, which includes the AppKit
/// text view, so the hosted view stays on top, editing and first responder included.
struct ComposerSurface: ViewModifier {

    enum Kind: CaseIterable {
        case material
        case solid

        /// The material unless Reduce Transparency is on.
        static func resolved(reducesTransparency: Bool) -> Kind {
            reducesTransparency ? .solid : .material
        }
    }

    /// The bar's outline, a rounded rectangle that keeps its corners as the field grows.
    let shape: RoundedRectangle

    let kind: Kind

    func body(content: Content) -> some View {
        switch kind {
        case .material:
            // A white veil over the material lifts the bar a little above the conversation in either theme.
            floating(content.background(Color.white.opacity(0.07), in: shape), on: AnyShapeStyle(.regularMaterial))
        case .solid:
            floating(content, on: AnyShapeStyle(Color(nsColor: .windowBackgroundColor)))
        }
    }

    /// A container lifted off the transcript by a hairline and a soft shadow.
    private func floating(_ content: some View, on fill: AnyShapeStyle) -> some View {
        content
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}
