//
//  MenuBarCommandTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/09/2026.
//

import ApplicationServices
@testable import AutomationRuntime
import EngineCore
import PerceptionCore
import Testing

/// The walk of a menu path over a fake menu bar shaped like Photoshop's, measured on 30/09/2026.
@MainActor
@Suite("Reaching a menu bar item by its path")
struct MenuBarCommandTests {

    /// A node of the fake bar: its title, whether it is enabled, its key equivalent and its items.
    final class Node {
        let title    : String
        let enabled  : Bool
        let key      : String?
        let modifiers: Int
        let children : [Node]
        init(_ title: String, enabled: Bool = true, key: String? = nil, modifiers: Int = 0, _ children: [Node] = []) {
            self.title = title; self.enabled = enabled; self.key = key; self.modifiers = modifiers
            self.children = children
        }
    }

    static let bar = Node("", [
        Node("Apple", [Node("Restart...")]),
        Node("Photoshop 2026", [Node("Hide Photoshop"), Node("Quit Photoshop")]),
        Node("File", [Node("New..."), Node("Close"), Node("Save", enabled: false), Node(""), Node("Save As...")]),
        Node("Layer", [Node("New", [Node("Layer..."), Node("Group...")]), Node("Delete", [Node("Layer", enabled: false)])]),
    ])

    func resolve(_ path: String, allowsDestructive: Bool = false) -> MenuBarCommand.Resolution<Node> {
        MenuBarCommand.resolve(MenuBarCommand.steps(of: path), from: Self.bar, allowsDestructive: allowsDestructive) {
            $0.children.map { MenuBarCommand.Item(title: $0.title, isEnabled: $0.enabled, element: $0) }
        }
    }

    @Test("an item is pressed by its path, whatever its case and ellipsis")
    func anItemIsPressed() {
        guard case .press(let node, let path) = resolve("layer > new > layer") else {
            Issue.record("the item was not pressed"); return
        }
        #expect(node.title == "Layer...")
        #expect(path == "Layer > New > Layer...")
        guard case .press(_, "File > Save As...") = resolve("File>Save As…") else {
            Issue.record("the ellipsis told two titles apart"); return
        }
    }

    @Test("a path that ends on a menu lists it and presses nothing")
    func aMenuIsListed() {
        guard case .list(let path, let items) = resolve("File") else { Issue.record("the menu was not listed"); return }
        #expect(path == "File")
        #expect(items == ["New...", "Close", "Save (disabled)", "Save As..."])
        guard case .list(_, let layer) = resolve("Layer") else { Issue.record("the menu was not listed"); return }
        #expect(layer == ["New >", "Delete >"])
    }

    @Test("the Apple menu, a disabled, hiding or destructive item and a missing one are not pressed")
    func refusals() {
        func kind(_ path: String, allowsDestructive: Bool = false) -> ActOutcomeKind? {
            switch resolve(path, allowsDestructive: allowsDestructive) {
                case .outcome(let outcome): return outcome.kind
                case .disabled            : return .refused
                case .press, .list        : return nil
            }
        }
        #expect(kind("Apple > Restart...") == .refused)
        #expect(kind("File > Save") == .refused)
        // A disabled item is its own answer: it is what gives a stale application a moment in front.
        guard case .disabled("File > Save") = resolve("File > Save") else { Issue.record("not read as disabled"); return }
        #expect(kind("Photoshop 2026 > Hide Photoshop") == .refused)
        #expect(kind("Photoshop 2026 > Quit Photoshop") == .refused)
        #expect(kind("Photoshop 2026 > Quit Photoshop", allowsDestructive: true) == nil)
        // Measured on 30/09/2026: Layer > Delete > Layer was pressed, its last step being "Layer".
        #expect(kind("Layer > Delete > Layer") == .refused)
        // Disabled in the fake, as it was in Photoshop: destructive is still the answer.
        guard case .outcome(let deleted) = resolve("Layer > Delete > Layer") else { Issue.record("pressed"); return }
        #expect(deleted.message.contains("destructive"))
        #expect(kind("File > Export") == .honestMiss)
        #expect(kind("") == .honestMiss)
    }

