//
//  ComputerSettings.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import SeatBroker
import SwiftUI

/// ComputerSettings is what a worker needs to use this Mac: the macOS
/// permissions its seat asks for (`PermissionsSection`), and this Mac's build
/// with whether the kit's ledger lists it.
struct ComputerSettings: View {

    let broker: SeatBroker

    @State private var validation: BuildValidation?

    var body: some View {
        Form {
            PermissionsSection(broker: broker)

            if let validation {
                Section {
                    LabeledContent(
                        "macOS",
                        value: "\(validation.productVersion) (\(validation.build))"
                    )
                    LabeledContent("Seat") {
                        if validation.isValidated {
                            Text("Validated")
                        } else {
                            Text("Not Validated")
                                .foregroundStyle(.orange)
                        }
                    }
                } header: {
                    Text("This Mac")
                } footer: {
                    if !validation.isValidated {
                        Text("Workers can still use this Mac, but this macOS build has not been validated. Mecum records that status with each action.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { validation = broker.buildValidation() }
    }
}
