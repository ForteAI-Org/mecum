//
//  WindowSnapshots+Root.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI

extension WindowSnapshots {

    /// The window's memory as plain state, standing in for the scene storage
    /// `TeamWindowView` keeps.
    struct Root: View {

        let team: TeamModel

        @State var isInspectorRequested: Bool

        var body: some View {
            TeamShellView(
                team                : team,
                isInspectorRequested: $isInspectorRequested
            )
        }
    }
}