    @Test("the poll of a moment in front reads an enabled item as ready, and nothing else")
    func enabledPredicate() {
        func isEnabled(_ path: String) -> Bool {
            MenuBarCommand.isEnabled(MenuBarCommand.steps(of: path), from: Self.bar) {
                $0.children.map { MenuBarCommand.Item(title: $0.title, isEnabled: $0.enabled, element: $0) }
            }
        }
        #expect(isEnabled("File > Save As..."))
        #expect(isEnabled("layer > new > layer"))
        #expect(!isEnabled("File > Save"), "disabled")
        #expect(!isEnabled("Layer > Delete > Layer"), "disabled, whatever the destructive policy says")
        #expect(!isEnabled("File > Export"), "missing")
        #expect(!isEnabled("File"), "a menu is not an item")
    }

    @Test("An enabled Adobe command is prepared once and resolves its current item before dispatch")
    func anEnabledCommandNeedsItsPreparedItem() async {
        let stale = Node("New...")
        let current = Node("New...")
        var prepared = false
        var effect = false
        var trace: [String] = []
        let result = await MenuBarCommand.runPrepared(
            preparesEnabledItems: true,
            read: {
                trace.append("read")
                return .press(prepared ? current : stale, path: "File > New...")
            },
            press: {
                trace.append("press")
                effect = prepared && $0 === current
                return .success
            },
            refresh: { trace.append("prepare"); prepared = true; return .readAgain }
        )
        #expect(trace == ["read", "prepare", "read", "press"])
        #expect(effect)
        #expect(result.pressed == "File > New...")
    }

    @Test("An enabled command is never dispatched when preparation or handback refuses", arguments: [
        MenuBarCommand.Refresh.stillDisabled(reason: nil),
        .stillDisabled(reason: "The person's focus did not return."),
        .blockedByDialog
    ])
    func aPreparationRefusalPostsNothing(_ refusal: MenuBarCommand.Refresh) async {
        var presses = 0
        var preparations = 0
        let result = await MenuBarCommand.runPrepared(
            preparesEnabledItems: true,
            read: { .press(Node("New..."), path: "File > New...") },
            press: { _ in presses += 1; return .success },
            refresh: { preparations += 1; return refusal }
        )
        #expect(presses == 0)
        #expect(preparations == 1)
        #expect(result.pressed == nil)
        #expect(result.outcome.kind == .refused)
    }

    @Test("Listing a menu and refusing a destructive path never request foreground preparation")
    func nonCommandsNeverPrepare() async {
        for path in ["File", "Layer > Delete > Layer"] {
            let result = await MenuBarCommand.runPrepared(
                preparesEnabledItems: true, read: { resolve(path) },
                press: { _ in Issue.record("No command is admitted"); return .success },
                refresh: { Issue.record("A listing or refusal must not activate"); return .readAgain }
            )
            #expect(result.pressed == nil)
        }
    }

    @Test("A command disabled after preparation refuses without a second preparation or press")
    func aChangedMenuCannotAuthorizeASecondPreparation() async {
        var preparations = 0
        let result = await MenuBarCommand.runPrepared(
            preparesEnabledItems: true,
            read: {
                preparations == 0 ? .press(Node("New..."), path: "File > New...")
                    : .disabled(path: "File > New...")
            },
            press: { _ in Issue.record("The refreshed item is disabled"); return .success },
            refresh: { preparations += 1; return .readAgain }
        )
        #expect(preparations == 1)
        #expect(result.pressed == nil)
        #expect(result.outcome.kind == .refused)
    }

    @Test("An admitted menu is resolved and pressed once during foreground, including an AX timeout",
          arguments: [AXError.success, .cannotComplete])
    func aScopedCommandUsesItsFreshItem(_ answer: AXError) async {
        let stale = Node("New...")
        let fresh = Node("New...")
        var inFront = false
        var presses = 0
        var reads = 0
        let result = await MenuBarCommand.runInFront(
            read: { reads += 1; return .press(inFront ? fresh : stale, path: "File > New...") },
            press: { item in
                #expect(inFront)
                #expect(item === fresh)
                presses += 1
                return answer
            },
            withFront: { command in
                inFront = true
                command()
                command()
                inFront = false
                return nil
            }
        )
        #expect(reads == 2)
        #expect(presses == 1)
        #expect(result.pressed == "File > New...")
        #expect(result.outcome.kind == .foundActed)
    }

