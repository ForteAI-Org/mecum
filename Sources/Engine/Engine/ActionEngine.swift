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
#if MECUM_PHASES
import PhaseSignposts
#endif

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
        /// Ends the wait after a gesture once the window settled; nil sleeps the fixed pause.
        public var settling: (any Settling)?

        public init(
            scenes      : any SceneProviding,
            actuator    : any Actuating,
            windows     : any WindowListing,
            controls    : (any ControlPressing)? = nil,
            activation  : (any ApplicationActivating)? = nil,
            expectations: (any EffectExpecting)? = nil,
            observer    : (any ActionObserving)? = nil,
            settling    : (any Settling)? = nil
        ) {
            self.scenes       = scenes
            self.actuator     = actuator
            self.windows      = windows
            self.controls     = controls
            self.activation   = activation
            self.expectations = expectations
            self.observer     = observer
            self.settling     = settling
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
        #if MECUM_PHASES
        self.pause = { duration in
            let phase = PhaseInterval.begin("pause")
            defer { phase.end() }
            await pause(duration)
        }
        #else
        self.pause        = pause
        #endif
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
            return ActOutcome(.honestMiss, "no section '\(name)': sections right now: "
                + scene.sections.map(\.name).joined(separator: " · "), scene: scene)
        }
        let members = scene.elements.filter { $0.section == section.name }
        var out = "Section: \(section.name), \(members.count) elements"
        if let note = section.verticalScrollNote { out += " · \(note)" }
        if let note = section.horizontalScrollNote { out += " · \(note)" }
        out += " (scene_token: \(scene.token))\n"
        for element in members {
            let position = String(format: "%.2f,%.2f", element.bounds.x, element.bounds.y)
            let state = element.state.map { " [\($0.rawValue)]" } ?? ""
            let tag = element.isUnlabeled ? "icon?" : element.kind.rawValue
            let does = element.does.map { ": \($0)" } ?? ""
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
            return ActOutcome(.refused, "NOT verifiably done: \(appName)'s screen does not show “\(needle)”. "
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
        do throws(Unresolved) {
            element = try resolved(
                request.target, section: request.section, in: scene, appName: request.appName,
                preferStateful: request.verb == .setToggle,
                preferNativeControls: [.click, .doubleClick, .tripleClick, .rightClick].contains(request.verb),
                preferTextEntry: request.verb == .tripleClick
            )
        } catch {
            return error.outcome
        }
        if ActionPolicy.isDestructive(label: element.label), !permissions.allowsDestructive {
            return ActOutcome(.refused, "'\(element.label)' looks destructive/irreversible: refused. "
                + "If you want the agent to do this, the person must allow destructive actions.", scene: scene)
        }
        if request.verb == .rightClick,
           let refusal = menuOutsideTheSeat(on: element, appName: request.appName, scene: scene) {
            return refusal
        }
        if request.verb != .rightClick, permissions.refusesMenuOpeningClicks,
           let role = element.role, ActionPolicy.menuOpeningRoles.contains(role) {
            return ActOutcome(.refused, ActionPolicy.menuOpeningRefusal(role: role), scene: scene)
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
                return ActOutcome(.dryRun, "a pop-up is open and '\(element.label)' is not one of its items: would "
                    + "Escape it first")
            }
            try? await dependencies.actuator.perform(.key(code: Key.escape), in: pid)
            await pause(timing.popupDismiss)
            let after = await perceive(pid)?.scene
            let dismissed = (try? dependencies.windows.windows(ownedBy: pid)).map {
                !WindowSurfaceClassifier.classify($0).hasOpenPopup
            } ?? false
            await dependencies.actuator.confirm(dismissed ? .observed : .unknown, in: pid)
            guard dismissed else {
                return ActOutcome(.actedUnverified,
                    "could not confirm the pop-up menu's closure after Escape; it may be still open. "
                        + "'\(element.label)' was not clicked. Observe before deciding what to do next.",
                    scene: after)
            }
            return ActOutcome(.actedNoop, "a pop-up menu was open and '\(element.label)' is NOT one of its items: "
                + "closed the menu instead of clicking through it. The scene below is current; act '\(element.label)' "
                    + "again now.",
                scene: after)
        }
        return await clickVerified(
            request, element: element, at: point, perceived: perceived, surfacesBefore: surfaces, expected: expected
        )
    }

    // MARK: Deliver

    /// Delivers one input beyond a click and answers with an outcome a model can act on next: every
    /// target resolved like `act`'s, the gestures through the actuator, the effect judged by perceiving
    /// again. Only a seen effect is `found_acted`.
    public func deliver(_ request: InputRequest) async -> ActOutcome {
        let pid = request.processID
        guard let perceived = await perceive(pid) else {
            return ActOutcome(.honestMiss, await noSceneReason(appName: request.appName, processID: pid))
        }
        switch request.input {
            case .typeText(let text, let field, let replacing):
                return await typeText(text, into: field, replacing: replacing, request, perceived: perceived)
            case .insertText(let text, let expectedValue):
                return await insertText(text, expecting: expectedValue, request)
            case .pressKey(let chord, let times):
                return await pressKey(chord, times: times, request, perceived: perceived)
            case .scroll(let lines, let target):
                return await scroll(lines: lines, over: target, request, perceived: perceived)
            case .drag(let source, let end):
                return await drag(from: source, to: end, request, perceived: perceived)
            case .contextMenu(let target, let item):
                return await chooseInContextMenu(item, on: target, request, perceived: perceived)
        }
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
            let expectation = expected.map { ": expected effect: \($0.summary)" } ?? ""
            return ActOutcome(.dryRun, "would \(request.verb.rawValue) '\(element.label)' at "
                + "\(Int(point.x)),\(Int(point.y))\(expectation)")
        }
        await raiseIfNeeded(pid, isPopupOpen: surfacesBefore.hasOpenPopup)
        // The census after activation on purpose: raising an application floats its own palettes.
        let censusBefore = await surfaces(pid).verdicts
        var openedByPress = false
        // In a remote file panel the seat's own route acts on the control instead.
        if request.verb == .click, !permissions.refusesMenuOpeningClicks, let controls = dependencies.controls {
            openedByPress = await controls.pressControl(labelled: element.label, in: pid)
        }
        do {
            switch request.verb {
                case .doubleClick: try await dependencies.actuator.perform(.click(at: point, count: 2), in: pid)
                case .tripleClick: try await dependencies.actuator.perform(.click(at: point, count: 3), in: pid)
                case .rightClick : try await dependencies.actuator.perform(.click(at: point, button: .right), in: pid)
                default:
                    if !openedByPress { try await dependencies.actuator.perform(.click(at: point), in: pid) }
            }
        } catch {
            await dependencies.actuator.confirm(.unknown, in: pid)
            return ActOutcome(.actedUnverified, "\(request.verb.performed) '\(element.label)': delivery failed: "
                + "\(error)", scene: nil)
        }
        await settle(pid)
        guard let after = await perceive(pid)?.scene else {
            await dependencies.actuator.confirm(.unknown, in: pid)
            return ActOutcome(
                .actedUnverified,
                "\(request.verb.performed) '\(element.label)': no scene could be read "
                + "afterwards; observe the window once it is available")
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
                return ActOutcome(.foundActed, "\(request.verb.performed) '\(element.label)': "
                    + "\(effect.summary)\(asExpected)", scene: after)
            case .landed(let effect, false):
                return ActOutcome(.actedUnverified, "\(request.verb.performed) '\(element.label)': expected "
                    + "\(expected?.summary ?? "?") but observed \(effect.summary); re-perceive and re-decide. "
                        + "\(elsewhere.sentence)", scene: after)
            case .ghost, .unattributable:
                let why = verdict == .ghost
                    ? "this window did NOT change (identical scene)"
                    : "the window's pixels changed but nothing structural did: the intended effect "
                        + "is not classified"
                let advice = elsewhere.changed ? "" : " Verify the intended result in a fresh observation "
                    + "before deciding on further input; do not repeat the click solely from this verdict."
                return ActOutcome(.actedUnverified, "\(request.verb.performed) '\(element.label)': \(why).\(advice) "
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
            return ActOutcome(.actedNoop, "'\(element.label)' is already \(desired.rawValue): nothing to "
                + "do", scene: perceived.scene)
        }
        if request.isDryRun {
            return ActOutcome(.dryRun, "would click '\(element.label)' to set it \(desired.rawValue)")
        }
        do { try await dependencies.actuator.perform(.click(at: point), in: pid) }
        catch {
            await dependencies.actuator.confirm(.unknown, in: pid)
            return ActOutcome(.actedUnverified, "set '\(element.label)': delivery failed: \(error)")
        }
        await settle(pid)
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
                    + "(wanted \(desired.rawValue)): "
                    + "re-perceive and re-decide, don't retry blindly", scene: after)
            case nil:
                return ActOutcome(.actedUnverified, "clicked '\(element.label)': state unreadable after the click; "
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
        // A native menu names its items: the one of that title is pressed, and keys pick only otherwise.
        if !request.isDryRun, let controls = dependencies.controls,
           await controls.pressMenuItem(titled: element.label, within: popupFrame, in: pid) {
            await pause(timing.popupCommit)
            let stillOpen = await surfaces(pid).hasOpenPopup
            let after = await perceive(pid)?.scene
            if stillOpen {
                return ActOutcome(.actedUnverified, "pressed '\(element.label)' in the open menu, but the "
                    + "menu is still open: observe before choosing again.", scene: after)
            }
            return ActOutcome(.foundActed, "chose '\(element.label)' in the open menu through its accessibility "
                + "item; the menu closed. Check the command's own effect before going on.", scene: after)
        }
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
                return ActOutcome(.actedUnverified, "picking '\(element.label)': delivery failed: \(error)")
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
                    + "reads '\(value ?? "?")': describe_scene and act the exact row.", scene: after)
            }
            return ActOutcome(.actedUnverified, "the pop-up closed but the control reads "
                + "'\(value ?? "?")', not '\(element.label)': "
                + "re-open it and re-decide.", scene: after)
        }
        // No control to read the highlight from: the menu's own type-ahead, first word only.
        let typed = PopupRowPick.typeAheadPrefix(for: element.label)
        guard !typed.isEmpty else {
            return ActOutcome(.honestMiss, "'\(element.label)' has no typeable name for pop-up selection: "
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
                return ActOutcome(.foundActed, "'\(element.label)' opened a SUBMENU: its items are in the scene "
                    + "below; act the one you want next.", scene: after)
            }
            // Commit only while the list is still open: a Return after it closed would hit the dialog behind it.
            if (await surfaces(pid)).hasOpenPopup {
                try await dependencies.actuator.perform(.key(code: Key.return), in: pid)
                await pause(timing.popupCommit)
            }
        } catch {
            await dependencies.actuator.confirm(.unknown, in: pid)
            return ActOutcome(.actedUnverified, "typing '\(typed)': delivery failed: \(error)")
        }
        let after = await perceive(pid)?.scene
        let stillOpen = (await surfaces(pid)).hasOpenPopup
        // A menu closing after typed keys proves the closing, not the item: Finder's Compress did nothing.
        await dependencies.actuator.confirm(.unknown, in: pid)
        if stillOpen {
            return ActOutcome(.actedUnverified, "typed '\(typed)' but a pop-up is still open: that prefix may not "
                + "match a row; "
                + "describe_scene to read the exact item labels, then act the precise one.", scene: after)
        }
        return ActOutcome(.actedUnverified, "typed '\(typed)' to choose '\(element.label)' in the pop-up (keyboard "
            + "type-ahead): the menu closed but the effect is not confirmed; observe before acting again.",
            scene: after)
    }

    // MARK: The inputs

    /// The longest text typed as a hand types it, one key pair per character; longer text is inserted
    /// on one event. Measured by the Driver on macOS 27.0 into background windows: at 128 clusters the
    /// two routes are within a fraction of a second of each other, so typing costs nothing there and
    /// keeps the keystrokes a completion list or a validator watches, while past it the typed cost grows
    /// with what the editor holds (0,66 ms a cluster on a browser and 11,3 ms on a native control at
    /// 8192) and an insertion stays flat.
    static let typedTextLimit = 128

    /// What selects everything a focused field holds, with no menu in the path. Command and A is a menu
    /// key equivalent in AppKit and Chromium, measured delivered and acted on by neither on a background
    /// window, while the standard key bindings are answered by the field itself: Command and Up to the
    /// start, then Command, Shift and Down selecting to the end, which a Qt line edit answers too.
    /// Command and A comes last because DaVinci's Search field answers it itself, as measured, and where
    /// a menu would resolve it instead it does nothing and leaves the selection as it was.
    ///
    /// Only a field whose value was read as holding text is sent them: a web application binds the
    /// same arrows. Slack opens the person's last message for editing on an Up arrow in its empty
    /// composer, and the text typed next went into that message, twice in a row, on 25 Sep 2026. A
    /// field read as empty has nothing to select; one whose value cannot be read, which is what a
    /// Chromium composer is, is selected with a triple click, which sends no key an application can
    /// bind, and selects the paragraph clicked in a field of several. A field of a file panel the
    /// system draws is selected the same way (`selectsFieldsByTripleClick`), whatever it holds.
    static let selectAll: [Gesture] = [
        .key(code: Key.upArrow, modifiers: .command),
        .key(code: Key.downArrow, modifiers: [.command, .shift]),
        .character("a", modifiers: .command),
    ]

    /// How a field is focused and prepared before the text: at its end to append, and to replace,
    /// by what its value says it holds (`selectAll`), or by clicks alone where `byTripleClick` says so.
    static func preparing(
        field value  : String?,
        at point     : CGPoint,
        replacing    : Bool,
        byTripleClick: Bool
    ) -> [Gesture] {
        guard replacing else { return [.click(at: point), endOfField] }
        switch value {
            case nil:                       return [.click(at: point, count: 3)]
            case ""?:                       return [.click(at: point)]
            case .some where byTripleClick: return [.click(at: point, count: 3)]
            case .some:                     return [.click(at: point)] + selectAll
        }
    }

    /// The extension kept when `text` replaces the file name `value` in a file panel: measured on
    /// 30/09/2026, Photoshop's Save As panel selects only the base name and saves exactly what the field
    /// holds, so a triple click would drop it. Nil when `text` has an extension of its own or is a path.
    static func keptExtension(of value: String?, replacedBy text: String) -> Substring? {
        func fileExtension(_ name: Substring) -> Substring? {
            guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
            let suffix = name[name.index(after: dot)...]
            guard (1...6).contains(suffix.count),
                  suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
            else { return nil }
            return suffix
        }
        guard let value, !text.contains("/"), !text.hasPrefix("~"), fileExtension(Substring(text)) == nil,
              let name = value.split(separator: "/", omittingEmptySubsequences: false).last
        else { return nil }
        return fileExtension(name)
    }

    /// Command and Down, the key binding that moves to the end of a document, and of a field.
    static let endOfField: Gesture = .key(code: Key.downArrow, modifiers: .command)

    /// Said after a Command chord whose effect was not seen on a background window.
    static let menuShortcutNote = " Background support for a menu shortcut depends on the target. "
        + "Verify the intended effect; prefer the menu tool or the target's contextual menu for an unsupported "
        + "shortcut. Do not repeat an unconfirmed command."

    /// Preserves a caller-established focus and selection. Pixel text alone cannot verify the
    /// resulting value, and an uncertain insertion must never be replayed automatically.
    private func insertText(
        _ text        : String,
        expecting     : String?,
        _ request     : InputRequest
    ) async -> ActOutcome {
        guard !text.isEmpty else { return ActOutcome(.refused, "insert_text needs a nonempty text") }
        if request.isDryRun {
            return ActOutcome(.dryRun, "would insert \(text.count) characters at the current focus and selection")
        }
        let pid = request.processID
        if let error = await send([.insert(text)], to: pid) {
            return ActOutcome(.actedUnverified, "inserting text: delivery failed: \(error); observe before any retry")
        }
        await settle(pid)
        let after = await perceive(pid)?.scene
        let value = await dependencies.controls?.focusedFieldValue(in: pid)
        let verified = expecting != nil && value != nil && value == expecting
        await dependencies.actuator.confirm(verified ? .observed : .unknown, in: pid)
        if verified, let value {
            return ActOutcome(.foundActed, "inserted text: the focused field reads '\(Self.shortened(value))'",
                              scene: after)
        }
        return ActOutcome(.actedUnverified,
            "inserted text at the current focus and selection, but the exact resulting value is unconfirmed; "
            + "observe its effect before further input and never insert again blindly", scene: after)
    }

    private func typeText(
        _ text     : String,
        into field : String,
        replacing  : Bool,
        _ request  : InputRequest,
        perceived  : PerceivedWindow
    ) async -> ActOutcome {
        let pid = request.processID
        guard !text.isEmpty else { return ActOutcome(.refused, "type_text needs a nonempty text") }
        let element: SceneElement
        do throws(Unresolved) {
            element = try resolved(
                field, section: request.section, in: perceived.scene, appName: request.appName,
                preferNativeControls: true, preferTextEntry: true
            )
        } catch {
            return error.outcome
        }
        let point = perceived.globalPoint(of: element)
        let kept = replacing && permissions.selectsFieldsByTripleClick
            ? Self.keptExtension(of: element.value, replacedBy: text)
            : nil
        let typed   = kept.map { text + "." + $0 } ?? text
        let keeping = kept.map { " (kept the extension .\($0))" } ?? ""
        // Short per-character events lose supplementary Unicode in Qt and renderers. Bulk payloads
        // preserve it and line breaks, without replaying a partially delivered edit.
        let inserts = typed.count > Self.typedTextLimit || typed.unicodeScalars.contains {
            $0.value > 0xFFFF || $0 == "\n" || $0 == "\r"
        }
        if request.isDryRun {
            return ActOutcome(.dryRun, "would click '\(element.label)' at \(Int(point.x)),\(Int(point.y)), "
                + (replacing ? "select what it holds" : "move to its end") + " and "
                + (inserts ? "insert" : "type") + " \(typed.count) characters"
                + (kept.map { ", keeping the extension .\($0)" } ?? ""))
        }
        await raiseIfNeeded(pid, isPopupOpen: (await surfaces(pid)).hasOpenPopup)
        let gestures = Self.preparing(
            field        : element.value,
            at           : point,
            replacing    : replacing,
            byTripleClick: permissions.selectsFieldsByTripleClick
        ) + [inserts ? .insert(typed) : .type(typed)]
        if let error = await send(gestures, to: pid) {
            return ActOutcome(.actedUnverified, "typing into '\(element.label)': delivery failed: \(error)")
        }
        await settle(pid)
        let after = await perceive(pid)?.scene
        let readBack = await dependencies.controls?.focusedFieldValue(in: pid)
            ?? after?.elements.first(where: { $0.id == element.id })?.value
        let wanted = replacing ? typed : element.value.map { $0 + text }
        await dependencies.actuator.confirm(readBack != nil && readBack == wanted ? .observed : .unknown, in: pid)
        let composing = inserts ? " This text is inserted as one event; an active input method may reject it." : ""
        switch (readBack, wanted) {
            case (.some(let value), .some(let wanted)) where value == wanted:
                return ActOutcome(.foundActed, "typed into '\(element.label)'\(keeping): the field reads "
                    + "'\(Self.shortened(value))'", scene: after)
            case (.some(let value), .some(let wanted)):
                return ActOutcome(.actedUnverified, "typed into '\(element.label)'\(keeping) but the field reads "
                    + "'\(Self.shortened(value))', not '\(Self.shortened(wanted))': observe and re-decide, do not "
                    + "type it again blindly.\(composing)", scene: after)
            case (.some(let value), nil):
                return ActOutcome(.actedUnverified, "typed into '\(element.label)' and the field reads "
                    + "'\(Self.shortened(value))', but what it held before could not be read, so the appended text "
                    + "cannot be confirmed: observe and re-decide.", scene: after)
            case (nil, _):
                return ActOutcome(.actedUnverified, "typed into '\(element.label)'\(keeping): no field's value could be "
                    + "read afterwards, so the text cannot be confirmed; observe before typing again.\(composing)",
                    scene: after)
        }
    }

    private func pressKey(
        _ chord  : KeyChord,
        times    : Int,
        _ request: InputRequest,
        perceived: PerceivedWindow
    ) async -> ActOutcome {
        let pid = request.processID
        if ActionPolicy.closesTheTarget(chord) {
            return ActOutcome(.refused, "\(chord) quits or closes what this session drives: refused. Use the "
                + "window's own control, or close the session.", scene: perceived.scene)
        }
        if ActionPolicy.isDestructive(chord), !permissions.allowsDestructive {
            return ActOutcome(.refused, "\(chord) deletes in most applications: refused. If you want the agent "
                + "to do this, the person must allow destructive actions.", scene: perceived.scene)
        }
        guard (1...InputRequest.maximumKeyPresses).contains(times) else {
            return ActOutcome(.refused, "a key is pressed 1 to \(InputRequest.maximumKeyPresses) times")
        }
        let pressed = "pressed \(chord)" + (times > 1 ? " \(times) times" : "")
        if request.isDryRun {
            return ActOutcome(.dryRun, "would press \(chord)" + (times > 1 ? " \(times) times" : "")
                + " into \(request.appName)'s window")
        }
        await raiseIfNeeded(pid, isPopupOpen: (await surfaces(pid)).hasOpenPopup)
        if let error = await send(Array(repeating: chord.gesture, count: times), to: pid) {
            return ActOutcome(.actedUnverified, "\(pressed): delivery failed: \(error)")
        }
        // A background chord's unchanged scene does not qualify the target's menu support.
        let note = dependencies.activation == nil && chord.modifiers.contains(.command) ? Self.menuShortcutNote : ""
        return await judged(
            pressed, in: request, before: perceived.scene, targetID: nil,
            ghost: "If you expected an effect, the key likely reached a control that ignores it: click the "
                + "control that should receive it first.\(note)",
            repaint: "A key's effect is often only a moved focus or caret, which the scene cannot attribute: "
                + "observe before pressing again.\(note)"
        )
    }

    private func scroll(
        lines      : Int,
        over target: String?,
        _ request  : InputRequest,
        perceived  : PerceivedWindow
    ) async -> ActOutcome {
        let pid = request.processID
        guard lines != 0, abs(lines) <= InputRequest.maximumScrollLines else {
            return ActOutcome(.refused, "a scroll turns 1 to \(InputRequest.maximumScrollLines) lines, up or down")
        }
        var element: SceneElement?
        if let target {
            do throws(Unresolved) {
                element = try resolved(target, section: request.section, in: perceived.scene, appName: request.appName)
            } catch {
                return error.outcome
            }
        }
        let point = element.map(perceived.globalPoint(of:))
            ?? CGPoint(x: perceived.frame.midX, y: perceived.frame.midY)
        let amount = "\(abs(lines)) line\(abs(lines) == 1 ? "" : "s") \(lines > 0 ? "up" : "down") over "
            + (element.map { "'\($0.label)'" } ?? "the window's centre")
        if request.isDryRun {
            return ActOutcome(.dryRun, "would scroll \(amount) at \(Int(point.x)),\(Int(point.y))")
        }
        let scrolled = "scrolled \(amount)"
        await raiseIfNeeded(pid, isPopupOpen: (await surfaces(pid)).hasOpenPopup)
        if let error = await send([.scroll(at: point, deltaY: lines)], to: pid) {
            return ActOutcome(.actedUnverified, "\(scrolled): delivery failed: \(error)")
        }
        return await judged(
            scrolled, in: request, before: perceived.scene, targetID: element?.id,
            ghost: "Nothing moved: the view may already be at its end, or nothing under that point scrolls; "
                + "target the scrolling panel itself.",
            repaint: "Observe to see whether other rows came into view."
        )
    }

    private func drag(
        from source: String,
        to end     : InputRequest.DragEnd,
        _ request  : InputRequest,
        perceived  : PerceivedWindow
    ) async -> ActOutcome {
        let pid = request.processID
        let scene = perceived.scene
        let element: SceneElement
        do throws(Unresolved) {
            element = try resolved(source, section: request.section, in: scene, appName: request.appName)
        } catch {
            return error.outcome
        }
        let start = perceived.globalPoint(of: element)
        let finish: CGPoint
        let destination: String
        switch end {
            case .target(let name):
                let other: SceneElement
                do throws(Unresolved) {
                    other = try resolved(name, section: request.section, in: scene, appName: request.appName)
                } catch {
                    return error.outcome
                }
                guard other.id != element.id else {
                    return ActOutcome(.refused, "a drag needs two different targets", scene: scene)
                }
                if ActionPolicy.isDestructive(label: other.label), !permissions.allowsDestructive {
                    return ActOutcome(.refused, "dropping on '\(other.label)' looks destructive/irreversible: "
                        + "refused. If you want the agent to do this, the person must allow destructive actions.",
                        scene: scene)
                }
                finish = perceived.globalPoint(of: other)
                destination = "'\(other.label)'"
            case .offset(let dx, let dy):
                guard dx != 0 || dy != 0 else { return ActOutcome(.refused, "a drag needs a nonzero offset") }
                finish = CGPoint(x: start.x + dx, y: start.y + dy)
                destination = "\(Int(dx)),\(Int(dy)) points away"
        }
        let dragged = "dragged '\(element.label)' to \(destination)"
        if request.isDryRun {
            return ActOutcome(.dryRun, "would drag '\(element.label)' from \(Int(start.x)),\(Int(start.y)) to "
                + "\(destination) at \(Int(finish.x)),\(Int(finish.y))")
        }
        await raiseIfNeeded(pid, isPopupOpen: (await surfaces(pid)).hasOpenPopup)
        if let error = await send([.drag(from: start, to: finish)], to: pid) {
            return ActOutcome(.actedUnverified, "\(dragged): delivery failed: \(error)")
        }
        return await judged(
            dragged, in: request, before: scene, targetID: element.id,
            ghost: "If you expected an effect, the press likely did not pick anything up: try a handle, a row "
                + "or the exact label.",
            repaint: "A drag that only moves things adds, removes and retitles nothing, so it cannot be told "
                + "from a repaint: observe to check where '\(element.label)' is now."
        )
    }

    /// A contextual menu is a pop-up of its own, so the row is chosen by the pop-up path: the keyboard,
    /// never a click through the menu.
    private func chooseInContextMenu(
        _ item   : String,
        on target: String,
        _ request: InputRequest,
        perceived: PerceivedWindow
    ) async -> ActOutcome {
        let pid = request.processID
        guard !LabelText.normalize(item).isEmpty else {
            return ActOutcome(.refused, "context_menu needs the item's title")
        }
        let element: SceneElement
        do throws(Unresolved) {
            element = try resolved(target, section: request.section, in: perceived.scene, appName: request.appName)
        } catch {
            return error.outcome
        }
        if ActionPolicy.isDestructive(label: item), !permissions.allowsDestructive {
            return ActOutcome(.refused, "'\(item)' looks destructive/irreversible: refused. If you want the agent "
                + "to do this, the person must allow destructive actions.", scene: perceived.scene)
        }
        if let refusal = menuOutsideTheSeat(on: element, appName: request.appName, scene: perceived.scene) {
            return refusal
        }
        let point = perceived.globalPoint(of: element)
        if request.isDryRun {
            return ActOutcome(.dryRun, "would right-click '\(element.label)' at \(Int(point.x)),\(Int(point.y)) "
                + "and choose '\(item)' in the contextual menu by keyboard")
        }
        let before = await surfaces(pid)
        await raiseIfNeeded(pid, isPopupOpen: before.hasOpenPopup)
        if let error = await send([.click(at: point, button: .right)], to: pid) {
            return ActOutcome(.actedUnverified, "right-clicking '\(element.label)': delivery failed: \(error)")
        }
        // The fixed pause on purpose: the menu is a window of its own, which the target's frames never show.
        await pause(timing.clickSettle)
        let popups = (await surfaces(pid)).popups
        guard let menu = popups.first(where: { !before.popups.contains($0) }) ?? popups.first,
              let opened = await perceive(pid) else {
            let after = await perceive(pid)?.scene
            await dependencies.actuator.confirm(.unknown, in: pid)
            return ActOutcome(.actedUnverified, "right-clicked '\(element.label)' but no contextual menu could be "
                + "read, so nothing was chosen: observe; this element may have no menu of its own", scene: after)
        }
        let rows = PopupRowPick.rows(in: opened.scene, windowFrame: opened.frame, popupFrame: menu)
        let wanted = LabelText.normalize(item)
        guard let row = rows.joined().first(where: { LabelText.normalize($0.label) == wanted }) else {
            // An item that is not there is never guessed at: the menu is closed instead.
            try? await dependencies.actuator.perform(.key(code: Key.escape), in: pid)
            await pause(timing.popupDismiss)
            let closed = !(await surfaces(pid)).hasOpenPopup
            let after = await perceive(pid)?.scene
            await dependencies.actuator.confirm(closed ? .observed : .unknown, in: pid)
            let offered = rows.compactMap { $0.first?.label }.prefix(14).map { "'\($0)'" }
            return ActOutcome(.honestMiss, "no item '\(item)' in the contextual menu of '\(element.label)'"
                + (offered.isEmpty ? "" : ": it offered \(offered.joined(separator: ", "))")
                + (closed ? "; the menu was closed" : "; the menu may still be open, observe"), scene: after)
        }
        let choice = ActionRequest(
            processID: pid, bundleID: request.bundleID, appName: request.appName, target: row.label, verb: .click
        )
        return await pickInPopup(choice, element: row, popupFrame: menu, perceived: opened)
    }

    // MARK: Helpers

    /// The roles whose contextual menu opens where the click landed, in every toolkit measured.
    private static let textFieldRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

    /// The refusal of a right click whose menu would open outside the seat, nil when it may go ahead.
    private func menuOutsideTheSeat(on element: SceneElement, appName: String, scene: SceneSnapshot) -> ActOutcome? {
        guard permissions.contextMenusOnTextFieldsOnly, !Self.textFieldRoles.contains(element.role ?? "") else {
            return nil
        }
        return ActOutcome(.refused, "\(appName) opens the contextual menu of '\(element.label)' on the person's own "
            + "screen, outside the seat, so it was not right-clicked: use a visible button or control instead. "
            + "A text field's contextual menu still works here.", scene: scene)
    }

    /// The element a target names in this scene, or the outcome that says why there is none: several
    /// share the name, or none has it.
    private func resolved(
        _ target            : String,
        section             : String?,
        in scene            : SceneSnapshot,
        appName             : String,
        preferStateful      : Bool = false,
        preferNativeControls: Bool = false,
        preferTextEntry      : Bool = false
    ) throws(Unresolved) -> SceneElement {
        let resolution = scene.resolve(
            target: target, preferStateful: preferStateful, section: section,
            preferNativeControls: preferNativeControls, preferTextEntry: preferTextEntry
        )
        switch resolution {
            case .found(let found):
                return found
            case .ambiguous(let count):
                throw Unresolved(outcome: ActOutcome(
                    .ambiguous,
                    "\(count) elements labeled '\(target)': choose an exact element ID or section: "
                    + scene.disambiguation(target: target), scene: scene))
            case .none:
                let near = scene.grep(goal: target).prefix(3)
                    .map { "'\($0.element.label)'" + ($0.element.section.map { " (\($0))" } ?? "") }
                throw Unresolved(outcome: ActOutcome(.honestMiss, "no element '\(target)' in \(appName)"
                    + (near.isEmpty ? "" : ": closest on screen: \(near.joined(separator: ", "))"), scene: scene))
        }
    }

    /// Why a target named no element, as the outcome that says so.
    private struct Unresolved: Error {
        let outcome: ActOutcome
    }

    /// Raises the application when a foreground gesture needs it, by the activation policy.
    private func raiseIfNeeded(_ processID: pid_t, isPopupOpen: Bool) async {
        guard let activation = dependencies.activation else { return }
        let frontmost = await activation.frontmostProcessID()
        if ActivationPolicy.needsActivation(target: processID, frontmost: frontmost, isPopupOpen: isPopupOpen) {
            await activation.activate(processID)
            await pause(timing.activateSettle)
        }
    }

    /// Waits for a gesture's effect before it is judged: the settling role's wait, capped at the click
    /// settle, when the composition gave one, and otherwise the click settle itself.
    private func settle(_ processID: pid_t) async {
        guard let settling = dependencies.settling else { return await pause(timing.clickSettle) }
        await settling.settle(in: processID, cap: timing.clickSettle)
    }

    /// Delivers the gestures in order and answers the error that stopped them, nil when all went out.
    /// A failure closes the delivery as unknown: what went out before it is never repeated.
    private func send(_ gestures: [Gesture], to processID: pid_t) async -> (any Error)? {
        do {
            for gesture in gestures { try await dependencies.actuator.perform(gesture, in: processID) }
            return nil
        } catch {
            await dependencies.actuator.confirm(.unknown, in: processID)
            return error
        }
    }

    /// An input with no reading of its own is judged by the two scenes alone, and its delivery closed
    /// with what they showed. `ghost` and `repaint` are what to do next when nothing was attributed.
    private func judged(
        _ performed: String,
        in request : InputRequest,
        before     : SceneSnapshot,
        targetID   : String?,
        ghost      : String,
        repaint    : String
    ) async -> ActOutcome {
        let pid = request.processID
        await settle(pid)
        guard let after = await perceive(pid)?.scene else {
            await dependencies.actuator.confirm(.unknown, in: pid)
            return ActOutcome(.actedUnverified, "\(performed): no scene could be read afterwards; observe when "
                + "the window is back")
        }
        let effect = Self.gatedEffect(
            before: before, after: after, targetID: targetID ?? "", popupIsOpen: (await surfaces(pid)).hasOpenPopup
        )
        let verdict = ActVerification.verdict(before: before, after: after, effect: effect)
        let delivery: DeliveryEffect = switch verdict {
            case .landed        : .observed
            case .ghost         : .absent
            case .unattributable: .unknown
        }
        await dependencies.actuator.confirm(delivery, in: pid)
        switch verdict {
            case .landed(let effect, _):
                return ActOutcome(.foundActed, "\(performed): \(effect.summary)", scene: after)
            case .ghost:
                return ActOutcome(.actedUnverified, "\(performed): this window did NOT change (identical scene). "
                    + ghost, scene: after)
            case .unattributable:
                return ActOutcome(.actedUnverified, "\(performed): the window's pixels changed but nothing "
                    + "structural did. \(repaint)", scene: after)
        }
    }

    /// A value a sentence quotes, cut so the sentence stays readable.
    private static func shortened(_ value: String) -> String {
        let flat = value.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 60 ? flat.prefix(59) + "…" : flat
    }

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
            return "no scene: \(appName) has NO window open right now "
                + "(it is running, but there is nothing to show or "
                + "capture). "
                + "Open a document or window in it first, then describe_scene."
        }
        return "no scene: \(appName) has a window but it could not be perceived right now; "
            + "retry, and if this repeats "
            + "check Screen Recording for the process that runs the engine."
    }
}
