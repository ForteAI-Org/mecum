//
//  RemoteContentActuator.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/10/2026.
//

import ApplicationServices
import CoreGraphics
import SeatCore

/// RemoteContentActuator acts on one click addressed to an out of process
/// panel's content through accessibility, so no event reaches the panel
/// service and the host application is never activated (ADR 0031).
///
/// Measured on 05/10/2026 on 27: a routed click into a file panel's content
/// activated its host in 75 to 525 ms, and a click on a sidebar row of the
/// inactive panel was eaten, while the accessibility actions below did the same
/// work with the host left in the background, three of three each.
///
/// The element is the one the host application's hit test answers at the
/// Command's point, proved by `DialogEndpointResolver.remoteContentPath`, or for
/// an ordinary window of an application listed for it, Finder's, by
/// `ownContentPath` against the window itself. The
/// click reaches the nearest element of that path a click is mapped for; every
/// other Command refuses, and nothing falls back to posting.
///
/// It is generic over the node type so the mapping is proved without a panel
/// on the screen, as the resolver is.
nonisolated package struct RemoteContentActuator<Node: Equatable> {

    /// One attribute write the actuator makes.
    package enum Write: Equatable {
        case selected
        case focused
        case selectedTextRange(location: Int, length: Int)
        case selectedText(String)
    }

    /// The views a row of an ordinary window belongs to, which a pointer click gives the focus.
    package static var rowContainerRoles: Set<String> {
        [kAXOutlineRole, kAXTableRole, kAXBrowserRole]
    }

    /// The roles a single click presses.
    package static var pressedRoles: Set<String> {
        [kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXDisclosureTriangleRole, kAXMenuItemRole]
    }

    /// The roles whose press opens a menu window the panel service owns, which
    /// nothing in the seat follows: a click on them refuses, `select` uses them.
    package static var menuOpeningRoles: Set<String> {
        [kAXPopUpButtonRole, kAXMenuButtonRole]
    }

    /// The action a file entry offers to be opened, which the SDK names no
    /// constant for.
    package static var openAction: String { "AXOpen" }

    /// The roles a click leaves a caret or a selection in.
    package static var textRoles: Set<String> {
        [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]
    }

    /// The containers a grid of items is selected through, by their selected children.
    package static var itemListRoles: Set<String> {
        [kAXListRole, "AXCollection"]
    }

    let path   : (CGPoint, ResolvedInputEndpoint) -> Result<[Node], RemoteContentActuationRefusal>
    let role   : (Node) -> String?
    let actions: (Node) -> [String]
    let value  : (Node) -> String?
    let perform: (Node, String) -> AXError
    let write  : (Node, Write) -> AXError

    /// The selection of a list of items: whether it can be written, what it holds, and the write.
    let selectionIsSettable: (Node) -> Bool
    let selectedChildren   : (Node) -> [Node]?
    let selectChildren     : (Node, [Node]) -> AXError

    /// An element's own `AXSelected`, nil when it does not answer.
    let isSelected: (Node) -> Bool?

    /// The element above, and the default button a window or a panel names.
    let parent       : (Node) -> Node?
    let defaultButton: (Node) -> Node?

    package init(
        path   : @escaping (CGPoint, ResolvedInputEndpoint) -> Result<[Node], RemoteContentActuationRefusal>,
        role   : @escaping (Node) -> String?,
        actions: @escaping (Node) -> [String],
        value  : @escaping (Node) -> String?,
        perform: @escaping (Node, String) -> AXError,
        write  : @escaping (Node, Write) -> AXError,
        selectionIsSettable: @escaping (Node) -> Bool = { _ in false },
        selectedChildren   : @escaping (Node) -> [Node]? = { _ in nil },
        selectChildren     : @escaping (Node, [Node]) -> AXError = { _, _ in .attributeUnsupported },
        isSelected         : @escaping (Node) -> Bool? = { _ in nil },
        parent             : @escaping (Node) -> Node? = { _ in nil },
        defaultButton      : @escaping (Node) -> Node? = { _ in nil }
    ) {
        self.path    = path
        self.role    = role
        self.actions = actions
        self.value   = value
        self.perform = perform
        self.write   = write
        self.selectionIsSettable = selectionIsSettable
        self.selectedChildren    = selectedChildren
        self.selectChildren      = selectChildren
        self.isSelected          = isSelected
        self.parent              = parent
        self.defaultButton       = defaultButton
    }

    /// Acts on `command` at the element under its point, and does nothing when
    /// it refuses.
    ///
    /// Inside a row, measured as a file list's name field, its text and its
    /// icon, a left click selects the row and two open the innermost element
    /// offering AXOpen, the row last; only a control drawn in the row is pressed.
    /// Outside one, a click presses a control or leaves a caret at the end of a
    /// field, and three select the field's whole value. A popup or a menu button
    /// refuses. A right click shows the nearest element's menu.
    func actuate(
        _ command: InputCommand,
        endpoint : ResolvedInputEndpoint
    ) -> Result<RemoteContentActuation, RemoteContentActuationRefusal> {

        guard case .click(let location, let button, let count) = command else {
            return .failure(.gestureUnmeasured)
        }
        let nodes: [Node]
        switch path(location.screenPoint, endpoint) {
            case .success(let found): nodes = found
            case .failure(let refusal): return .failure(refusal)
        }
        guard !nodes.isEmpty else { return .failure(.noElementAtPoint) }
        let roles = nodes.map { role($0) ?? kAXUnknownRole }

        if button == .right {
            guard count == 1, let menu = nodes.first(where: { actions($0).contains(kAXShowMenuAction) })
            else { return .failure(.unsupportedRole(roles[0])) }
            return press(menu, kAXShowMenuAction)
        }
        // Column view's selection was never measured; list view's rows were.
        if roles.contains(kAXBrowserRole) { return .failure(.columnView) }
        // A row bounds what the click reaches: the row, or a control drawn in it.
        let row     = roles.firstIndex(of: kAXRowRole)
        let reached = 0..<(row.map { $0 + 1 } ?? roles.count)
        let control = reached.first {
            Self.pressedRoles.contains(roles[$0]) || Self.menuOpeningRoles.contains(roles[$0])
        }
        if let control, Self.menuOpeningRoles.contains(roles[control]) {
            return .failure(.opensMenu(roles[control]))
        }
        if let row {
            switch count {
                case 1:
                    if let control { return press(nodes[control], kAXPressAction) }
                    let code = write(nodes[row], .selected)
                    guard code == .success else {
                        return .failure(.actionRefused(action: kAXSelectedAttribute, code: code.rawValue))
                    }
                    // In an ordinary window a click also focuses the row's list, which a key such as
                    // Finder's / then reaches; its answer is reported, never retried.
                    let list = endpoint.relation == .logicalSurface
                        ? nodes[(row + 1)...].first { Self.rowContainerRoles.contains(role($0) ?? "") }
                        : nil
                    let focus = list.map {
                        write($0, .focused) == .success ? ", its list focused" : ", its list not focused"
                    }
                    return .success(RemoteContentActuation(
                        action   : kAXSelectedAttribute + (focus ?? ""),
                        role     : kAXRowRole,
                        textField: nil
                    ))
                case 2:
                    guard let opener = nodes[...row].first(where: { actions($0).contains(Self.openAction) })
                    else { return .failure(.unsupportedRole(kAXRowRole)) }
                    return press(opener, Self.openAction)
                default:
                    return .failure(.unsupportedRole(kAXRowRole))
            }
        }
        let mapped = Self.pressedRoles.union(Self.textRoles)
        // An item of a grid, outside any row or control, is selected through its list.
        if control == nil, let list = nodes.indices.first(where: {
            Self.itemListRoles.contains(roles[$0]) && selectionIsSettable(nodes[$0])
        }), !roles[..<list].contains(where: mapped.contains) {
            return item(in: nodes, list: list, roles: roles, count: count)
        }
        guard let index = roles.firstIndex(where: mapped.contains) else {
            return .failure(.unsupportedRole(roles[0]))
        }
        switch count {
            case 1 where Self.pressedRoles.contains(roles[index]):
                return press(nodes[index], kAXPressAction)
            case 1 where Self.textRoles.contains(roles[index]):
                return select(in: nodes[index], role: roles[index], wholeValue: false)
            case 3... where Self.textRoles.contains(roles[index]):
                return select(in: nodes[index], role: roles[index], wholeValue: true)
            default:
                return .failure(.unsupportedRole(roles[index]))
        }
    }

    /// Selects the item under the point through the list's selected children, and on a double click
    /// presses the default button, or opens the item where none is named.
    ///
    /// Measured on 06/10/2026 in an open panel's icon view: only `AXSelectedChildren` on the outer
    /// list, holding the item group, selected the file; writing the group's or the image's
    /// `AXSelected`, the inner list's selected children or the image in the outer list answered 0
    /// and changed nothing. So each candidate, the list's nearest descendant first, is written and
    /// read back, and only a verified selection counts. AXOpen on the image completed the panel but
    /// activated the host, which is why the default button comes first.
    private func item(
        in nodes: [Node],
        list    : Int,
        roles   : [String],
        count   : Int
    ) -> Result<RemoteContentActuation, RemoteContentActuationRefusal> {
        guard count <= 2 else { return .failure(.unsupportedRole(roles[0])) }
        let candidates = (0..<list).reversed().filter { !Self.itemListRoles.contains(roles[$0]) }
        // A hit already selected proves nothing: only a change read back does.
        let wasSelected = isSelected(nodes[0]) == true
        guard let chosen = candidates.first(where: { index in
            selectChildren(nodes[list], [nodes[index]]) == .success
                && (selectedChildren(nodes[list]) == [nodes[index]] || !wasSelected && isSelected(nodes[0]) == true)
        }) else { return .failure(.selectionNotVerified(roles[0])) }
        let selected = RemoteContentActuation(
            action   : kAXSelectedChildrenAttribute,
            role     : roles[chosen],
            textField: nil
        )
        guard count == 2 else { return .success(selected) }

        var above = nodes[list...].map { $0 }
        if let top = nodes.last, let surface = parent(top) { above.append(surface) }
        if let button = above.lazy.compactMap(defaultButton).first {
            return press(button, kAXPressAction)
        }
        guard let opener = nodes[..<list].first(where: { actions($0).contains(Self.openAction) }) else {
            return .failure(.unsupportedRole(roles[0]))
        }
        return press(opener, Self.openAction)
    }

    /// Performs one action. A panel's default button closes the panel before
    /// answering, -25204, so that answer is a delivery, verified by the panel
    /// disappearing, as any Receipt is verified by what follows it.
    private func press(
        _ node  : Node,
        _ action: String
    ) -> Result<RemoteContentActuation, RemoteContentActuationRefusal> {
        let code = perform(node, action)
        guard code == .success || code == .cannotComplete else {
            return .failure(.actionRefused(action: action, code: code.rawValue))
        }
        return .success(RemoteContentActuation(action: action, role: role(node) ?? kAXUnknownRole, textField: nil))
    }

    /// Leaves a caret at the end of the field's value, or selects all of it.
    /// A value that cannot be read refuses, since its length is the caret.
    private func select(
        in node   : Node,
        role      : String,
        wholeValue: Bool
    ) -> Result<RemoteContentActuation, RemoteContentActuationRefusal> {
        guard let current = value(node) else { return .failure(.unreadable) }
        let length = current.utf16.count
        let code   = write(node, .selectedTextRange(location: wholeValue ? 0 : length, length: wholeValue ? length : 0))
        guard code == .success else {
            return .failure(.actionRefused(action: kAXSelectedTextRangeAttribute, code: code.rawValue))
        }
        let field = RemoteContentActuation.TextField(
            isAnswering: { self.role(node) != nil },
            replaceSelection: { text in
                let code = self.write(node, .selectedText(text))
                guard code == .success else {
                    return .failure(.actionRefused(action: kAXSelectedTextAttribute, code: code.rawValue))
                }
                return .success(self.value(node))
            }
        )
        return .success(RemoteContentActuation(
            action   : kAXSelectedTextRangeAttribute,
            role     : role,
            textField: field
        ))
    }
}

