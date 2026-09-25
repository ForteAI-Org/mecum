//
//  ShellChrome.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation

/// ShellChrome decides what the team window's chrome says about the selected
/// worker (§3.4): the header at the leading edge of the title bar, the
/// window's title, and the controls the toolbar keeps.
///
/// The header is the only place the worker's name is drawn above the
/// conversation. The window title still carries it, so Mission Control and the
/// Window menu name the window, but the toolbar shows no title beside the header.
/// The header has no status line: the sidebar row already says what the worker
/// is doing, and no fact is shown twice.
nonisolated enum ShellChrome {

    /// A control that belongs to the window rather than to a worker. There is
    /// no sidebar toggle: the sidebar turns compact and is never hidden.
    enum ToolbarControl: Sendable, Hashable, CaseIterable {
        /// The new tokens the worker's turns used, shown once it has recorded one.
        case tokenCounter

        /// Moves the worker's live screen between the inspector and the top right of the conversation.
        case screenToggle
        case inspectorToggle
    }

    /// What the header shows for one worker.
    struct Header: Sendable, Hashable {
        let workerID  : UUID
        let name      : String
        let appearance: WorkerAppearance
    }

    /// The window's title when no worker is selected: the app's scene name.
    static let untitled = "Mecum"

    /// Everything the toolbar holds, in order. Worker actions live with the
    /// worker (the composer, the menu bar, the row's context menu), not here.
    static let toolbar: [ToolbarControl] = [
        .tokenCounter,
        .screenToggle,
        .inspectorToggle,
    ]

    /// The header for the selected worker, or nil when none is selected.
    static func header(for worker: WorkerSnapshot?) -> Header? {
        worker.map { Header(workerID: $0.id, name: $0.name, appearance: $0.appearance) }
    }

    /// The window's title: the selected worker's name, or `untitled`.
    static func windowTitle(for worker: WorkerSnapshot?) -> String {
        worker?.name ?? untitled
    }
}
