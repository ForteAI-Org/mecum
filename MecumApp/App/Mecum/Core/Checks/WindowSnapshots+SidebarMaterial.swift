//
//  WindowSnapshots+SidebarMaterial.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import SwiftUI

extension WindowSnapshots {

    /// The sidebar material, behind the sidebar drawn alone, standing in for
    /// the glass the split's column gives it in a window. Offscreen it draws
    /// the grey the list used to draw there.
    struct SidebarMaterial: NSViewRepresentable {

        func makeNSView(context: Context) -> NSVisualEffectView {
            let view = NSVisualEffectView()
            view.material     = .sidebar
            view.blendingMode = .behindWindow
            return view
        }

        func updateNSView(
            _ view : NSVisualEffectView,
            context: Context
        ) {}
    }
}
