//
//  WindowClickCheck+ProbedRoot.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Observation
import SwiftUI

extension WindowClickCheck {

    /// The window's inspector request, readable from outside the shell.
    @Observable
    final class Probe {

        var isInspectorRequested = false
    }

    struct ProbedRoot: View {

        let team : TeamModel
        let probe: Probe

        var body: some View {
            TeamShellView(
                team                : team,
                isInspectorRequested: Binding(
                    get: { probe.isInspectorRequested },
                    set: { probe.isInspectorRequested = $0 }
                )
            )
        }
    }
}
