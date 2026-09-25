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
                    "Show model names",
                    isOn: $showsModel
                )
                Toggle(
                    "Show unread counts",
                    isOn: $showsUnreadCount
                )
            } footer: {
                Text("Current activity and failed turns are always shown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(
                    "Show the search field",
                    isOn: $showsSearch
                )
            } footer: {
                Text("Search is hidden when the sidebar is compact.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
