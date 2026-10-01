//
//  StepEvidence.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 28/09/2026.
//

/// StepEvidence is what every typed proof of one step states alike: the application and the window
/// it was recorded in, and the windows whose words may name its context. Each proof keeps its own
/// readings besides, and a higher layer judges a step by those readings, never by the outcome's
/// sentence or by a shared success flag.
///
/// A proof holds no image, coordinate, or session, process or window number.
public protocol StepEvidence: Sendable, Equatable, Codable {

    /// The application's bundle identifier.
    var bundleID: String { get }

    /// The title of the window the step was resolved in: where it started.
    var windowTitle: String { get }

    /// The titles of the windows the step involves, the one it started in first: a request may name
    /// the step's context by their words. A proof whose step can open a window names it too.
    var windowTitles: [String] { get }
}

extension StepEvidence {

    public var windowTitles: [String] { [windowTitle] }
}
