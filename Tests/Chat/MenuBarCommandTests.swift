//
//  MenuBarCommandTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/09/2026.
//

import AutomationRuntime
import EngineCore
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