// MARK: - The shipping actuator

extension RemoteContentActuator where Node == AXUIElement {

    /// How long one action or write may wait for its answer. Longer than a
    /// read's, because the host forwards it to the panel service.
    private static var effectTimeout: Float { 0.5 }

    /// The actuator the seat runs, over the assigned application's own
    /// accessibility tree: the remote elements answer there, with true screen
    /// coordinates.
    package static func accessibility(assignedProcessID: Int32) -> RemoteContentActuator<AXUIElement> {
        let resolver = DialogEndpointResolver<AXUIElement>.accessibility(assignedProcessID: assignedProcessID)
        func attribute<Value>(_ node: AXUIElement, _ name: String) -> Value? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
            return value as? Value
        }
        return RemoteContentActuator(
            path   : { point, endpoint in
                endpoint.relation == .remoteContent
                    ? resolver.remoteContentPath(at: point, of: endpoint)
                    : resolver.ownContentPath(at: point, of: endpoint)
            },
            role   : { attribute($0, kAXRoleAttribute) },
            actions: { node in
                var names: CFArray?
                guard AXUIElementCopyActionNames(node, &names) == .success else { return [] }
                return names as? [String] ?? []
            },
            value  : { attribute($0, kAXValueAttribute) },
            perform: { node, action in
                AXUIElementSetMessagingTimeout(node, effectTimeout)
                return AXUIElementPerformAction(node, action as CFString)
            },
            write  : { node, write in
                AXUIElementSetMessagingTimeout(node, effectTimeout)
                switch write {
                    case .selected:
                        return AXUIElementSetAttributeValue(node, kAXSelectedAttribute as CFString, kCFBooleanTrue)
                    case .focused:
                        return AXUIElementSetAttributeValue(node, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                    case .selectedTextRange(let location, let length):
                        var range = CFRange(location: location, length: length)
                        guard let value = AXValueCreate(.cfRange, &range) else { return .failure }
                        return AXUIElementSetAttributeValue(node, kAXSelectedTextRangeAttribute as CFString, value)
                    case .selectedText(let text):
                        return AXUIElementSetAttributeValue(
                            node,
                            kAXSelectedTextAttribute as CFString,
                            text as CFString
                        )
                }
            },
            selectionIsSettable: { node in
                var settable = DarwinBoolean(false)
                return AXUIElementIsAttributeSettable(node, kAXSelectedChildrenAttribute as CFString, &settable)
                    == .success && settable.boolValue
            },
            selectedChildren: { attribute($0, kAXSelectedChildrenAttribute) },
            selectChildren  : { list, children in
                AXUIElementSetMessagingTimeout(list, effectTimeout)
                return AXUIElementSetAttributeValue(
                    list,
                    kAXSelectedChildrenAttribute as CFString,
                    children as CFArray
                )
            },
            isSelected      : { (attribute($0, kAXSelectedAttribute) as NSNumber?)?.boolValue },
            parent          : { node in
                guard let parent: AXUIElement = attribute(node, kAXParentAttribute) else { return nil }
                AXUIElementSetMessagingTimeout(parent, BoundedAccessibilityRead.fastTimeout)
                return parent
            },
            defaultButton   : { attribute($0, kAXDefaultButtonAttribute) }
        )
    }
}
