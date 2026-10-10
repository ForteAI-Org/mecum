import AutomationRuntime
import AppKit
import CoreGraphics
import EngineCore
import Foundation
import ImageIO
import Memory
import Perception
import SeatDriving
import SeatCore
import SeatSession
import UniformTypeIdentifiers
import VisionText

/// SelectCommand selects a dropdown item within one background Seat lifetime.
enum SelectCommand {

    static func run(_ invocation: Invocation) async throws {
        guard invocation.flags.contains("seat") else {
            throw UsageError.missing("--seat (select currently supports background dropdowns)")
        }
        let application = try ApplicationLookup.running(try invocation.positional(0, "<app>"))
        let control = try invocation.positional(1, "<dropdown>")
        let item = try invocation.positional(2, "<item>")
        let identity = ApplicationIdentity(
            bundleID: application.bundleIdentifier ?? "pid.\(application.processIdentifier)",
            name: application.localizedName ?? "application"
        )
        try await SeatRuntime.withSeat(application, invocation) { target in
            let recorder = EngineRuntime.commandLineRecorder(knowledge: EngineRuntime.knowledgeDirectory(invocation))
            let kind = try await perform(control: control, item: item, identity: identity,
                                         target: target, invocation: invocation, recorder: recorder)
            guard [.foundActed, .dryRun].contains(kind) else { throw ActFailure(kind) }
        }
    }

    /// Borrows an existing Seat, allowing a batch to reuse the same menu operation and verification.
    static func perform(
        control: String,
        item: String,
        identity: ApplicationIdentity,
        target: SeatTarget,
        invocation: Invocation,
        recorder: CallRecorder,
        begun: Bool = false,
        evidenceDirectory: String? = nil
    ) async throws -> ActOutcomeKind {
        let selector = SeatDropdownSelector(target: target, pipeline: ScenePipeline(text: VisionTextRecognizer()))
        let dryRun = invocation.flags.contains("dry-run")
        // A batch's step is begun and started by its batch; the command's own call is begun here.
        if !dryRun, !begun {
            do {
                try await recorder.begin(
                    .select(control: control, item: item),
                    app: AppContextIdentity(bundleID: identity.bundleID)
                )
            } catch {
                print("refused: Mecum's memory did not confirm the selection before it could act (\(error)); nothing was done")
                return .refused
            }
        }
        do {
            let result = try await selector.select(
                control: control, item: item, identity: identity,
                permissions: ActionPermissions(allowsDestructive: invocation.flags.contains("allow-destructive")),
                dryRun: dryRun,
                onMenu: { menu in print("menu: observed #\(menu.window.windowNumber) at \(menu.frame)") },
                onCapture: { stage, image in
                    if let directory = evidenceDirectory ?? invocation.options["evidence"] {
                        try save(image, stage: stage, directory: directory)
                    }
                },
                report: SelectorReporting.reporting(to: dryRun ? nil : recorder, bundleID: identity.bundleID)
            )
            print("\(result.outcome.kind.rawValue): \(result.outcome.message)")
            if !dryRun { try await CommandLineCall.end(recorder, outcome: result.outcome, tool: .select) }
            if let receipt = result.receipt {
                print("menu: #\(receipt.menu.window.windowNumber), closed by \(receipt.closedBy.rawValue)")
                if receipt.opening != nil {
                    print("menu: routed opening click, \(receipt.choosing.count) selection key presses")
                }
                if let observation = receipt.observation {
                    print("selection: focus changed=\(observation.frontmostApplicationChanged), cursor distance=\(observation.maximumCursorDistance)")
                }
            }
            return result.outcome.kind
        } catch let suspension as CommandLineCall.Unsaved {
            throw suspension
        } catch {
            if !dryRun {
                try? await recorder.end(
                    error is CancellationError ? .cancelled : .failed,
                    result: error is CancellationError ? nil : .error(message: String(describing: error)),
                    tool: .select
                )
            }
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
