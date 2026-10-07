//
//  SeatActuator.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import CoreGraphics
import EngineCore
import Foundation
#if MECUM_PHASES
import PhaseSignposts
#endif
import SeatCapture
import SeatCore
import SeatInput
import SeatSession

/// SeatActuator is `Actuating` over the Seat: every gesture becomes one Command admitted under one
/// Observation Reference inside a Turn, and the receipts are kept until the engine says what it saw.
/// `confirm` answers each receipt with that verdict and gives the Turn back, which is the Seat's own
/// rule: an event that went out is never repeated, and a Turn is released only once every Command is
/// confirmed. One action's gestures share one Turn.
///
/// A Command is addressed by the observation it was decided on, never by a window, and a complete
/// Command consumes it. So the first gesture of an action rides the observation the scene was
/// perceived from, and each gesture after it takes a new one: the engine's actions are successions
/// of gestures, and the succession is the consumer's to orchestrate.
///
/// A click is routed only through that observation's own window geometry, so a point outside the
/// observed window, or outside the region a hosted sheet's picture covers, is refused rather than
/// posted somewhere: pop-ups are chosen with the keyboard, and the engine already does so. The
/// application is never activated; the seat never raises anything.
public actor SeatActuator: Actuating {

    private let target: SeatTarget
    private var turn: Turn?
    private var receipts: [InputReceipt] = []

    public init(target: SeatTarget) {
        self.target = target
    }

    public func perform(_ gesture: Gesture, in processID: pid_t) async throws {
        #if MECUM_PHASES
        let preparing = PhaseInterval.begin("delivery.prepare")
        #endif
        let seat = try await target.agentSeat()
        let turn = try await heldTurn(on: seat)
        let observation = try await target.currentObservation()
        #if MECUM_PHASES
        preparing.end()
        let delivery = PhaseInterval.begin("delivery")
        defer { delivery.end() }
        #endif
        switch gesture {
            case .click(let point, let button, let count):
                guard (1...InputCommand.maximumClickCount).contains(count) else {
                    throw SeatDrivingFailure.gestureUnsupported("a \(count)-click")
                }
                let location = try routed(point, in: observation)
                let mouse: SeatCore.MouseButton = button == .left ? .left : .right
                receipts.append(try await seat.send(
                    .click(location, button: mouse, count: count),
                    observation: observation.reference,
                    turn       : turn
                ))
            case .scroll(let point, let deltaY, _):
                let location = try routed(point, in: observation)
                receipts.append(try await seat.send(
                    .scroll(location, deltaY: Int32(deltaY)),
                    observation: observation.reference,
                    turn       : turn
                ))
            case .key(let code, let modifiers):
                let shortcut = Shortcut(.virtualKey(CGKeyCode(code)), holding: Self.modifiers(modifiers))
                receipts.append(try await seat.send(shortcut, observation: observation.reference, turn: turn))
            case .character(let character, let modifiers):
                // The seat resolves a character through the installed layout, as a menu matches it.
                let shortcut = Shortcut.character(character, holding: Self.modifiers(modifiers))
                receipts.append(try await seat.send(shortcut, observation: observation.reference, turn: turn))
            case .type(let text):
                receipts.append(try await seat.send(.text(text), observation: observation.reference, turn: turn))
            case .insert(let text):
                receipts.append(try await seat.send(.insertText(text), observation: observation.reference, turn: turn))
            case .drag(let start, let end):
                // Both ends are routed under the one observation, so a drag leaving the window is refused.
                let path = InputCommand.drag(
                    from: try routed(start, in: observation),
                    to  : try routed(end, in: observation)
                )
                receipts.append(try await seat.send(path, observation: observation.reference, turn: turn))
        }
        // The events are out: the observation they rode has spent its authority and the next
        // gesture needs a new one.
        await target.spendObservation()
    }

    /// A seat that refuses a confirmation or a release has already failed its Turn and reports that
    /// on its own event stream; there is nothing more to do from here, so those errors are dropped.
    public func confirm(_ effect: DeliveryEffect, in processID: pid_t) async {
        #if MECUM_PHASES
        let confirming = PhaseInterval.begin("delivery.confirm")
        defer { confirming.end() }
        #endif
        guard let turn else { return }
        let confirmation: EffectConfirmation = switch effect {
            case .observed: .observed
            case .absent  : .absent
            case .unknown : .unknown
        }
        if let seat = try? await target.agentSeat() {
            for receipt in receipts { try? await seat.confirm(receipt, confirmation) }
            try? await seat.release(turn)
        }
        receipts = []
        self.turn = nil
    }

    private func heldTurn(on seat: AgentSeat) async throws -> Turn {
        if let turn { return turn }
        let acquired = try await seat.acquire()
        turn = acquired
        return acquired
    }

    /// The point under the observation the Command will be admitted with, or a refusal when it
    /// falls outside the window that observation is of, or outside the region its picture covers.
    private func routed(_ point: CGPoint, in observation: SeatObservationDelivery) throws -> InputLocation {
        let region: CGRect? = if case .attestedWindowRegion? = observation.captureTarget {
            observation.frame.geometry.screenRect
        } else {
            nil
        }
        guard let location = Self.location(of: point, in: observation.geometry, region: region) else {
            throw SeatDrivingFailure.pointOutsideTarget(point)
        }
        return location
    }

    /// A point inside the observed window, or inside the region a hosted sheet's picture covers. A
    /// sheet can extend past its host (TextEdit's Save sheet, 05/10/2026, once expanded), and the
    /// picture covers both: such a point keeps the host's geometry, and the seat admits it against
    /// the sheet's own attested frame or refuses it.
    static func location(
        of point   : CGPoint,
        in geometry: WindowGeometryObservation,
        region     : CGRect?
    ) -> InputLocation? {
        if let location = InputLocation(screenPoint: point, observedIn: geometry) { return location }
        guard let region, point.x.isFinite, point.y.isFinite,
              point.x >= region.minX, point.y >= region.minY, point.x < region.maxX, point.y < region.maxY
        else { return nil }
        let origin = geometry.window.frame.origin
        return InputLocation(
            screenPoint       : point,
            windowPointFromTop: CGPoint(x: point.x - origin.x, y: point.y - origin.y),
            observedIn        : geometry
        )
    }

    private static func modifiers(_ modifiers: KeyModifiers) -> Modifiers {
        var held: Modifiers = []
        if modifiers.contains(.command) { held.insert(.command) }
        if modifiers.contains(.shift)   { held.insert(.shift) }
        if modifiers.contains(.option)  { held.insert(.option) }
        if modifiers.contains(.control) { held.insert(.control) }
        return held
    }
}
