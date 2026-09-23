//
//  ShellChrome.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation
import Workspace

/// ShellChrome decides what the team window's chrome says about the selected
/// worker (§3.4): the header floating at the conversation's top centre, the
/// window's title, and the controls the toolbar keeps.
///
/// The header is the only place the worker's name is drawn above the
/// conversation. The window title still carries it, so Mission Control and the
/// Window menu name the window, but the toolbar shows no title beside the header.
/// The header has no status line: the sidebar row already says what the worker
/// is doing, and no fact is shown twice.
public enum ShellChrome {

    /// A control that belongs to the window rather than to a worker.
    public enum ToolbarControl: Sendable, Hashable, CaseIterable {
        case sidebarToggle
        case inspectorToggle
    }

    /// What the header shows for one worker.
    public struct Header: Sendable, Hashable {
        public let workerID  : UUID
        public let name      : String
        public let appearance: WorkerAppearance

        /// What VoiceOver says on top of the name: activating the header opens the details.
        public var accessibilityHint: String { "Shows \(name)'s details" }
    }

    /// The window's title when no worker is selected: the app's scene name.
    public static let untitled = "Mecum"

    /// Everything the toolbar holds, in order. Worker actions live with the
    /// worker (the composer, the menu bar, the row's context menu), not here.
    public static let toolbar: [ToolbarControl] = [.sidebarToggle, .inspectorToggle]

    /// The header for the selected worker, or nil when none is selected.
    public static func header(for worker: WorkerSnapshot?) -> Header? {
        worker.map { Header(workerID: $0.id, name: $0.name, appearance: $0.appearance) }
    }

    /// The window's title: the selected worker's name, or `untitled`.
    public static func windowTitle(for worker: WorkerSnapshot?) -> String {
        worker?.name ?? untitled
    }
}
