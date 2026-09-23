//
//  WorkerInspectorView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI
import TeamShell
import Workspace

/// WorkerInspectorView is the inspector for the selected worker (§14.2): what
/// it is doing right now and the computer it drives, the model and connection
/// its next turn will use, which is the way into its profile, and its current
/// or last turn as it ran.
///
/// It is a grouped form, the macOS inspector's own shape: one block per part of
/// the flow, label and value in each row, the system's separators between
/// them. The worker's name is small at the top, since the title bar already
/// says it. While the worker has a window open on the computer, its live screen
/// is a block of its own, which can move over the conversation. Colour is kept
/// for state: a dot beside what the worker is doing and how its connection is,
/// and a symbol with every outcome, so nothing depends on colour alone.
///
/// The turn's model and effort are the execution's frozen settings
/// (`TurnSummary`), never the current profile. Memory and the full
/// Capabilities area have no data yet and are left out rather than drawn
/// empty (§21.2).
struct WorkerInspectorView: View {

    let team  : TeamModel
    let worker: WorkerSnapshot

    /// The turn as last read, which `InspectorTurnSection` shows.
    enum TurnReading: Equatable {
        case reading
        case nothingYet
        case read(TurnSummary)
        case failed(String)
    }

    /// What reading the turn again depends on: a new record in the open
    /// conversation, or a turn starting or ending.
    private struct TurnKey: Equatable {
        let workerID : UUID
        let revision : Int
        let isRunning: Bool
    }

    @State private var turn = TurnReading.reading

    var body: some View {
        Form {
            InspectorIdentitySection(worker: worker)
            InspectorNowSection(
                team  : team,
                worker: worker
            )
            InspectorScreenSection(
                team  : team,
                worker: worker
            )
            InspectorModelSection(
                team  : team,
                worker: worker
            )
            InspectorTurnSection(
                worker: worker,
                turn  : turn
            )
        }
        .formStyle(.grouped)
        .task(id: TurnKey(
            workerID : worker.id,
            revision : team.transcriptRevision,
            isRunning: team.isAnswering(worker.id)
        )) {
            await readTurn()
        }
    }

    private func readTurn() async {
        do {
            let summary = try await team.latestTurn(of: worker.id)
            turn = summary.map(TurnReading.read) ?? .nothingYet
        } catch {
            turn = .failed(String(describing: error))
        }
    }
}
