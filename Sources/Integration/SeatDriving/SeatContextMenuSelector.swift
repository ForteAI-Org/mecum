import CoreGraphics
import EngineCore
import Foundation
import Perception
import PerceptionCore
import SeatCapture
import SeatCore
import SeatSession

/// SeatContextMenuSelector chooses one observed row through the Driver's scoped menu interaction.
/// The menu's capture and input share its attested identity. The Driver revokes that authority and
/// verifies withdrawal on every path; no ordinary parent input is sent while the menu is tracking.
@MainActor
public struct SeatContextMenuSelector {

    private let target: SeatTarget
    private let pipeline: ScenePipeline

    /// Creates a selector over a borrowed or owned target and its production perception pipeline.
    public init(target: SeatTarget, pipeline: ScenePipeline) {
        self.target = target
        self.pipeline = pipeline
    }

    /// Opens once and chooses a unique enabled row. Delivery and withdrawal do not prove the
    /// command's application effect: the outcome requires a fresh check of that intended effect. Its
    /// check (`OperationCheck`) says whether the row was chosen in the Driver's menu, never that the
    /// command took effect; `report` receives what the choice perceived, for the call's record.
    public func select(
        item: String,
        on control: String,
        identity: ApplicationIdentity,
        section: String? = nil,
        permissions: ActionPermissions = ActionPermissions(),
        dryRun: Bool = false,
        report: @escaping @MainActor (SelectorPerception) async -> Void = { _ in }
    ) async throws -> ActOutcome {
        let seat = try target.agentSeat()
        let turn = try await seat.acquire()
        var perception = SelectorPerception()
        do {
            let outcome = try await perform(
                item: item, on: control, identity: identity, section: section,
                permissions: permissions, dryRun: dryRun, seat: seat, turn: turn, perception: &perception
            )
            try seat.release(turn)
            await report(perception)
            return outcome
        } catch {
            do { try seat.release(turn) }
            catch let cleanup {
                throw TurnReleaseFailure(primary: String(describing: error), cleanup: String(describing: cleanup))
            }
            throw error
        }
    }

