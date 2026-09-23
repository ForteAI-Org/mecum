//
//  RunHistoryView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import ModelTransports
import SeatBroker
import AppKit
import SwiftUI

/// Every recorded run, newest first. Left: searchable list with outcome,
/// goal, target and when. Right: the run as evidence (outcome, model, budget
/// tiles, the verified step timeline and the last frame the agent saw).
struct RunHistoryView: View {

    let broker: SeatBroker

    @Environment(\.dismiss)
    private var dismiss

    @State
    private var records : [RunRecord] = []
    @State
    private var selected: RunRecord.ID?
    @State
    private var query                 = ""

    private var filtered: [RunRecord] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return records }
        return records.filter {
            $0.goal.localizedCaseInsensitiveContains(q) || $0.app.localizedCaseInsensitiveContains(q)
                || $0.model.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(
                filtered,
                selection: $selected
            ) { record in
                RunListRow(record: record)
                    .tag(record.id)
            }
            .listStyle(.sidebar)
            .searchable(
                text     : $query,
                placement: .sidebar,
                prompt   : "Goal, app or model"
            )
            .navigationSplitViewColumnWidth(
                min  : 280,
                ideal: 320
            )
            .overlay {
                if records.isEmpty {
                    ContentUnavailableView(
                        "No runs yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Every goal you send is recorded here with its verified steps.")
                    )
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        } detail: {
            if let record = filtered.first(where: { $0.id == selected }) ?? records.first(where: { $0.id == selected }) {
                RunDetail(
                    record  : record,
                    frameURL: broker.finalFrameURL(for: record)
                )
                .id(record.id)
            } else {
                ContentUnavailableView(
                    "Select a run",
                    systemImage: "list.bullet.rectangle"
                )
            }
        }
        .frame(
            minWidth : 960,
            minHeight: 620
        )
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            ToolbarItem {
                Button(
                    "Show in Finder",
                    systemImage: "folder"
                ) {
                    NSWorkspace.shared.activateFileViewerSelecting([broker.configuration.recordingDirectory])
                }
                .help("Open the folder with runs.jsonl and the frames")
            }
        }
        .onAppear {
            records  = broker.runHistory()
            selected = records.first?.id
        }
    }
}
