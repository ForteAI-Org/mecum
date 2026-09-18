//
//  RouteStep.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

/// RouteStep is one replayable step: a verb call by semantic target, never a coordinate. Typed text
/// is never stored; a type step may only be the Return-only confirmation.
public struct RouteStep: Sendable, Equatable, Codable {

    /// The tool: `act`, `run_menu`, `reach`, `type`, `focus_app` or `launch_app`.
    public var tool: String
    /// The act or reach target, a type step's focus target, or the application to focus.
    public var target: String?
    /// The act verb.
    public var verb: String?
    /// The desired state of a toggle set.
    public var value: String?
    /// The menu path of a menu step.
    public var path: String?
    /// True for the Return-only type step.
    public var submit: Bool?
    /// The effect family observed when learned: a verification hint, not a gate.
    public var expect: String?
    /// The letters family of the window title after this step ran when learned. The last step's value
    /// is the route's end state, which makes replay idempotent.
    public var afterTitle: String?

    public init(
        tool      : String,
        target    : String? = nil,
        verb      : String? = nil,
        value     : String? = nil,
        path      : String? = nil,
        submit    : Bool? = nil,
        expect    : String? = nil,
        afterTitle: String? = nil
    ) {
        self.tool       = tool
        self.target     = target
        self.verb       = verb
        self.value      = value
        self.path       = path
        self.submit     = submit
        self.expect     = expect
        self.afterTitle = afterTitle
    }

    /// The identity of the action itself, ignoring observational fields, used to decide whether a
    /// re-saved route is the same way (evidence grows) or a new procedure (evidence resets).
    public var actionKey: String {
        [tool, target ?? "", verb ?? "", value ?? "", path ?? "", submit == true ? "⏎" : ""].joined(separator: "|")
    }

    /// A human one-liner such as "act click 'Export'".
    public var summary: String {
        switch tool {
            case "act"      : "act \(verb ?? "click") '\(target ?? "?")'\(value.map { " → \($0)" } ?? "")"
            case "run_menu" : "run_menu '\(path ?? "?")'"
            case "reach"    : "reach '\(target ?? "?")'"
            case "type"     : "press Return\(target.map { " (focus '\($0)')" } ?? "")"
            case "focus_app": "focus app '\(target ?? "?")'"
            default         : tool
        }
    }
}