    private func perform(
        item: String,
        on control: String,
        identity: ApplicationIdentity,
        section: String?,
        permissions: ActionPermissions,
        dryRun: Bool,
        seat: AgentSeat,
        turn: Turn,
        perception: inout SelectorPerception
    ) async throws -> ActOutcome {
        guard !LabelText.normalize(item).isEmpty else {
            return ActOutcome(.refused, "context_menu needs the item's title")
        }
        let parent = try target.currentWindow()
        let beforeDelivery = try await target.observe()
        let before = try await perceive(beforeDelivery, identity: identity, title: parent.title)
        perception.before = before
        let opener: SceneElement
        switch before.scene.resolve(
            target: control, section: section, preferNativeControls: true,
            preferTextEntry: permissions.contextMenusOnTextFieldsOnly
        ) {
            case .found(let element): opener = element
            case .none:
                return ActOutcome(.honestMiss, "no target '\(control)' for the contextual menu", scene: before.scene)
            case .ambiguous(let count):
                return ActOutcome(.ambiguous, "\(count) targets match '\(control)'; choose a section or unique ID", scene: before.scene)
        }
        if !permissions.allowsDestructive, ActionPolicy.isDestructive(label: item) {
            return ActOutcome(.refused, "'\(item)' requires --allow-destructive", scene: before.scene)
        }
        if permissions.contextMenusOnTextFieldsOnly,
           !AccessibilityAugmentation.textEntryRoles.contains(opener.role ?? "") {
            return ActOutcome(.refused, "\(identity.name) opens this control's menu outside the Seat; use a native text field or a visible button", scene: before.scene)
        }
        if dryRun {
            return ActOutcome(.dryRun, "would open '\(opener.label)' and choose '\(item)' in its observed menu", scene: before.scene)
        }
        perception.target = opener
        guard let location = InputLocation(screenPoint: before.globalPoint(of: opener), observedIn: beforeDelivery.geometry) else {
            throw SeatDrivingFailure.frameUnusable
        }
        var selected: String?
        var missing: String?
        var failure: String?
        var menuWindow: PerceivedWindow?
        let result = try await seat.withContextMenu(
            openedAt: location, observation: beforeDelivery.reference, turn: turn
        ) { interaction in
            do {
                try Task.checkCancellation()
                let delivery: SeatObservationDelivery
                switch await interaction.observe() {
                    case .success(let observed): delivery = observed
                    case .failure(let reason): throw reason
                }
                let menu = try await perceive(delivery, identity: identity, title: "Contextual menu")
                menuWindow = menu
                // The scene's own resolution first, then the menu title rule that names
                // `Compress “file”` by "Compress"; a miss names what the menu holds.
                let enabled = menu.scene.elements.filter { !$0.isUnlabeled && $0.isEnabled != false }
                var chosen: SceneElement?
                if case .found(let found) = menu.scene.resolve(target: item) {
                    chosen = found.isEnabled != false ? found : nil
                } else {
                    chosen = LabelText.menuItemMatch(item, in: enabled.map(\.label)).map { enabled[$0] }
                }
                guard let row = chosen else {
                    let titles = enabled.map(\.label).filter { LabelText.isNameworthy($0) }
                    missing = "no unique enabled '\(item)' in the observed menu. It holds: "
                        + (titles.isEmpty ? "nothing readable" : titles.joined(separator: ", "))
                    return
                }
                guard let choice = InputLocation(screenPoint: menu.globalPoint(of: row), observedIn: delivery.geometry) else {
                    throw SeatDrivingFailure.frameUnusable
                }
                try Task.checkCancellation()
                try await interaction.send(.click(choice, button: .left), observation: delivery.reference)
                selected = row.label
            } catch {
                failure = String(describing: error)
            }
        }
        try Task.checkCancellation()
        // A failed post-menu reading cannot turn a delivered choice into a dead click or invite
        // replay. Withdrawal is already the Driver's verified result, independent of this capture.
        var afterWindow: PerceivedWindow?
        var readAfter = true
        do {
            afterWindow = try await perceive(try await target.observe(), identity: identity, title: parent.title)
        } catch {
            readAfter = false
            failure = [failure, "parent observation: \(error)"].compactMap { $0 }.joined(separator: "; ")
        }
        perception.menu  = menuWindow
        perception.after = afterWindow
        let after = afterWindow?.scene
        let checked = OperationCheck.Target(opener)
        let afterLimit: [OperationCheck.Limit] = readAfter ? [] : [.noAfterScene]
        if let failure, selected == nil {
            return ActOutcome(
                .actedUnverified,
                "contextual menu interaction: \(failure); cleanup: \(result.cleanup). Inspect the intended effect before further input",
                scene: after,
                check: OperationCheck(
                    condition: .menuItemChosen,
                    method   : .driverReceipt,
                    verdict  : .unknown,
                    expected : item,
                    limits   : [.deliveryUncertain, .commandEffectUnchecked] + afterLimit,
                    performed: .uncertain,
                    target   : checked
                )
            )
        }
        if let missing {
            // The menu opened and was withdrawn with no row chosen: the requested choice was not performed.
            return ActOutcome(
                .honestMiss,
                "\(missing); cleanup: \(result.cleanup)",
                scene: after,
                check: OperationCheck(
                    condition : .menuItemChosen,
                    method    : .driverReceipt,
                    verdict   : .failed,
                    expected  : item,
                    limits    : afterLimit,
                    performed : .substitute,
                    substitute: "menu_opened_and_withdrawn",
                    target    : checked
                )
            )
        }
        // The Driver delivered the choice and verified the menu's withdrawal: the choice is checked,
        // the command's effect is not.
        let chosen = OperationCheck(
            condition: .menuItemChosen,
            method   : .driverReceipt,
            verdict  : .passed,
            expected : item,
            observed : selected,
            limits   : [.commandEffectUnchecked] + afterLimit,
            performed: .requested,
            target   : checked
        )
        if let failure {
            return ActOutcome(
                .actedUnverified,
                "contextual menu interaction: \(failure); cleanup: \(result.cleanup). Inspect the intended effect before further input",
                scene: after,
                check: chosen
            )
        }
        let message = "requested '\(selected ?? item)' in menu #\(result.menu.window.windowNumber); cleanup: \(result.cleanup). The command's application effect remains unverified: inspect it before further input"
        return ActOutcome(.actedUnverified, message, scene: after, check: chosen)
    }

    private func perceive(
        _ delivery: SeatObservationDelivery, identity: ApplicationIdentity, title: String
    ) async throws -> PerceivedWindow {
        guard delivery.frame.geometry.isValid, let image = delivery.frame.makeCGImage() else {
            throw SeatDrivingFailure.frameUnusable
        }
        let captured = delivery.geometry.window
        let scene = try await pipeline.perceive(image, of: ScenePipeline.Window(
            bundleID: identity.bundleID, appName: identity.name, title: title,
            processID: captured.processID, frame: captured.frame, windowNumber: captured.windowNumber
        ))
        return PerceivedWindow(scene: scene, frame: captured.frame)
    }

    private struct TurnReleaseFailure: Error, CustomStringConvertible {
        let primary: String
        let cleanup: String
        var description: String { "\(primary); releasing the menu Turn: \(cleanup)" }
    }
}
