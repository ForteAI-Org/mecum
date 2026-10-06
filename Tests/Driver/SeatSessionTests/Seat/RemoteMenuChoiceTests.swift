//
//  RemoteMenuChoiceTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/10/2026.
//

import ApplicationServices
import CoreGraphics
@testable import SeatDriving
import Testing

/// The choice of one item in a remote file panel's popup menu, over a menu this suite writes. The
/// titles are the Where popup's as read on 05/10/2026, bidi isolates included (ADR 0031).
@MainActor
@Suite("Choosing in a remote file panel's menu")
struct RemoteMenuChoiceTests {

    /// One accessibility element of a menu, with the actions performed on it.
    final class Node {
        let role     : String
        let title    : String?
        let frame    : CGRect?
        let isEnabled: Bool
        let children : [Node]
        var performed: [String] = []
        var answer   = AXError.success

        init(
            _ role   : String,
            title    : String? = nil,
            frame    : CGRect? = nil,
            isEnabled: Bool = true,
            children : [Node] = []
        ) {
            self.role      = role
            self.title     = title
            self.frame     = frame
            self.isEnabled = isEnabled
            self.children  = children
        }
    }

    static var choice: RemoteMenuChoice<Node> {
        RemoteMenuChoice(
            role     : { $0.role },
            title    : { $0.title },
            isEnabled: { $0.isEnabled },
            frame    : { $0.frame },
            children : { $0.children },
            perform  : { node, action in node.performed.append(action); return node.answer }
        )
    }

    static let menuFrame = CGRect(x: 2000, y: 700, width: 220, height: 160)

    static func item(_ title: String, row: Int, isEnabled: Bool = true) -> Node {
        Node(kAXMenuItemRole, title: title,
             frame: CGRect(x: 2004, y: 700 + CGFloat(row) * 20, width: 200, height: 20), isEnabled: isEnabled)
    }

    /// The Where menu: isolate-wrapped iCloud folders, a separator, iCloud Drive twice, a
    /// disabled heading.
    static func whereMenu() -> (root: Node, menu: Node, items: [Node]) {
        let items = [
            item("\u{2068}Desktop\u{2069} \u{2014} iCloud", row: 0),
            item("\u{2068}Documents\u{2069} \u{2014} iCloud", row: 1),
            item("", row: 2),
            item("iCloud Drive", row: 3),
            item("Recent Places", row: 4, isEnabled: false),
            item("iCloud Drive", row: 5),
            item("\u{200E}Downloads\u{200F}", row: 6),
        ]
        let menu = Node(kAXMenuRole, children: items)
        return (Node("AXApplication", children: [Node(kAXPopUpButtonRole, children: [menu])]), menu, items)
    }

    @Test("a title is compared without its bidi isolates and marks")
    func titlesAreNormalized() {
        let wrapped = "\u{2068}Desktop\u{2069} \u{2014} iCloud"
        #expect(RemoteMenuChoice<Node>.normalized(wrapped) == "Desktop \u{2014} iCloud")
        #expect(RemoteMenuChoice<Node>.normalized("\u{2066}a\u{2067}b\u{200E}c\u{200F} ") == "abc")
    }

    @Test("the one item of that title is pressed, whatever its case and isolates", arguments: [
        "Desktop \u{2014} iCloud", "desktop \u{2014} ICLOUD", "\u{2068}Desktop\u{2069} \u{2014} iCloud", "downloads",
    ])
    func aUniqueTitleIsPressed(item: String) throws {
        let (root, menu, items) = Self.whereMenu()
        #expect(try Self.choice.choose(item, in: Self.menuFrame, under: [root]) == .chosen)
        #expect(items.filter { $0.performed == [kAXPressAction] }.count == 1)
        #expect(menu.performed.isEmpty, "a chosen item closes the menu by itself")
    }

    @Test("a title's start names the one item that begins with it")
    func aTitlesStartNamesItsItem() throws {
        let (root, _, items) = Self.whereMenu()
        #expect(try Self.choice.choose("Documents", in: Self.menuFrame, under: [root]) == .chosen)
        #expect(items[1].performed == [kAXPressAction], "Documents names its iCloud item")
    }

    @Test("a duplicate title is a miss that lists the menu and cancels it")
    func aDuplicateIsAMiss() throws {
        let (root, menu, items) = Self.whereMenu()
        let outcome = try Self.choice.choose("iCloud Drive", in: Self.menuFrame, under: [root])

        #expect(outcome == .missing(listing:
            "Desktop \u{2014} iCloud, Documents \u{2014} iCloud, iCloud Drive (twice), Downloads"))
        #expect(items.allSatisfy { $0.performed.isEmpty }, "neither copy is pressed")
        #expect(menu.performed == [kAXCancelAction])
    }

    @Test("a missing, cut or disabled title is a miss that cancels the menu", arguments: ["Library", "Desk", "Recent Places"])
    func aMissingTitleIsAMiss(item: String) throws {
        let (root, menu, items) = Self.whereMenu()
        guard case .missing(let listing)? = try? Self.choice.choose(item, in: Self.menuFrame, under: [root]) else {
            Issue.record("the choice was not a miss")
            return
        }
        #expect(listing?.contains("Recent Places") == false, "a disabled item is not offered")
        #expect(items.allSatisfy { $0.performed.isEmpty })
        #expect(menu.performed == [kAXCancelAction])
    }

    @Test("the host's tree is read first, and the panel service's when the host shows no menu")
    func theServiceTreeIsTheFallback() throws {
        let host = Node("AXApplication")
        let (service, _, items) = Self.whereMenu()
        #expect(try Self.choice.choose("Downloads", in: Self.menuFrame, under: [host, service]) == .chosen)
        #expect(items[6].performed == [kAXPressAction])
        #expect(try Self.choice.choose("Downloads", in: Self.menuFrame, under: [host]) == .missing(listing: nil))
    }

    @Test("a refused press throws, so the seat's cleanup closes the menu")
    func aRefusedPressThrows() {
        let (root, _, items) = Self.whereMenu()
        items[0].answer = .actionUnsupported
        #expect(throws: RemoteMenuFailure.self) {
            try Self.choice.choose("Desktop \u{2014} iCloud", in: Self.menuFrame, under: [root])
        }
    }
}