    @Test("A scope refusal dispatches nothing; a failure after dispatch retains its possible effect",
          arguments: [false, true])
    func aScopedFailureRetainsDelivery(_ dispatches: Bool) async {
        var presses = 0
        let result = await MenuBarCommand.runInFront(
            read: { .press(Node("New..."), path: "File > New...") },
            press: { _ in presses += 1; return .success },
            withFront: { command in
                if dispatches { command() }
                return "The person's attested window was not verified."
            }
        )
        #expect(presses == (dispatches ? 1 : 0))
        #expect(result.outcome.kind == (dispatches ? .actedUnverified : .refused))
        #expect(result.pressed == (dispatches ? "File > New..." : nil))
        #expect(result.outcome.message.contains("not verified"))
        #expect(!dispatches || result.outcome.message.contains("Do not repeat"))
    }

    @Test("Observation failure after dispatch retains delivery and any handback failure",
          arguments: [false, true])
    func aFailedObservationRetainsTheScopedCommand(_ handbackFails: Bool) async {
        var presses = 0
        var observations = 0
        let dispatched = await MenuBarCommand.runInFront(
            read     : { .press(Node("New..."), path: "File > New...") },
            press    : { _ in presses += 1; return .success },
            withFront: { command in
                command()
                return handbackFails ? "The person's focus handback was not verified." : nil
            }
        )
        do {
            let result = try await MenuBarCommand.observedOutcome(
                dispatched.pressed,
                outcome  : dispatched.outcome,
                processID: -1,
                before   : [],
                observe  : {
                    observations += 1
                    throw AutomationFailure("The application's Seat is suspended.")
                }
            )
            #expect(result.kind == .actedUnverified)
            #expect(!result.isSuccess)
            #expect(result.scene == nil)
            #expect(result.message.contains("pressed File > New..."))
            #expect(result.message.contains("Seat is suspended"))
            #expect(result.message.contains("Do not repeat"))
            #expect(result.message.contains("Observe"))
            #expect(!handbackFails || result.message.contains("handback was not verified"))
        } catch {
            Issue.record("Observation erased an acknowledged dispatch: \(error)")
        }
        #expect(presses == 1)
        #expect(observations == 1)
    }

    private static let scene = SceneSnapshot(
        bundleID: "test", appName: "Test", windowTitle: "Open",
        viewportPixelSize: .init(width: 100, height: 100), elements: []
    )

    @Test("A handback that was not verified but is verified by the observation gets the window verdict",
          arguments: [true, false])
    func aLateVerifiedReturnGetsTheWindowVerdict(_ windowOpened: Bool) async throws {
        let dispatched = await MenuBarCommand.runInFront(
            read     : { .press(Node("Place Embedded..."), path: "File > Place Embedded...") },
            press    : { _ in .success },
            withFront: { command in command(); return "The return was not verified." }
        )
        let result = try await MenuBarCommand.observedOutcome(
            dispatched.pressed,
            outcome      : dispatched.outcome,
            processID    : -1,
            before       : windowOpened ? ["AXWindow|AXDialog|Open"] : [],
            frontIssue   : "The return was not verified.",
            frontReturned: { true },
            observe      : { Self.scene }
        )
        #expect(result.kind == (windowOpened ? .foundActed : .actedUnverified))
        #expect(result.scene == Self.scene)
        #expect(!result.message.contains("not verified"))
        #expect(!result.message.contains("Observe"))
    }

    @Test("A handback still not verified keeps actedUnverified with the scene and no advice to observe")
    func aReturnStillNotVerifiedAttachesTheSceneAndAsksForNothing() async throws {
        let dispatched = await MenuBarCommand.runInFront(
            read     : { .press(Node("Place Embedded..."), path: "File > Place Embedded...") },
            press    : { _ in .success },
            withFront: { command in command(); return "The return was not verified." }
        )
        let result = try await MenuBarCommand.observedOutcome(
            dispatched.pressed,
            outcome      : dispatched.outcome,
            processID    : -1,
            before       : [],
            frontIssue   : "The return was not verified.",
            frontReturned: { false },
            observe      : { Self.scene }
        )
        #expect(result.kind == .actedUnverified)
        #expect(result.scene == Self.scene)
        #expect(result.message.hasPrefix("pressed File > Place Embedded... The return was not verified."))
        #expect(!result.message.localizedCaseInsensitiveContains("observe"))
        #expect(result.message.contains("Do not repeat"))
    }

