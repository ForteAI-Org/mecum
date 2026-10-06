import ApplicationServices
import PerceptionCore
import Testing
@testable import AccessibilityActions

@MainActor
@Suite("Native dropdown opening action")
struct DropdownOpeningTests {

    @Test("the primary dropdown action wins over its contextual menu action", arguments: [false, true])
    func primaryAction(reverse: Bool) {
        let actions = reverse ? [kAXShowMenuAction, kAXPressAction] : [kAXPressAction, kAXShowMenuAction]
        #expect(DropdownOpening.openingAction(in: actions) == kAXPressAction)
    }

    @Test("a dropdown exposing only its primary action can open")
    func primaryOnly() {
        #expect(DropdownOpening.openingAction(in: [kAXPressAction]) == kAXPressAction)
    }

    @Test("Show Menu remains available when it is the dropdown's only opening action")
    func showMenuOnly() {
        #expect(DropdownOpening.openingAction(in: [kAXShowMenuAction]) == kAXShowMenuAction)
        #expect(DropdownOpening.openingAction(in: []) == nil)
        #expect(DropdownOpening.openingAction(in: [kAXCancelAction]) == nil)
    }

    private let popup = CGRect(x: 200, y: 300, width: 160, height: 90)

    @Test("CEF's native popup item at depth twelve remains reachable")
    func nestedNativeItem() {
        let native = row("Beta")
        var nested = MenuNode("AXMenu", children: [native])
        for _ in 0..<10 { nested = MenuNode("AXGroup", children: [nested]) }
        let root = MenuNode("AXApplication", children: [nested])
        #expect(DropdownOpening.nativeMenuItem(named: "Beta", in: popup, under: root,
                                             reader: MenuReader()) === native)
    }

    @Test("native item traversal remains bounded on excessively deep trees")
    func deeplyNestedItemRefuses() {
        var nested = MenuNode("AXMenu", children: [row("Beta")])
        for _ in 0..<15 { nested = MenuNode("AXGroup", children: [nested]) }
        let root = MenuNode("AXApplication", children: [nested])
        #expect(DropdownOpening.nativeMenuItem(named: "Beta", in: popup, under: root,
                                             reader: MenuReader()) == nil)
    }

    @Test("a web option mirror does not make the real native menu item ambiguous")
    func webMirrorAndNativeMenu() {
        let mirror = row("Beta")
        let native = row("Beta")
        let root = MenuNode("AXApplication", children: [
            MenuNode("AXWebArea", children: [MenuNode("AXPopUpButton", children: [
                MenuNode("AXMenu", children: [mirror])
            ])]),
            MenuNode("AXMenu", children: [native])
        ])
        #expect(DropdownOpening.nativeMenuItem(named: "Beta", in: popup, under: root,
                                             reader: MenuReader()) === native)
    }

    @Test("a web option without a real native menu is not a native action recipient")
    func webOnlyRefuses() {
        let root = MenuNode("AXApplication", children: [
            MenuNode("AXWebArea", children: [MenuNode("AXMenu", children: [row("Beta")])])
        ])
        #expect(DropdownOpening.nativeMenuItem(named: "Beta", in: popup, under: root,
                                             reader: MenuReader()) == nil)
    }

    @Test("two real native items remain ambiguous, including a disabled duplicate")
    func nativeDuplicatesRefuse() {
        for enabled in [false, true] {
            let root = MenuNode("AXApplication", children: [
                MenuNode("AXMenu", children: [row("Beta"), row("Beta", enabled: enabled)])
            ])
            #expect(DropdownOpening.nativeMenuItem(named: "Beta", in: popup, under: root,
                                                 reader: MenuReader()) == nil)
        }
    }

    @Test("unpainted or disabled items are not native action recipients")
    func unusableItemsRefuse() {
        let items = [
            row("Beta", enabled: false),
            MenuNode("AXMenuItem", title: "Beta"),
            MenuNode("AXMenuItem", title: "Beta", frame: CGRect(x: 204, y: 900, width: 150, height: 20)),
            MenuNode("AXMenuItem", title: "Beta", frame: CGRect(x: 204, y: 310, width: 0, height: 20))
        ]
        for item in items {
            let root = MenuNode("AXApplication", children: [MenuNode("AXMenu", children: [item])])
            #expect(DropdownOpening.nativeMenuItem(named: "Beta", in: popup, under: root,
                                                 reader: MenuReader()) == nil)
        }
    }

    @Test("one painted enabled native item is resolved with the existing case matching")
    func oneNativeItem() {
        let native = row("Beta")
        let root = MenuNode("AXApplication", children: [MenuNode("AXMenu", children: [native])])
        #expect(DropdownOpening.nativeMenuItem(named: "beta", in: popup, under: root,
                                             reader: MenuReader()) === native)
        #expect(DropdownOpening.nativeMenuItem(named: "Gamma", in: popup, under: root,
                                             reader: MenuReader()) == nil)
    }

    @Test("a menu item matches its title read with straight quotes, an ellipsis as dots, or bidi isolates",
          arguments: [("Compress \u{201C}carla_video_bn\u{201D}", "Compress \"carla_video_bn\""),
                      ("Save As\u{2026}", "Save As..."), ("Save As\u{2026}", "save as"),
                      ("\u{2068}Desktop\u{2069} \u{2014} iCloud", "Desktop \u{2014} iCloud")])
    func menuTitlesCompareAsRead(title: String, typed: String) {
        let native = row(title)
        let root = MenuNode("AXApplication", children: [MenuNode("AXMenu", children: [native, row("Open")])])
        #expect(DropdownOpening.nativeMenuItem(named: typed, in: popup, under: root, reader: MenuReader()) === native)
    }

    @Test("a menu item named by the start of its title is the unique one that begins with it")
    func menuItemNamedByItsStart() {
        let compress = row("Compress \u{201C}carla_video_bianco_nero.mov\u{201D}")
        let open     = row("Open")
        let root = MenuNode("AXApplication", children: [MenuNode("AXMenu", children: [
            open, row("Open With"), compress
        ])])
        #expect(DropdownOpening.nativeMenuItem(named: "Compress", in: popup, under: root, reader: MenuReader()) === compress)
        #expect(DropdownOpening.nativeMenuItem(named: "Open", in: popup, under: root, reader: MenuReader()) === open)
        let twoLonger = MenuNode("AXApplication", children: [MenuNode("AXMenu", children: [
            row("Open With"), row("Open in New Tab")
        ])])
        #expect(DropdownOpening.nativeMenuItem(named: "Open", in: popup, under: twoLonger, reader: MenuReader()) == nil)
    }

    private func row(_ title: String, enabled: Bool = true) -> MenuNode {
        MenuNode("AXMenuItem", title: title,
                 frame: CGRect(x: 204, y: 310, width: 150, height: 20), enabled: enabled)
    }
}

private final class MenuNode {
    let role: String
    let title: String?
    let frame: CGRect?
    let enabled: Bool
    let children: [MenuNode]

    init(_ role: String, title: String? = nil, frame: CGRect? = nil,
         enabled: Bool = true, children: [MenuNode] = []) {
        self.role = role
        self.title = title
        self.frame = frame
        self.enabled = enabled
        self.children = children
    }
}

private struct MenuReader: AccessibilityTreeReading {
    func role(_ node: MenuNode) -> String? { node.role }
    func subrole(_ node: MenuNode) -> String? { nil }
    func title(_ node: MenuNode) -> String? { node.title }
    func descriptionText(_ node: MenuNode) -> String? { nil }
    func identifier(_ node: MenuNode) -> String? { nil }
    func value(_ node: MenuNode) -> String? { nil }
    func numericValue(_ node: MenuNode) -> Int? { nil }
    func isEnabled(_ node: MenuNode) -> Bool? { node.enabled }
    func actions(_ node: MenuNode) -> [String] { [kAXPressAction] }
    func frame(_ node: MenuNode) -> CGRect? { node.frame }
    func children(_ node: MenuNode) -> [MenuNode] { node.children }
}
