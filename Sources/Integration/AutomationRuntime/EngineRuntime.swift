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
import FileKnowledge
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
public struct EngineRuntime {

    public let windows = WindowServerWindowListing()
    public let scenes: any SceneProviding
    public let actuator: any Actuating
    public let controls: any ControlPressing
    public let activation: (any ApplicationActivating)?
    public let store: FileKnowledgeStore
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
        store = FileKnowledgeStore(
            directory  : knowledgeDirectory,
            clock      : { Date() },
            diagnostics: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        )
        memory = BrainMemory(store: store, clock: { Date() })
    }

    /// The engine over the foreground adapters, remembering through the brain.
    public func engine(allowsDestructive: Bool) -> ActionEngine {
        ActionEngine(
            ActionEngine.Dependencies(
                scenes      : scenes,
                actuator    : actuator,
                windows     : windows,
                controls    : controls,
                activation  : activation,
                expectations: memory,
                observer    : memory
            ),
            permissions: ActionPermissions(allowsDestructive: allowsDestructive)
        )
    }

    /// Writes every pending memory change before the process exits.
    public func finish() async {
        await store.flush()
    }

}
