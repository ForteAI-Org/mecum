//
//  AutomationTool.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 28/09/2026.
//

/// AutomationTool is the closed set of MCP tools `AutomationTools` offers, by the names a model calls
/// them with. A name outside it is not a tool: the adapter refuses it before any effect.
public enum AutomationTool: String, Sendable, CaseIterable {

    case status
    case windows
    case apps
    case openSession  = "open_session"
    case openRecent = "open_recent"
    case observe
    case menus
    case resolveAction = "resolve_action"
    case menu
    case press
    case act
    case select
    case typeText     = "type_text"
    case pressKey     = "press_key"
    case scroll
    case drag
    case contextMenu  = "context_menu"
    case batch
    case closeSession = "close_session"

    /// The tools that deliver an input through the engine, in the order they are listed.
    static let inputs: [AutomationTool] = [.typeText, .pressKey, .scroll, .drag, .contextMenu]

    /// Whether a call needs the current session's id: every tool but the ones that find an application
    /// and open its session.
    var needsSession: Bool {
        switch self {
            case .status, .windows, .apps, .openSession, .openRecent, .menus: false
            default                                    : true
        }
    }

    /// Whether the tool is one step of work a batch may also run: an act, a select, or an input.
    var isStep: Bool {
        self == .act || self == .select || Self.inputs.contains(self)
    }
}
