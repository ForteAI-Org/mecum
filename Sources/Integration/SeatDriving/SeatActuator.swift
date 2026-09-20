//
//  SeatActuator.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import CoreGraphics
import EngineCore
import Foundation
import SeatCore
import SeatSession

/// SeatActuator is `Actuating` over the Seat: every gesture becomes one Command posted to the adopted
/// window inside a Turn, and the receipts are kept until the engine says what it saw. `confirm`
/// answers each receipt with that verdict and gives the Turn back, which is the Seat's own rule:
/// an event that went out is never repeated, and a Turn is released only once every Command is
/// confirmed. One action's gestures share one Turn.
///
/// A click is routed only through the last observed window geometry, so a point outside the adopted
/// window is refused rather than posted somewhere: pop-ups are chosen with the keyboard, and the
/// engine already does so. The application is never activated; the seat never raises anything.
public actor SeatActuator: Actuating {

    private let target: SeatTarget
    private var turn: Turn?
    private var receipts: [InputReceipt] = []

    public init(target: SeatTarget) {
        self.target = target
    }

    public func perform(_ gesture: Gesture, in processID: pid_t) async throws {
        let seat = try await target.agentSeat()
        let window = try await target.currentWindow()
        let turn = try await heldTurn(on: seat)
        switch gesture {
            case .click(let point, let button, let count):
                guard count == 1 else { throw SeatDrivingFailure.gestureUnsupported("a \(count)-click") }
                let location = try await routed(point)
                let mouse: SeatCore.MouseButton = button == .left ? .left : .right
                receipts.append(try await seat.send(.click(location, button: mouse), to: window, turn: turn))
            case .scroll(let point, let deltaY, _):
                let location = try await routed(point)
                receipts.append(try await seat.send(.scroll(location, deltaY: Int32(deltaY)), to: window, turn: turn))
            case .key(let code, let modifiers):
                let shortcut = Shortcut(.virtualKey(CGKeyCode(code)), holding: Self.modifiers(modifiers))
                receipts.append(try await seat.send(shortcut, to: window, turn: turn))
            case .type(let text):
                receipts.append(try await seat.send(.text(text), to: window, turn: turn))
        }
    }

    /// A seat that refuses a confirmation or a release has already failed its Turn and reports that
    /// on its own event stream; there is nothing more to do from here, so those errors are dropped.
    public func confirm(_ effect: DeliveryEffect, in processID: pid_t) async {
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

    /// The point under the last window observation, or a refusal when it falls outside the window.
    private func routed(_ point: CGPoint) async throws -> InputLocation {
        guard let geometry = await target.lastWindowGeometry else { throw SeatDrivingFailure.noGeometry }
        guard let location = InputLocation(screenPoint: point, observedIn: geometry) else {
            throw SeatDrivingFailure.pointOutsideTarget(point)
        }
        return location
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