    @Test("An unprepared listing warns that disabled flags and history may be stale without requesting input")
    func aBackgroundListingDoesNotEstablishCommandAvailability() async {
        let result = await MenuBarCommand.runInFront(
            read     : { self.resolve("File") },
            press    : { _ in Issue.record("A listing must not press"); return .success },
            withFront: { _ in Issue.record("A listing must not activate"); return nil }
        )
        #expect(result.pressed == nil)
        #expect(result.outcome.kind == .actedNoop)
        #expect(result.outcome.message.contains("Save (disabled)"))
        #expect(result.outcome.message.contains("without activating"))
        #expect(result.outcome.message.contains("may be stale"))
        #expect(result.outcome.message.contains("full command path"))
    }

    @Test("A listing, missing path and destructive refusal never enter an input scope",
          arguments: ["File", "File > Missing", "Layer > Delete > Layer"])
    func aNonCommandNeverEntersTheScope(_ path: String) async {
        let result = await MenuBarCommand.runInFront(
            read: { self.resolve(path) },
            press: { _ in Issue.record("No admitted command"); return .success },
            withFront: { _ in Issue.record("No foreground scope is allowed"); return nil }
        )
        #expect(result.pressed == nil)
    }

    @Test("A menu disabled after readiness cannot dispatch or repeat the scope")
    func aScopedMenuMustStillBeEnabled() async {
        var scopes = 0
        let result = await MenuBarCommand.runInFront(
            read: {
                scopes == 0 ? .press(Node("New..."), path: "File > New...")
                    : .disabled(path: "File > New...")
            },
            press: { _ in Issue.record("The fresh item is disabled"); return .success },
            withFront: { command in scopes += 1; command(); return nil }
        )
        #expect(scopes == 1)
        #expect(result.pressed == nil)
        #expect(result.outcome.kind == .refused)
    }

    @Test("Redo's cold title may expand when activation validates its current command")
    func aRedoTitleCanExpandDuringActivation() async {
        let cold = Node("Redo", enabled: false)
        let current = Node("Redo Typing")
        var inFront = false
        var presses = 0
        func menu() -> Node {
            Node("", [Node("Apple"), Node("TextEdit"), Node("Edit", [inFront ? current : cold])])
        }
        func items(_ node: Node) -> [MenuBarCommand.Item<Node>] {
            node.children.map { MenuBarCommand.Item(title: $0.title, isEnabled: $0.enabled, element: $0) }
        }
        let result = await MenuBarCommand.runInFront(
            read: {
                MenuBarCommand.resolve(["Edit", "Redo"], from: menu(), allowsDestructive: false, items: items)
            },
            press: { item in
                #expect(inFront && item === current)
                presses += 1
                return .success
            },
            withFront: { command in
                inFront = true
                #expect(MenuBarCommand.isEnabled(["Edit", "Redo"], from: menu(), items: items))
                command()
                inFront = false
                return nil
            }
        )
        #expect(presses == 1)
        #expect(result.pressed == "Edit > Redo Typing")
    }

    @Test("dynamic Undo and Redo require one candidate and never broaden other command paths")
    func aDynamicEditingTitleMustBeUnique() {
        func resolve(_ wanted: String, titles: [String], disabled: Set<String> = []) -> MenuBarCommand.Resolution<Node> {
            let menu = Node("", [Node("Apple"), Node("TextEdit"),
                                 Node("Edit", titles.map { Node($0, enabled: !disabled.contains($0)) })])
            return MenuBarCommand.resolve(["Edit", wanted], from: menu, allowsDestructive: false) {
                $0.children.map { MenuBarCommand.Item(title: $0.title, isEnabled: $0.enabled, element: $0) }
            }
        }
        for verb in ["Undo", "Redo"] {
            guard case .press(_, "Edit > \(verb) Typing") = resolve(verb, titles: ["\(verb) Typing"]) else {
                Issue.record("The current editing command was not resolved"); continue
            }
            if case .press = resolve(verb, titles: ["\(verb) Typing", "\(verb) Selection"]) {
                Issue.record("An ambiguous editing command must not dispatch")
            }
            guard case .press(_, "Edit > \(verb)") = resolve(verb, titles: [verb, "\(verb) Typing"]) else {
                Issue.record("The exact current title must win"); continue
            }
            guard case .disabled = resolve(verb, titles: [verb, "\(verb) Typing"], disabled: [verb]) else {
                Issue.record("A disabled exact command must not admit another command"); continue
            }
        }
        if case .press = resolve("Paste", titles: ["Paste and Match Style"]) {
            Issue.record("Other paths must retain exact matching")
        }
        if case .press = resolve("Redo", titles: ["Redoable"]) {
            Issue.record("A prefix without a word boundary is another command")
        }
    }

