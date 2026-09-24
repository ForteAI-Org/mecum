//
//  SidebarSettings.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import SwiftUI

/// SidebarSettings is what the team's sidebar shows beside each worker's
/// name, and whether it has a field to find a worker.
struct SidebarSettings: View {

    @AppStorage(AppPreferences.sidebarShowsModel)
    private var showsModel = AppPreferences.sidebarShowsModelDefault

    @AppStorage(AppPreferences.sidebarShowsUnreadCount)
    private var showsUnreadCount = AppPreferences.sidebarShowsUnreadCountDefault

    @AppStorage(AppPreferences.sidebarShowsSearch)
    private var showsSearch = AppPreferences.sidebarShowsSearchDefault

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Show the model under the name",
                    isOn: $showsModel
                )
                Toggle(
                    "Show unread counts",
                    isOn: $showsUnreadCount
                )
            } footer: {
                Text("What a worker is doing and a failed turn are shown either way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(
                    "Show the search field",
                    isOn: $showsSearch
                )
            } footer: {
                Text("The compact sidebar has no search field.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
