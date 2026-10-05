//
//  StepPerformer.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 03/10/2026.
//

import AppKit
import AutomationMCP
import AutomationRuntime
import CoreGraphics
import Engine
import EngineCore
import Foundation
import ImageIO
import Memory
import Perception
import PerceptionCore
import SeatCore
import SeatDriving
import SeatSession
import UniformTypeIdentifiers
import VisionText
import WindowServerListing

/// EngineStepPerformer runs a decoded action through the engine the vertical command composed, over
/// its Seat (`--seat`) or the real screen: `act` through `ActionEngine.act`, the five inputs through
/// `ActionEngine.deliver` (the `InputRequest` the tools' decoder maps them to, `engineInput`), and
/// `select` through the Seat's dropdown selector, as the app's session runs them. Each step's samples
/// go to the call's recorder (`EngineRuntime.recorder`), under the call's context.
@MainActor
final class EngineStepPerformer: StepPerforming {

    private let runtime: Runtime
    private let target: SeatTarget?
    private let application: NSRunningApplication
    private let allowsDestructive: Bool
    private let dryRun: Bool

    /// The window a batch began in, which every step must still find; nil outside a batch.
    private let original: AdoptedWindow?

    init(runtime: Runtime, target: SeatTarget?, application: NSRunningApplication, allowsDestructive: Bool,
         dryRun: Bool, guardsWindow: Bool = false) throws {
        self.runtime           = runtime
        self.target            = target
        self.application       = application
        self.allowsDestructive = allowsDestructive
        self.dryRun            = dryRun
        self.original          = guardsWindow ? try target?.currentWindow() : nil
    }

    private var processID: pid_t { application.processIdentifier }
    private var bundleID: String { application.bundleIdentifier ?? "pid.\(processID)" }
    private var appName: String { application.localizedName ?? "pid \(processID)" }

    func checkTarget() throws {
        guard let original, let target else { return }
        let seat = try target.agentSeat()
        let current = try target.currentWindow()
        let windows = try runtime.windows.windows(ownedBy: processID)
        guard seat.state == .ready, current.id == original.id, windows.contains(where: { $0.number == original.id }) else {
            throw UsageError.invalid(option: "window", value: original.title,
                                     expected: "the original batch window still available in a ready Seat")
        }
    }

    func perform(_ request: AgentCallRequest, context: ActionContext, evidence: String?) async throws -> StepResult {
        let recorder = runtime.recorder(for: context)
        let engine = runtime.engine(allowsDestructive: allowsDestructive, observer: recorder)
        let started = ContinuousClock.now
        let outcome: ActOutcome
        switch request {
            case .act(let target, let verb, let value, let section):
                outcome = try await engine.act(ActionRequest(
                    processID: processID, bundleID: bundleID, appName: appName, target: target, verb: verb,
                    section: section, desiredState: value, isDryRun: dryRun
                ))
            case .select(let control, let item):
                outcome = try await select(control: control, item: item, recorder: recorder, evidence: evidence)
            default:
                guard let input = request.engineInput else {
                    throw UsageError.missing("an action a vertical command runs: " + ActionGrammar.operations.map(\.rawValue).joined(separator: ", "))
                }
                outcome = try await engine.deliver(InputRequest(
                    processID: processID, bundleID: bundleID, appName: appName, input: input.input,
                    section: input.section, isDryRun: dryRun
                ))
        }
        CLIMemory.say("acted in \(started.duration(to: .now))")
        return StepResult(outcome: outcome, report: await recorder.report())
    }

    /// Opens the dropdown and chooses the item in one background menu operation, recording the windows
    /// the selector read as the call's samples.
    private func select(control: String, item: String, recorder: CallRecorder, evidence: String?) async throws -> ActOutcome {
        guard let target else { throw UsageError.missing("--seat (select currently supports background dropdowns)") }
        let selector = SeatDropdownSelector(target: target, pipeline: ScenePipeline(text: VisionTextRecognizer()))
        do {
            let result = try await selector.select(
                control: control, item: item,
                identity: ApplicationIdentity(bundleID: bundleID, name: application.localizedName ?? "application"),
                permissions: ActionPermissions(allowsDestructive: allowsDestructive),
                dryRun: dryRun,
                onMenu: { menu in print("menu: observed #\(menu.window.windowNumber) at \(menu.frame)") }
            ) { stage, image in
                if let evidence { try Self.save(image, stage: stage, directory: evidence) }
            }
            if let receipt = result.receipt {
                print("menu: #\(receipt.menu.window.windowNumber), closed by \(receipt.closedBy.rawValue)")
                if receipt.opening != nil {
                    print("menu: routed opening click, \(receipt.choosing.count) selection key presses")
                }
                if let observation = receipt.observation {
                    print("selection: focus changed=\(observation.frontmostApplicationChanged), cursor distance=\(observation.maximumCursorDistance)")
                }
            }
            await recorder.record(before: result.before, menu: result.menu, after: result.after)
            return result.outcome
        } catch {
            let seat = try target.agentSeat()
            print("seat: selection stopped in state \(seat.state)")
            if seat.lastFocusRecovery != nil {
                print("seat: a focus recovery occurred; this was not an uninterrupted background operation")
            }
            throw error
        }
    }

    private static func save(_ image: CGImage, stage: String, directory: String) throws {
        let folder = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(stage).png")
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
