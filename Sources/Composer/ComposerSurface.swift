//
//  ComposerSurface.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI

/// ComposerSurface is what the composer's pill floats on (§3.2): Liquid Glass
/// on macOS 26 and later, an Apple material before it, and an opaque surface
/// when Reduce Transparency is on, so nothing behind the pill shows through.
///
/// The glass is SwiftUI's `glassEffect`, applied to the pill's content, which
/// includes the AppKit text view: SwiftUI draws the glass behind that content
/// and leaves the hosted view on top, editing and first responder included.
/// The material is SwiftUI's `regularMaterial`, the system material in SwiftUI.
struct ComposerSurface: ViewModifier {

    enum Kind: CaseIterable {
        case glass
        case material
        case solid

        /// The platform's kind: glass unless Reduce Transparency is on.
        static func resolved(reducesTransparency: Bool) -> Kind {
            if reducesTransparency { return .solid }
            if #available(macOS 26, *) { return .glass }
            // Never reached while the deployment target is macOS 26; kept for an earlier target.
            return .material
        }
    }

    /// The pill's outline: a capsule at one line, which keeps its ends as the field grows.
    let shape: RoundedRectangle

    let kind: Kind

    func body(content: Content) -> some View {
        switch kind {
        case .glass:
            if #available(macOS 26, *) {
                content.glassEffect(.regular, in: shape)
            } else {
                floating(content, on: AnyShapeStyle(.regularMaterial))
            }
        case .material:
            floating(content, on: AnyShapeStyle(.regularMaterial))
        case .solid:
            floating(content, on: AnyShapeStyle(Color(nsColor: .windowBackgroundColor)))
        }
    }

    /// A container lifted off the transcript by a hairline and a soft shadow.
    private func floating(_ content: Content, on fill: AnyShapeStyle) -> some View {
        content
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}
