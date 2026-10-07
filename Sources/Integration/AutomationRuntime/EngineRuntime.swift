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
import OSLog
import SeatDriving
import WindowServerListing
import WorkspaceActivation

/// EngineRuntime is the composition root: the one place that knows which adapter fills which role, where
/// memory lives, and what the clock is. Commands take what they need from it. Without a seat the
/// roles are the foreground pair (a still of the real screen, events at the HID tap, the workspace
/// raising the application); with one they are the Seat's (its stills, its routed commands, no
/// raising at all), and the engine is the same.
///
/// Memory is the living memory of the Knowledge directory: the process's one `MemoryService` for
/// it, shared with every other runtime on the same directory, and the Brain read from it. What a
/// call teaches reaches the memory through the call's `CallRecorder`, which `recorder(_:)` makes.
public struct EngineRuntime {

    public let windows = WindowServerWindowListing()
    public let scenes: any SceneProviding
    public let actuator: any Actuating
    public let controls: any ControlPressing
    public let activation: (any ApplicationActivating)?
    public let service: MemoryService
    public let memory: BrainMemory

    public init(knowledgeDirectory: URL, seat: SeatTarget? = nil) {
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
        let service = MemoryService.shared(for: knowledgeDirectory)
        self.service = service
        memory = BrainMemory(brains: service, applications: service, clock: { service.clock.brainNow() })
    }

    /// The recorder of a call made outside the tools, for the engine and the session to report to: a
    /// command line action, or a session's own observation. A call through the tools brings its own.
    public func recorder(_ context: ActionContext) -> CallRecorder {
        CallRecorder(memory: service, brain: memory, context: context)
    }

    /// The engine over the foreground adapters, expecting from the Brain and reporting to the call's
    /// recorder, which carries what it saw and taught to the memory.
    public func engine(
        recorder                    : CallRecorder,
        allowsDestructive           : Bool,
        contextMenusOnTextFieldsOnly: Bool = false,
        selectsFieldsByTripleClick  : Bool = false,
        refusesMenuOpeningClicks    : Bool = false
    ) -> ActionEngine {
        ActionEngine(
            ActionEngine.Dependencies(
                scenes      : scenes,
                actuator    : actuator,
                windows     : windows,
                controls    : controls,
                activation  : activation,
                expectations: memory,
                observer    : recorder
            ),
            permissions: ActionPermissions(
                allowsDestructive           : allowsDestructive,
                contextMenusOnTextFieldsOnly: contextMenusOnTextFieldsOnly,
                selectsFieldsByTripleClick  : selectsFieldsByTripleClick,
                refusesMenuOpeningClicks    : refusesMenuOpeningClicks
            )
        )
    }

    /// Waits, within the memory's closing budget, for what this process still has to write.
    public func finish() async {
        await service.flush(within: service.configuration.closingBudget)
    }

}