    /// A browser's menu bar around the File menu given, the Apple and application menus first.
    static func browser(file: [Node], applicationMenu: [Node] = [], appleMenu: [Node] = []) -> Node {
        Node("", [Node("Apple", appleMenu), Node("Browser", applicationMenu), Node("File", file),
                  Node("Window", [Node("Minimize", key: "M")])])
    }

    func newWindow(_ bar: Node) -> String? {
        MenuBarCommand.newWindowItem(from: bar) { node in
            node.children.map {
                MenuBarCommand.Item(title: $0.title, isEnabled: $0.enabled, element: $0,
                                    keyEquivalent: $0.key, keyEquivalentModifiers: $0.modifiers)
            }
        }?.path
    }

    // The keys as accessibility read them on 30/09/2026: modifiers 0 is Command alone, 1 adds Shift,
    // 2 Option, 4 Control, and 8 drops Command.
    @Test("a new window is Command-N, and a private window on Shift is never taken")
    func theNewWindowItemIsCommandN() {
        let chrome = Self.browser(file: [Node("New Tab", key: "T"), Node("New Window", key: "N"),
                                         Node("New Incognito Window", key: "N", modifiers: 1)])
        #expect(newWindow(chrome) == "File > New Window")
        #expect(newWindow(Self.browser(file: [Node("New Private Window", key: "N", modifiers: 1)])) == nil)
        #expect(newWindow(Self.browser(file: [Node("New Window", key: "N", modifiers: 3)])) == nil,
                "Shift with Option is still Shift")
        #expect(newWindow(Self.browser(file: [Node("New Window", key: "N", modifiers: 8)])) == nil,
                "N without Command is no key equivalent of a new window")
        #expect(newWindow(Self.browser(file: [Node("New Window", key: "n")])) == "File > New Window")
        #expect(newWindow(Self.browser(file: [Node("New Tab", key: "T"), Node("Open Location...", key: "L")])) == nil)
    }

    @Test("Safari with profiles opens its personal window on Option-Command-N, not a tab group on Control")
    func optionCommandNIsTakenWhenThereIsNoCommandN() {
        let safari = Self.browser(file: [Node("New Empty Tab Group", key: "N", modifiers: 4),
                                         Node("New Personal Window", key: "N", modifiers: 2),
                                         Node("New Work Window"),
                                         Node("New Private Window", key: "N", modifiers: 1),
                                         Node("New Tab", key: "T")])
        #expect(newWindow(safari) == "File > New Personal Window")
        let both = Self.browser(file: [Node("New Personal Window", key: "N", modifiers: 2),
                                       Node("New Window", key: "N")])
        #expect(newWindow(both) == "File > New Window", "Command alone wins over an earlier Option")
        let tied = Node("", [Node("Apple"), Node("Browser"),
                             Node("File", [Node("New Personal Window", key: "N", modifiers: 2)]),
                             Node("Window", [Node("New Work Window", key: "N", modifiers: 2)])])
        #expect(newWindow(tied) == "File > New Personal Window", "the bar's order breaks a tie")
    }

    @Test("a disabled item, and one in the Apple or the application menu, is not a new window")
    func disabledAndSystemItemsAreSkipped() {
        let disabled = Self.browser(file: [Node("New Window", enabled: false, key: "N"),
                                           Node("New Personal Window", key: "N", modifiers: 2)])
        #expect(newWindow(disabled) == "File > New Personal Window")
        #expect(newWindow(Self.browser(file: [Node("New Window", enabled: false, key: "N")])) == nil)
        #expect(newWindow(Self.browser(file: [], applicationMenu: [Node("New Window", key: "N")])) == nil)
        #expect(newWindow(Self.browser(file: [], appleMenu: [Node("New Window", key: "N")])) == nil)
    }
}
