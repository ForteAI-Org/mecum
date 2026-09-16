//
//  WindowPlacing+Frame.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import CoreGraphics
import SeatCore

nonisolated extension WindowPlacing {
    /// A custom placer that cannot read the body refuses thumbnail returns.
    public func frame(of window: WindowReference) throws -> CGRect? { nil }
}
