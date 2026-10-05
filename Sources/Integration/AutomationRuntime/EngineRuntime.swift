//
//  Runtime.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import AppKit
import AccessibilityActions
import Engine
import EngineCore
import Foundation
import HIDActuation
import Memory
import SeatDriving
import WindowServerListing
import WorkspaceActivation

/// EngineRuntime is the composition root: the one place that knows which adapter fills which role, where
/// memory lives, and what the clock is. Commands take what they need from it. Without a seat the
/// roles are the foreground pair (a still of the real screen, events at the HID tap, the workspace
/// raising the application); with one they are the Seat's (its stills, its routed commands, no
/// raising at all), and the engine is the same.
///
/// Memory is the owner's `MemoryService`, shared by every runtime over one Knowledge directory; the
/// brain's seams (`BrainMemory`) read and apply through it, and each call's samples and learning go
/// through the `CallRecorder` made for that call, which the engine gets as its observer.
public struct EngineRuntime {

    public let windows = WindowServerWindowListing()
    public let scenes: any SceneProviding
    public let actuator: any Actuating
    public let controls: any ControlPressing
    public let activation: (any ApplicationActivating)?
    public let memory: MemoryService
    public let brain: BrainMemory

    public init(memory: MemoryService, seat: SeatTarget? = nil) {
        if let seat {
            scenes = SeatSceneProvider(target: seat, pipeline: ProductionPerception.pipeline(), windows: windows,
                                       identity: { RunningApplicationLookup.identity(of: $0) })
            actuator   = SeatActuator(target: seat)
            controls   = SeatControls()
            activation = nil
        } else {
            scenes = ProductionPerception.foregroundScenes()
            actuator   = HIDActuator()
            controls   = AccessibilityController()
            activation = WorkspaceActivator()
        }
        self.memory = memory
        let clock = memory.clock
        brain = BrainMemory(brains: memory, applications: memory, clock: { clock.brainNow() })
    }

    /// The engine over the adapters, expecting through the brain and reporting each action to
    /// `observer`, the call's recorder. Without one nothing is recorded or learned.
    public func engine(allowsDestructive: Bool, observer: (any ActionObserving)? = nil) -> ActionEngine {
        ActionEngine(
            ActionEngine.Dependencies(
                scenes      : scenes,
                actuator    : actuator,
                windows     : windows,
                controls    : controls,
                activation  : activation,
                expectations: brain,
                observer    : observer
            ),
            permissions: ActionPermissions(allowsDestructive: allowsDestructive)
        )
    }

    /// The recorder of one call, under its context. `requestedAtMS` is the Brain's clock the call's
    /// applications are asked for at: read now from the service's clock when not given (a proof
    /// gives it, to offer the same facts again as the same commands).
    public func recorder(for context: ActionContext, sessionRevision: Int64? = nil, requestedAtMS: Int64? = nil) -> CallRecorder {
        let instant = requestedAtMS ?? memory.clock.brainMS()
        return CallRecorder(memory: memory, brain: brain, context: context, sessionRevision: sessionRevision,
                            requestedAt: Date(timeIntervalSince1970: Double(instant) / 1000))
    }
}
