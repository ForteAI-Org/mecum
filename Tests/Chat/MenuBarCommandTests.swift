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

    /// A node of the fake bar: its title, whether it is enabled and its items.
    final class Node {
        let title   : String
        let enabled : Bool
        let children: [Node]
        init(_ title: String, enabled: Bool = true, _ children: [Node] = []) {
            self.title = title; self.enabled = enabled; self.children = children
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
}
