//
//  WindowInventoryProbeFixture.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import AppKit
import Foundation

/// ProbeFixtureFailure is what the fixture itself can get wrong. It is never a
/// finding about the window server, about AppKit or about the kit: it says the
/// experiment asked for something this fixture does not do.
enum ProbeFixtureFailure: Error, CustomStringConvertible {

    case alreadyCreated(FixtureWindowRole)
    case notCreated(FixtureWindowRole)
    case unsupported(ProbePhaseStep)

    var description: String {
        switch self {
        case .alreadyCreated(let role): "the \(role.rawValue) window was already created"
        case .notCreated(let role)    : "the \(role.rawValue) window has not been created"
        case .unsupported(let step)   : "this fixture does not implement \(step.rawValue)"
        }
    }
}

/// WindowInventoryProbeFixture owns the two `NSWindow` objects this experiment
/// is about: one that is created and never presented, and one that is shown,
/// minimized, restored, ordered out, shown again and closed.
///
/// Public AppKit only, and only on objects it created itself. It never activates
/// an application, never moves, hides or closes a window it does not own, and
/// never hides applications globally. There is no external fixture, child
/// process, synthetic input, pixel capture, Virtual Display, SPI or symbol table
/// anywhere in it.
///
/// Ownership is registered before the first presentation, which is what makes
/// cleanup possible after a partial startup or a throw. What it reports is what
/// its own objects say about themselves: `isVisible` is AppKit's answer, and a
/// method that returned is not evidence that the window server did anything.
@MainActor
final class WindowInventoryProbeFixture: ProbeWindowOperating {

    let processID = Int(ProcessInfo.processInfo.processIdentifier)

    private let clock: any ProbeClock

    private var windows      : [FixtureWindowToken: NSWindow] = [:]
    private var registered   : [FixtureWindowToken]           = []
    private var presented    : Set<FixtureWindowToken>        = []
    private var creationCount = 0

    init(clock: any ProbeClock) {
        self.clock = clock
    }

    /// Window IDs of the fixture's own windows that already have a number. A
    /// window without one contributes nothing rather than a zero.
    var ownedWindowIDs: Set<Int> {
        Set(windows.values.map(\.windowNumber).filter { $0 > 0 })
    }

    func perform(_ step: ProbePhaseStep) throws -> ProbeWindowLocalState {

        if step.isCreation { return try create(step.role) }

        guard let token = registered.first(where: { $0.role == step.role }),
              let window = windows[token]
        else { throw ProbeFixtureFailure.notCreated(step.role) }

        switch step {
        case .makeVisible, .showAgain:
            presented.insert(token)
            window.orderFront(nil)
        case .minimize:
            window.miniaturize(nil)
        case .restore:
            window.deminiaturize(nil)
        case .orderOut:
            window.orderOut(nil)
        case .close:
            window.close()
        case .createNeverPresented, .createPhased:
            throw ProbeFixtureFailure.unsupported(step)
        }
        return state(of: token)
    }

    /// Releases only the windows this fixture created, checking the deadline
    /// before each request and after the last one.
    ///
    /// Nothing here can report a verified release of a window: `orderOut` and
    /// `close` are requests, and `isVisible` is AppKit answering about AppKit's
    /// object. A window whose close was requested is therefore recorded as an
    /// unverified residue, and the record says unknown and incomplete rather
    /// than inventing a success the probe never observed. The decision itself
    /// lives in `ProbeCleanupSweep`, which is exercised offline.
    func cleanUp(deadlineNanoseconds: UInt64) -> ProbeCleanupRecord {

        var sweep = ProbeCleanupSweep()

        for token in registered {
            guard let window = windows[token] else { continue }

            guard clock.nowNanoseconds < deadlineNanoseconds else {
                sweep.record(.notAttemptedBeforeDeadline, for: token)
                continue
            }
            window.orderOut(nil)

            guard clock.nowNanoseconds < deadlineNanoseconds else {
                sweep.record(.interruptedByDeadline, for: token)
                continue
            }
            window.close()
            windows[token] = nil

            let visible = window.isVisible
            sweep.record(
                .closeRequested(
                    visibleLocally          : visible,
                    deadlinePassedAfterwards: clock.nowNanoseconds >= deadlineNanoseconds
                ),
                for: token
            )
        }

        return sweep.result()
    }

    // MARK: Creation and observation

    private func create(_ role: FixtureWindowRole) throws -> ProbeWindowLocalState {

        guard !registered.contains(where: { $0.role == role })
        else { throw ProbeFixtureFailure.alreadyCreated(role) }

        creationCount += 1
        let token = FixtureWindowToken(
            identifier   : UUID(),
            role         : role,
            creationOrder: creationCount
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask  : [.titled, .closable, .miniaturizable],
            backing    : .buffered,
            defer      : true
        )
        window.isReleasedWhenClosed = false
        window.title                = "AgentSeat window inventory probe"

        // Ownership is registered before anything can present the window, so a
        // throw after this line still leaves cleanup something to release.
        windows[token] = window
        registered.append(token)
        return state(of: token)
    }

    private func state(of token: FixtureWindowToken) -> ProbeWindowLocalState {
        guard let window = windows[token] else {
            return ProbeWindowLocalState(
                token                    : token,
                observed                 : nil,
                isVisibleLocally         : false,
                isMiniaturizedLocally    : false,
                wasPresentedAtLeastOnce  : presented.contains(token)
            )
        }
        let number = window.windowNumber
        return ProbeWindowLocalState(
            token                  : token,
            observed               : number > 0
                ? ObservedWindowIdentity(windowID: number, processID: processID)
                : nil,
            isVisibleLocally       : window.isVisible,
            isMiniaturizedLocally  : window.isMiniaturized,
            wasPresentedAtLeastOnce: presented.contains(token)
        )
    }
}
