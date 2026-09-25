//
//  FirstLaunchView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI

/// The first launch offers the two things there are to do. It invents no
/// team, and it asks for no desktop permission: talking to a worker never
/// needed one.
struct FirstLaunchView: View {

    let team: TeamModel

    var body: some View {
        ContentUnavailableView {
            Label(
                "Create Your First Worker",
                systemImage: "person.2"
            )
        } description: {
            Text("Add a worker, then connect a provider. Mecum asks for Mac permissions only when a worker needs them.")
        } actions: {
            Button("Create Worker") { team.isCreatingWorker = true }
                .buttonStyle(.borderedProminent)

            Button("Connect Provider…") { team.isShowingConnections = true }
        }
    }
}
