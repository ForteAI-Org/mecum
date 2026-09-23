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
                "No team yet",
                systemImage: "person.2"
            )
        } description: {
            Text(
                """
                Create the first worker, then connect a model. Nothing is created for you, and no desktop \
                permission is needed to talk to a worker.
                """
            )
        } actions: {
            Button("Create the first worker") { team.isCreatingWorker = true }
                .buttonStyle(.borderedProminent)

            Button("Connect a model") { team.isShowingConnections = true }
        }
    }
}
