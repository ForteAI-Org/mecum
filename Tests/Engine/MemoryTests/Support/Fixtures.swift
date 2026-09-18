//
//  Fixtures.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import Foundation
import Memory
import PerceptionCore

/// Fixtures are the constants and builders the memory suites share.
enum Fixtures {

    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    static let t1 = Date(timeIntervalSince1970: 1_700_000_100)

    static func rect(_ x: Double, _ y: Double, _ width: Double = 0.03, _ height: Double = 0.017) -> NormalizedRect {
        NormalizedRect(x: x, y: y, width: width, height: height)
    }

    static func detection(_ kind: ElementKind, _ label: String, x: Double, y: Double,
                          width: Double = 0.03, height: Double = 0.017, state: ControlState? = nil) -> BrainDetection {
        BrainDetection(kind: kind, label: label, bounds: rect(x, y, width, height), state: state)
    }

    static func observed(_ key: String, _ text: String?, role: String? = "AXButton",
                         bounds: NormalizedRect = rect(0.1, 0.2, 0.1, 0.05), source: ObjectSource = .ax) -> ObservedObject {
        ObservedObject(identityKey: key, selfText: text, role: role, source: source,
                       boundsNormalized: bounds, firstSeen: t0, lastSeen: t0)
    }

    static func step(_ target: String) -> RouteStep { RouteStep(tool: "act", target: target, verb: "click") }

    static let proof = "2 verified steps, none missed"

    /// A bundled fixture file's URL.
    static func url(_ name: String, _ ext: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext) else {
            throw FixtureError.missing("\(name).\(ext)")
        }
        return url
    }

    enum FixtureError: Error { case missing(String) }
}
