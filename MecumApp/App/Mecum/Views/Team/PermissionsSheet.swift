//
//  PermissionsSheet.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import SeatBroker
import SwiftUI

/// PermissionsSheet asks for the macOS permissions a worker needs to use this Mac, from the team
/// window: a title, a sentence on why, the permissions (`PermissionsSection`) and Done.
///
/// The first launch opens it once by itself, so the permissions are asked for before a worker
/// first needs them; Mac Access on the first launch screen and This Mac in Settings reach the same
/// rows later. Nothing here is required: text conversations work without any of them.
struct PermissionsSheet: View {

    let broker: SeatBroker

    @Environment(\.dismiss)
    private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(
                alignment: .leading,
                spacing  : 6
            ) {
                Text("Mac Access")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)

                Text("Workers open and use apps on a display of their own, off your screen. macOS asks you to allow each of these once.")
                    .foregroundStyle(.secondary)
                    .fixedSize(
                        horizontal: false,
                        vertical  : true
                    )
            }
            .frame(
                maxWidth : .infinity,
                alignment: .leading
            )
            .padding(
                .horizontal,
                20
            )
            .padding(
                .top,
                20
            )

            Form {
                PermissionsSection(broker: broker)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()

            HStack {
                Spacer()

                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(
                .horizontal,
                20
            )
            .padding(
                .vertical,
                14
            )
        }
        .frame(
            width : 520,
            height: 420
        )
    }
}
