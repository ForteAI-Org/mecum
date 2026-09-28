//
//  BrainAppView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import SwiftUI

/// BrainAppView is one application's Brain, pushed from the list of
/// applications with the application's name as its title: a graph that
/// moves and can be played as it grew, or a list. The window's toolbar
/// switches between the two, as a Finder window switches its views.
///
/// The simulation is made once the page appears and kept while it is open, so
/// going to the list and back finds the graph as it was left.
struct BrainAppView: View {

    enum Mode {
        case graph
        case list
    }

    let app: BrainApp

    @State private var mode = Mode.graph

    @State private var simulation: BrainSimulation?

    var body: some View {
        Group {
            switch mode {
            case .graph:
                if let simulation {
                    BrainGraphView(simulation: simulation)
                } else {
                    Color.clear
                }
            case .list:
                BrainListView(brain: app.brain)
            }
        }
        .navigationTitle(app.name)
        .toolbar {
            ToolbarItem {
                Picker(
                    "View",
                    selection: $mode.animation(.easeInOut(duration: 0.2))
                ) {
                    Label(
                        "Graph",
                        systemImage: "point.3.connected.trianglepath.dotted"
                    )
                    .tag(Mode.graph)

                    Label(
                        "List",
                        systemImage: "list.bullet"
                    )
                    .tag(Mode.list)
                }
                .pickerStyle(.segmented)
                .help("Show the Brain as a graph or list.")
            }
        }
        .task {
            if simulation == nil { simulation = await BrainSimulation.settled(BrainGraph(brain: app.brain)) }
        }
    }
}
