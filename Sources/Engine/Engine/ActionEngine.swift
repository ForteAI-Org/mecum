//
//  ActionEngine.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import CoreGraphics
import EngineCore
import Foundation
import PerceptionCore

/// ActionEngine performs one action the honest way: perceive this instant, resolve the target by
/// name, refuse what policy refuses, deliver the gesture through a role, perceive again, and judge
/// the effect by what changed structurally. Every dependency arrives at construction; nothing here
/// reads a clock, a path or an environment.
///
/// A pop-up is a window of its own. A target inside an open pop-up is chosen with the keyboard from a
/// plan over the scene's rows, never by a coordinate; a target outside one closes the pop-up first and
/// says so. A closed dropdown is opened by its own press action when the application exposes one, so a
/// painted caret is never the click target.
public struct ActionEngine: Sendable {

    /// What the engine has not been given decides what it can do: no activation role means no raising
    /// (a background seat), no control role means coordinates and type-ahead only.
    public struct Dependencies: Sendable {
        public var scenes: any SceneProviding
        public var actuator: any Actuating
        public var windows: any WindowListing
        public var controls: (any ControlPressing)?
        public var activation: (any ApplicationActivating)?
        public var expectations: (any EffectExpecting)?
        public var observer: (any ActionObserving)?

        public init(
            scenes      : any SceneProviding,
            actuator    : any Actuating,
            windows     : any WindowListing,
            controls    : (any ControlPressing)? = nil,
            activation  : (any ApplicationActivating)? = nil,
            expectations: (any EffectExpecting)? = nil,
            observer    : (any ActionObserving)? = nil
        ) {
            self.scenes       = scenes
            self.actuator     = actuator
            self.windows      = windows
            self.controls     = controls
            self.activation   = activation
            self.expectations = expectations
            self.observer     = observer
        }
    }

    private let dependencies: Dependencies
    private let permissions: ActionPermissions
    private let timing: ActionTiming
    private let pause: @Sendable (Duration) async -> Void

    /// Creates an engine. `pause` is how it waits; the default sleeps, a test does not.
    public init(
        _ dependencies: Dependencies,
        permissions   : ActionPermissions = ActionPermissions(),
        timing        : ActionTiming = .standard,
        pause         : @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.dependencies = dependencies
        self.permissions  = permissions
        self.timing       = timing
        self.pause        = pause
    }

    // MARK: Observe

    /// The map a model reads, with the token it echoes back when it acts.
    public func describeScene(of processID: pid_t, appName: String) async -> ActOutcome {
        guard let perceived = await perceive(processID) else {
            return ActOutcome(.honestMiss, await noSceneReason(appName: appName, processID: processID))
        }
        let text = perceived.scene.mapText() + "\nscene_token: \(perceived.scene.token)"
        return ActOutcome(.foundActed, text, scene: perceived.scene)
    }

    /// One panel's elements, each with its id, so a shared label can be acted on by id.
    public func describeSection(named name: String, of processID: pid_t, appName: String) async -> ActOutcome {
        guard let perceived = await perceive(processID) else {
            return ActOutcome(.honestMiss, await noSceneReason(appName: appName, processID: processID))
        }
        let scene = perceived.scene
        guard let section = scene.resolveSection(named: name) else {
            return ActOutcome(.honestMiss, "no section '\(name)' — sections right now: "
                + scene.sections.map(\.name).joined(separator: " · "), scene: scene)
        }
        let members = scene.elements.filter { $0.section == section.name }
        var out = "▣ \(section.name) — \(members.count) elements"
        if let note = section.verticalScrollNote { out += " · \(note)" }
        if let note = section.horizontalScrollNote { out += " · \(note)" }
        out += " (scene_token: \(scene.token))\n"
        for element in members {
            let position = String(format: "%.2f,%.2f", element.bounds.x, element.bounds.y)
            let state = element.state.map { " [\($0.rawValue)]" } ?? ""
            let tag = element.isUnlabeled ? "icon?" : element.kind.rawValue
            let does = element.does.map { " — \($0)" } ?? ""
            out += "  [\(tag)] \(element.label)\(state)\(does)  @ \(position)  id:\(element.id)\n"
        }
        return ActOutcome(.foundActed, out, scene: scene)
    }

