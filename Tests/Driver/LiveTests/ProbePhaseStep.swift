//
//  ProbePhaseStep.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import Foundation

/// FixtureWindowRole names one of the two windows the probe's own fixture may
/// create. It is a role inside this experiment and never a statement about an
/// application, a helper process or a surface the kit could drive.
enum FixtureWindowRole: String, Codable, Equatable {

    /// Created and never presented. It exists so the probe can say what an
    /// all-windows reading carries for a surface that was never shown.
    case neverPresented

    /// The window the phases act on: shown, minimized, restored, ordered out,
    /// shown again and closed.
    case phased
}

/// ProbePhaseStep is one requested operation of the probe's plan, in the order
/// the plan runs them. The step is the *request*: what AppKit returned and what
/// the window server did are separate records, and neither is inferred here.
enum ProbePhaseStep: String, Codable, CaseIterable, Equatable {

    case createNeverPresented
    case createPhased
    case makeVisible
    case minimize
    case restore
    case orderOut
    case showAgain
    case close

    /// The plan the Live suite runs. `allCases` is declaration order, and the
    /// order is the experiment: a restore before a minimize would describe a
    /// different phase sequence than the one the report claims.
    static var standardPlan: [ProbePhaseStep] { allCases }

    var role: FixtureWindowRole {
        self == .createNeverPresented ? .neverPresented : .phased
    }

    var isCreation: Bool {
        self == .createNeverPresented || self == .createPhased
    }

    /// The AppKit call the step asks for, recorded next to the local state so a
    /// reader can see the request and the observation as two different facts.
    var requestedCommand: String {
        switch self {
        case .createNeverPresented: "NSWindow(contentRect:styleMask:backing:defer:)"
        case .createPhased        : "NSWindow(contentRect:styleMask:backing:defer:)"
        case .makeVisible         : "orderFront(_:)"
        case .minimize            : "miniaturize(_:)"
        case .restore             : "deminiaturize(_:)"
        case .orderOut            : "orderOut(_:)"
        case .showAgain           : "orderFront(_:)"
        case .close               : "close()"
        }
    }
}
