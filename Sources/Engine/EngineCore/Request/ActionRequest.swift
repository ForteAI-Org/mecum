//
//  ActionRequest.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import Foundation
import PerceptionCore

/// ActionRequest is one thing a model asks the engine to do: a verb on a named target in one
/// application's window, optionally narrowed to a panel, optionally as a rehearsal.
public struct ActionRequest: Sendable, Equatable {

    public var processID: pid_t
    public var bundleID: String
    public var appName: String
    /// An element id or a label, resolved live against this instant's scene.
    public var target: String
    public var verb: ActionVerb
    /// A panel name that disambiguates a shared label.
    public var section: String?
    /// The state a `setToggle` must reach. Ignored by other verbs.
    public var desiredState: ControlState?
    /// A rehearsal: resolve and report what would happen, perform nothing.
    public var isDryRun: Bool

    public init(
        processID   : pid_t,
        bundleID    : String,
        appName     : String,
        target      : String,
        verb        : ActionVerb,
        section     : String? = nil,
        desiredState: ControlState? = nil,
        isDryRun    : Bool = false
    ) {
        self.processID    = processID
        self.bundleID     = bundleID
        self.appName      = appName
        self.target       = target
        self.verb         = verb
        self.section      = section
        self.desiredState = desiredState
        self.isDryRun     = isDryRun
    }
}
