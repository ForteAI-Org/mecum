//
//  RemoteMenuChoice.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/10/2026.
//

import ApplicationServices
import CoreGraphics
import Foundation
import PerceptionCore

/// RemoteMenuChoice chooses one item in the menu a remote file panel's popup opened, through
/// accessibility alone, and closes that menu itself when the item is not there (ADR 0031).
///
/// The panel service owns that menu: neither a host preparation cycle nor an Escape to the host
/// is known to close it, while AXCancel on its AXMenu answered 0 and closed it (Resolve,
/// 05/10/2026). Titles are compared without the bidi isolates and marks the service wraps names
/// in, ignoring case: Where read Desktop and Documents inside isolates, and iCloud Drive twice. It is generic
/// over the node so the decision is proved without a menu on the screen.
struct RemoteMenuChoice<Node> {

    /// What one choice came to.
    enum Outcome: Equatable {

        /// The one enabled item of that title was pressed.
        case chosen

        /// No single enabled item has that title. AXCancel was asked of the menu, and the
        /// listing names its enabled titles, nil when no item could be read at all.
        case missing(listing: String?)
    }

    let role     : (Node) -> String?
    let title    : (Node) -> String?
    let isEnabled: (Node) -> Bool
    let frame    : (Node) -> CGRect?
    let children : (Node) -> [Node]
    let perform  : (Node, String) -> AXError

    /// Presses the item titled `item` in the menu painted at `menuFrame`, read from the first of
    /// `roots` that shows the menu: the host's tree before the panel service's. A refused press
    /// throws, since the menu may still be open.
    func choose(_ item: String, in menuFrame: CGRect, under roots: [Node]) throws -> Outcome {
        guard let reading = roots.lazy.map({ self.read(menuFrame, under: $0) }).first(where: { $0.menu != nil })
        else { return .missing(listing: nil) }
        let enabled = reading.items.filter(\.isEnabled)
        if let index = LabelText.menuItemMatch(item, in: enabled.map(\.title)) {
            let code = perform(enabled[index].node, kAXPressAction)
            guard code == .success || code == .cannotComplete else {
                throw RemoteMenuFailure.pressRefused(code: code.rawValue)
            }
            return .chosen
        }
        // Its effect is the seat's to verify: it waits for the menu window to go.
        if let menu = reading.menu { _ = perform(menu, kAXCancelAction) }
        return .missing(listing: enabled.isEmpty ? nil : Self.listing(of: enabled.map(\.title)))
    }

    /// The title as compared: `LabelText.withoutBidiControls`.
    static func normalized(_ title: String) -> String { LabelText.withoutBidiControls(title) }

    /// The titles in menu order, a repeated one named once with how often it appears.
    static func listing(of titles: [String]) -> String {
        var order : [String] = []
        var counts: [String: Int] = [:]
        for title in titles {
            let key = title.lowercased()
            if counts[key] == nil { order.append(title) }
            counts[key, default: 0] += 1
        }
        return order.map { title in
            switch counts[title.lowercased()] ?? 1 {
                case 1: title
                case 2: "\(title) (twice)"
                case let times: "\(title) (\(times) times)"
            }
        }.joined(separator: ", ")
    }

    /// The menu items painted inside `menuFrame` under `root`, with the AXMenu holding the first
    /// of them. A separator has no title and is skipped. The walk stops at the same depth as
    /// `DropdownOpening`'s and never enters a web area's option mirrors.
    private func read(
        _ menuFrame: CGRect,
        under root : Node
    ) -> (menu: Node?, items: [(node: Node, title: String, isEnabled: Bool)]) {
        var menu : Node?
        var items: [(node: Node, title: String, isEnabled: Bool)] = []
        func visit(_ node: Node, _ depth: Int, _ enclosing: Node?) {
            guard depth < 16 else { return }
            let role = self.role(node) ?? ""
            guard role != "AXWebArea" else { return }
            let holder = role == kAXMenuRole ? node : enclosing
            if role == kAXMenuItemRole, let frame = frame(node),
               menuFrame.contains(CGPoint(x: frame.midX, y: frame.midY)) {
                let title = Self.normalized(self.title(node) ?? "")
                if !title.isEmpty {
                    if menu == nil { menu = holder }
                    items.append((node, title, isEnabled(node)))
                }
            }
            for child in children(node) { visit(child, depth + 1, holder) }
        }
        visit(root, 0, nil)
        return (menu, items)
    }
}

/// Why a remote menu's item could not be pressed. The menu may still be open, and the seat's
/// cleanup is what closes it.
enum RemoteMenuFailure: Error, CustomStringConvertible {
    case pressRefused(code: Int32)

    var description: String {
        switch self {
            case .pressRefused(let code):
                "the file panel's menu answered the item's press with error \(code); observe before retrying"
        }
    }
}

extension RemoteMenuChoice where Node == AXUIElement {

    /// The choice over the live accessibility trees, each read bounded like `DropdownOpening`'s.
    static var accessibility: RemoteMenuChoice<AXUIElement> {
        func attribute<Value>(_ node: AXUIElement, _ name: String) -> Value? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
            return value as? Value
        }
        return RemoteMenuChoice(
            role     : { attribute($0, kAXRoleAttribute) },
            title    : { attribute($0, kAXTitleAttribute) },
            isEnabled: { (attribute($0, kAXEnabledAttribute) as Bool?) == true },
            frame    : { node in
                guard let position: AXValue = attribute(node, kAXPositionAttribute),
                      let size: AXValue = attribute(node, kAXSizeAttribute)
                else { return nil }
                var origin = CGPoint.zero
                var extent = CGSize.zero
                guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent)
                else { return nil }
                return CGRect(origin: origin, size: extent)
            },
            children : { node in
                let children: [AXUIElement] = attribute(node, kAXChildrenAttribute) ?? []
                children.forEach { AXUIElementSetMessagingTimeout($0, 0.2) }
                return children
            },
            perform  : { node, action in
                AXUIElementSetMessagingTimeout(node, 0.5)
                return AXUIElementPerformAction(node, action as CFString)
            }
        )
    }

    /// The application roots to read, the host's first, each with a bounded messaging timeout.
    static func roots(host: pid_t, menuOwner: pid_t) -> [AXUIElement] {
        (host == menuOwner ? [host] : [host, menuOwner]).map { processID in
            let root = AXUIElementCreateApplication(processID)
            AXUIElementSetMessagingTimeout(root, 0.2)
            return root
        }
    }
}