    /// Whether the window shows `evidence` right now: a title or a label, matched case-insensitively.
    /// A goal is verified by what is on screen, never by the model's own report of having done it.
    public func checkGoal(evidence: String, of processID: pid_t, appName: String) async -> ActOutcome {
        let needle = evidence.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return ActOutcome(.refused, "missing evidence") }
        guard let perceived = await perceive(processID) else {
            return ActOutcome(.honestMiss, await noSceneReason(appName: appName, processID: processID))
        }
        let scene = perceived.scene
        let haystack = (scene.windowTitle + " " + scene.elements.map(\.label).joined(separator: " ")).lowercased()
        guard haystack.contains(needle.lowercased()) else {
            return ActOutcome(.refused, "NOT verifiably done — \(appName)'s screen does not show “\(needle)”. "
                + "Keep working, or check with a string that IS visible (window title or an exact label from the "
                    + "scene).",
                scene: scene)
        }
        return ActOutcome(.foundActed, "verified on screen (“\(needle)”)", scene: scene)
    }

    // MARK: Act

    /// Performs one request and answers with an outcome a model can act on next.
    public func act(_ request: ActionRequest) async -> ActOutcome {
        let pid = request.processID
        guard let perceived = await perceive(pid) else {
            return ActOutcome(.honestMiss, await noSceneReason(appName: request.appName, processID: pid))
        }
        let scene = perceived.scene
        let element: SceneElement
        let resolution = scene.resolve(
            target: request.target, preferStateful: request.verb == .setToggle, section: request.section,
            preferNativeControls: request.verb == .click || request.verb == .doubleClick
        )
        switch resolution {
            case .found(let found):
                element = found
            case .ambiguous(let count):
                return ActOutcome(
                    .ambiguous,
                    "\(count) elements labeled '\(request.target)' — choose an exact element ID or section: "
                    + scene.disambiguation(target: request.target), scene: scene)
            case .none:
                let near = scene.grep(goal: request.target).prefix(3)
                    .map { "'\($0.element.label)'" + ($0.element.section.map { " (\($0))" } ?? "") }
                return ActOutcome(.honestMiss, "no element '\(request.target)' in \(request.appName)"
                    + (near.isEmpty ? "" : " — closest on screen: \(near.joined(separator: ", "))"), scene: scene)
        }
        if ActionPolicy.isDestructive(label: element.label), !permissions.allowsDestructive {
            return ActOutcome(.refused, "'\(element.label)' looks destructive/irreversible — refused. "
                + "If you want the agent to do this, the person must allow destructive actions.", scene: scene)
        }
        let point = perceived.globalPoint(of: element)
        let surfaces = await surfaces(pid)
        let expected = await dependencies.expectations?.expectedEffect(
            of: request.verb, on: element, in: request.bundleID
        )

        if request.verb == .setToggle {
            return await setToggle(request, element: element, at: point, perceived: perceived, expected: expected)
        }
        let containingPopup = surfaces.popups.first { $0.insetBy(dx: -4, dy: -4).contains(point) }
        if request.verb == .click, let popup = containingPopup {
            return await pickInPopup(request, element: element, popupFrame: popup, perceived: perceived)
        }
        if request.verb == .click, surfaces.hasOpenPopup {
            // Clicking through an open menu hits the menu; dismiss it first and say so.
            if request.isDryRun {
                return ActOutcome(.dryRun, "a pop-up is open and '\(element.label)' is not one of its items — would "
                    + "Escape it first")
            }
            try? await dependencies.actuator.perform(.key(code: Key.escape), in: pid)
            await pause(timing.popupDismiss)
            let after = await perceive(pid)?.scene
            let dismissed = !(await self.surfaces(pid)).hasOpenPopup
            await dependencies.actuator.confirm(dismissed ? .observed : .unknown, in: pid)
            return ActOutcome(.actedNoop, "a pop-up menu was open and '\(element.label)' is NOT one of its items — "
                + "closed the menu instead of clicking through it. The scene below is current; act '\(element.label)' "
                    + "again now.",
                scene: after)
        }
        return await clickVerified(
            request, element: element, at: point, perceived: perceived, surfacesBefore: surfaces, expected: expected
        )
    }

    // MARK: The three ways to act

    private func clickVerified(
        _ request     : ActionRequest,
        element       : SceneElement,
        at point      : CGPoint,
        perceived     : PerceivedWindow,
        surfacesBefore: WindowSurfaces,
        expected      : SceneEffect?
    ) async -> ActOutcome {
        let pid = request.processID
        if request.isDryRun {
            let expectation = expected.map { " — expected effect: \($0.summary)" } ?? ""
            return ActOutcome(.dryRun, "would \(request.verb.rawValue) '\(element.label)' at "
                + "\(Int(point.x)),\(Int(point.y))\(expectation)")
        }
        if let activation = dependencies.activation {
            let frontmost = await activation.frontmostProcessID()
            let raise = ActivationPolicy.needsActivation(
                target: pid, frontmost: frontmost, isPopupOpen: surfacesBefore.hasOpenPopup
            )
            if raise {
                await activation.activate(pid)
                await pause(timing.activateSettle)
            }
        }
        // The census after activation on purpose: raising an application floats its own palettes.
        let censusBefore = await surfaces(pid).verdicts
        var openedByPress = false
        if request.verb == .click, let controls = dependencies.controls {
            openedByPress = await controls.pressControl(labelled: element.label, in: pid)
        }
        do {
            switch request.verb {
                case .doubleClick: try await dependencies.actuator.perform(.click(at: point, count: 2), in: pid)
                case .rightClick : try await dependencies.actuator.perform(.click(at: point, button: .right), in: pid)
                default:
                    if !openedByPress { try await dependencies.actuator.perform(.click(at: point), in: pid) }
            }
        } catch {
            await dependencies.actuator.confirm(.unknown, in: pid)
            return ActOutcome(.actedUnverified, "\(request.verb.performed) '\(element.label)' — delivery failed: "
                + "\(error)", scene: nil)
        }
        await pause(timing.clickSettle)
        guard let after = await perceive(pid)?.scene else {
            await dependencies.actuator.confirm(.unknown, in: pid)
            return ActOutcome(
                .actedUnverified,
                "\(request.verb.performed) '\(element.label)' — no scene could be read "
                + "afterwards; describe_scene when the window is back")
        }
        let surfacesAfter = await surfaces(pid)
        let effect = Self.gatedEffect(
            before: perceived.scene, after: after, targetID: element.id, popupIsOpen: surfacesAfter.hasOpenPopup
        )
        let verdict = ActVerification.verdict(before: perceived.scene, after: after, effect: effect, expected: expected)
        await dependencies.observer?.record(ActionRecord(
            bundleID        : request.bundleID,
            element         : element,
            verb            : request.verb,
            effect          : effect,
            windowTitleAfter: after.windowTitle
        ))
        let elsewhere = ElsewhereGuide.forUnverifiedAct(
            app: request.appName, before: censusBefore, after: surfacesAfter.verdicts
        )
        // A landed effect is observed whether or not it was the expected one; a ghost is verified absence.
        let delivery: DeliveryEffect = switch verdict {
            case .landed        : .observed
            case .ghost         : .absent
            case .unattributable: .unknown
        }
        await dependencies.actuator.confirm(delivery, in: pid)
        switch verdict {
            case .landed(let effect, true):
                let asExpected = expected == nil ? "" : " (as expected)"
                return ActOutcome(.foundActed, "\(request.verb.performed) '\(element.label)' — "
                    + "\(effect.summary)\(asExpected)", scene: after)
            case .landed(let effect, false):
                return ActOutcome(.actedUnverified, "\(request.verb.performed) '\(element.label)' — expected "
                    + "\(expected?.summary ?? "?") but observed \(effect.summary); re-perceive and re-decide. "
                        + "\(elsewhere.sentence)", scene: after)
            case .ghost, .unattributable:
                let why = verdict == .ghost
                    ? "this window did NOT change (identical scene)"
                    : "the window's pixels changed but nothing structural did — no element appeared, disappeared, or "
                        + "retitled, "
                        + "so this is likely animation/repaint, NOT your action landing"
                let advice = elsewhere.changed ? "" : " If you expected an effect here, the click likely did not "
                    + "register — "
                    + "try the exact label with a section arg, or a menu."
                return ActOutcome(.actedUnverified, "\(request.verb.performed) '\(element.label)' — \(why).\(advice) "
                    + "\(elsewhere.sentence)", scene: after)
        }
    }

    private func setToggle(
        _ request: ActionRequest,
        element  : SceneElement,
        at point : CGPoint,
        perceived: PerceivedWindow,
        expected : SceneEffect?
    ) async -> ActOutcome {
        let pid = request.processID
        guard let desired = request.desiredState, desired == .on || desired == .off else {
            return ActOutcome(.refused, "set_toggle needs a desired state of on or off")
        }
        if element.state == desired {
            return ActOutcome(.actedNoop, "'\(element.label)' is already \(desired.rawValue) — nothing to "
                + "do", scene: perceived.scene)
        }
        if request.isDryRun {
            return ActOutcome(.dryRun, "would click '\(element.label)' to set it \(desired.rawValue)")
        }
        do { try await dependencies.actuator.perform(.click(at: point), in: pid) }
        catch {
            await dependencies.actuator.confirm(.unknown, in: pid)
            return ActOutcome(.actedUnverified, "set '\(element.label)' — delivery failed: \(error)")
        }
        await pause(timing.clickSettle)
        let after = await perceive(pid)?.scene
        let readBack = await dependencies.controls?.toggleState(at: point, in: pid)
            ?? after?.elements.first(where: { $0.id == element.id })?.state
            ?? after?.elements.first(where: {
                $0.state != nil && LabelText.normalize($0.label) == LabelText.normalize(element.label)
            })?.state
        let effect = after.flatMap { SceneDifference.effect(before: perceived.scene, after: $0, targetID: element.id) }
        await dependencies.observer?.record(ActionRecord(
            bundleID        : request.bundleID,
            element         : element,
            verb            : .setToggle,
            effect          : effect,
            windowTitleAfter: after?.windowTitle
        ))
        await dependencies.actuator.confirm(readBack == desired ? .observed : .unknown, in: pid)
        switch readBack {
            case desired:
                return ActOutcome(.foundActed, "set '\(element.label)' → \(desired.rawValue)", scene: after)
            case .some(let other):
                return ActOutcome(.actedUnverified, "clicked '\(element.label)' but it now reads '\(other.rawValue)' "
                    + "(wanted \(desired.rawValue)) — "
                    + "re-perceive and re-decide, don't retry blindly", scene: after)
            case nil:
                return ActOutcome(.actedUnverified, "clicked '\(element.label)' — state unreadable after the click; "
                    + "judge from the scene", scene: after)
        }
    }

    private func pickInPopup(
        _ request  : ActionRequest,
        element    : SceneElement,
        popupFrame : CGRect,
        perceived  : PerceivedWindow
    ) async -> ActOutcome {
        let pid = request.processID
        let rows = PopupRowPick.rows(in: perceived.scene, windowFrame: perceived.frame, popupFrame: popupFrame)
        let labels = Set(rows.flatMap { $0.map { LabelText.normalize($0.label) } }.filter { !$0.isEmpty })
        let current = await dependencies.controls?.controlValue(matchingAny: labels, in: pid)
        if let current, let plan = PopupRowPick.plan(rows: rows, currentValue: current, target: element) {
            if request.isDryRun {
                return ActOutcome(.dryRun, "would pick '\(element.label)' in the open pop-up by keyboard "
                    + "(\(plan.route)): "
                    + "row \(plan.targetIndex + 1) of \(plan.rowLabels.count), the highlight starting on '\(current)'")
            }
            do {
                for _ in 0..<abs(plan.delta) {
                    let arrow = plan.delta > 0 ? Key.downArrow : Key.upArrow
                    try await dependencies.actuator.perform(.key(code: arrow), in: pid)
                    await pause(timing.popupArrow)
                }
                try await dependencies.actuator.perform(.key(code: Key.return), in: pid)
            } catch {
                await dependencies.actuator.confirm(.unknown, in: pid)
                return ActOutcome(.actedUnverified, "picking '\(element.label)' — delivery failed: \(error)")
            }
            await pause(timing.popupCommit)
            let stillOpen = await surfaces(pid).hasOpenPopup
            let value = await dependencies.controls?.controlValue(matchingAny: labels, in: pid)
            let after = await perceive(pid)?.scene
            let picked = value.map { LabelText.normalize($0) == LabelText.normalize(element.label) } ?? false
            await dependencies.actuator.confirm(picked ? .observed : .unknown, in: pid)
            if let value, LabelText.normalize(value) == LabelText.normalize(element.label) {
                return ActOutcome(.foundActed, "selected '\(element.label)' in the pop-up (keyboard \(plan.route); the "
                    + "control now reads '\(value)')", scene: after)
            }
            if stillOpen {
                return ActOutcome(.actedUnverified, "moved the pop-up highlight (\(plan.route)) but the list is still "
                    + "open and the control "
                    + "reads '\(value ?? "?")' — describe_scene and act the exact row.", scene: after)
            }
            return ActOutcome(.actedUnverified, "the pop-up closed but the control reads "
                + "'\(value ?? "?")', not '\(element.label)' — "
                + "re-open it and re-decide.", scene: after)
        }
        // No control to read the highlight from: the menu's own type-ahead, first word only.
        let typed = PopupRowPick.typeAheadPrefix(for: element.label)
        guard !typed.isEmpty else {
            return ActOutcome(.honestMiss, "'\(element.label)' has no typeable name for pop-up selection — "
                + "describe_scene and target a named row.")
        }
        if request.isDryRun {
            return ActOutcome(.dryRun, "would type '\(typed)' into the open pop-up, probe for a submenu with →, then "
                + "Return")
        }
        let popupsBefore = (await surfaces(pid)).popups.count
        do {
            try await dependencies.actuator.perform(.type(typed), in: pid)
            await pause(timing.popupType)
            // A submenu parent selects nothing on Return; the right arrow enters one and is harmless otherwise.
            try await dependencies.actuator.perform(.key(code: Key.rightArrow), in: pid)
            await pause(timing.popupArrow)
            if (await surfaces(pid)).popups.count > popupsBefore {
                let after = await perceive(pid)?.scene
                await dependencies.actuator.confirm(.observed, in: pid)
                return ActOutcome(.foundActed, "'\(element.label)' opened a SUBMENU — its items are in the scene "
                    + "below; act the one you want next.", scene: after)
            }
            // Commit only while the list is still open: a Return after it closed would hit the dialog behind it.
            if (await surfaces(pid)).hasOpenPopup {
                try await dependencies.actuator.perform(.key(code: Key.return), in: pid)
                await pause(timing.popupCommit)
            }
        } catch {
            await dependencies.actuator.confirm(.unknown, in: pid)
            return ActOutcome(.actedUnverified, "typing '\(typed)' — delivery failed: \(error)")
        }
        let after = await perceive(pid)?.scene
        let stillOpen = (await surfaces(pid)).hasOpenPopup
        await dependencies.actuator.confirm(stillOpen ? .unknown : .observed, in: pid)
        if stillOpen {
            return ActOutcome(.actedUnverified, "typed '\(typed)' but a pop-up is still open — that prefix may not "
                + "match a row; "
                + "describe_scene to read the exact item labels, then act the precise one.", scene: after)
        }
        return ActOutcome(.foundActed, "selected '\(element.label)' in the pop-up (keyboard type-ahead)", scene: after)
    }

    // MARK: Helpers

    /// A menu is believable only while a pop-up window exists; and when one does, the menu's rows
    /// are the effect whatever the scene difference read, because the after scene IS the menu.
    static func gatedEffect(
        before     : SceneSnapshot,
        after      : SceneSnapshot,
        targetID   : String,
        popupIsOpen: Bool
    ) -> SceneEffect? {
        var effect = SceneDifference.effect(before: before, after: after, targetID: targetID)
        if case .menuOpened(let labels) = effect, !popupIsOpen { effect = .elementsAppeared(labels: labels) }
        if popupIsOpen {
            let items = after.elements
                .filter { !$0.isUnlabeled && $0.kind != .icon && (2...40).contains($0.label.count) }
                .prefix(14).map(\.label)
            if items.count >= 2 { effect = .menuOpened(labels: Array(Set(items)).sorted().prefix(6).map { $0 }) }
        }
        return effect
    }

    private func perceive(_ processID: pid_t) async -> PerceivedWindow? {
        try? await dependencies.scenes.currentScene(of: processID)
    }

    private func surfaces(_ processID: pid_t) async -> WindowSurfaces {
        let rows = (try? dependencies.windows.windows(ownedBy: processID)) ?? []
        return WindowSurfaceClassifier.classify(rows)
    }

    private func noSceneReason(appName: String, processID: pid_t) async -> String {
        let rows = (try? dependencies.windows.windows(ownedBy: processID)) ?? []
        let ordinary = rows.filter { $0.layer == 0 && $0.frame.width >= 60 }
        if ordinary.isEmpty {
            return "no scene — \(appName) has NO window open right now "
                + "(it is running, but there is nothing to show or "
                + "capture). "
                + "Open a document or window in it first, then describe_scene."
        }
        return "no scene — \(appName) has a window but it could not be perceived right now; "
            + "retry, and if this repeats "
            + "check Screen Recording for the process that runs the engine."
    }
}
