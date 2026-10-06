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

    /// The views a row belongs to: their selected rows select it, and in an ordinary window a
    /// pointer click gives them the focus.
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

    /// The selection a container holds under one attribute, `AXSelectedChildren` of a list of items
    /// or `AXSelectedRows` of an outline or a table: whether it can be written, what it holds, and
    /// the write.
    let selectionIsSettable: (Node, String) -> Bool
    let selection          : (Node, String) -> [Node]?
    let writeSelection     : (Node, String, [Node]) -> AXError

    /// An element's own `AXSelected`, nil when it does not answer.
    let isSelected: (Node) -> Bool?

    /// The element above, the elements below, and the default button a window or a panel names.
    let parent       : (Node) -> Node?
    let children     : (Node) -> [Node]
    let defaultButton: (Node) -> Node?

    package init(
        path   : @escaping (CGPoint, ResolvedInputEndpoint) -> Result<[Node], RemoteContentActuationRefusal>,
        role   : @escaping (Node) -> String?,
        actions: @escaping (Node) -> [String],
        value  : @escaping (Node) -> String?,
        perform: @escaping (Node, String) -> AXError,
        write  : @escaping (Node, Write) -> AXError,
        selectionIsSettable: @escaping (Node, String) -> Bool = { _, _ in false },
        selection          : @escaping (Node, String) -> [Node]? = { _, _ in nil },
        writeSelection     : @escaping (Node, String, [Node]) -> AXError = { _, _, _ in .attributeUnsupported },
        isSelected         : @escaping (Node) -> Bool? = { _ in nil },
        parent             : @escaping (Node) -> Node? = { _ in nil },
        children           : @escaping (Node) -> [Node] = { _ in [] },
        defaultButton      : @escaping (Node) -> Node? = { _ in nil }
    ) {
        self.path    = path
        self.role    = role
        self.actions = actions
        self.value   = value
        self.perform = perform
        self.write   = write
        self.selectionIsSettable = selectionIsSettable
        self.selection           = selection
        self.writeSelection      = writeSelection
        self.isSelected          = isSelected
        self.parent              = parent
        self.children            = children
        self.defaultButton       = defaultButton
    }

    /// Acts on `command` at the element under its point, and does nothing when
    /// it refuses.
    ///
    /// Inside a row, measured as a file list's name field, its text and its
    /// icon, a left click selects the row and two select it and open it through
    /// the element offering AXOpen; only a control drawn in the row is pressed.
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
            if count == 1, let control { return press(nodes[control], kAXPressAction) }
            guard count <= 2 else { return .failure(.unsupportedRole(kAXRowRole)) }
            var selected: String
            switch selectRow(at: row, of: nodes) {
                case .success(let attribute): selected = attribute
                case .failure(let refusal): return .failure(refusal)
            }
            // In an ordinary window a click also focuses the row's list, which a key such as
            // Finder's / then reaches; its answer is reported, never retried.
            if endpoint.relation == .logicalSurface,
               let list = nodes[(row + 1)...].first(where: { Self.rowContainerRoles.contains(role($0) ?? "") }) {
                selected += write(list, .focused) == .success ? ", its list focused" : ", its list not focused"
            }
            guard count == 2 else {
                return .success(RemoteContentActuation(action: selected, role: kAXRowRole, textField: nil))
            }
            return open(row: nodes[row], under: nodes[...row], selected: selected)
        }
        let mapped = Self.pressedRoles.union(Self.textRoles)
        // An item of a grid, outside any row or control, is selected through its list.
        if control == nil, let list = nodes.indices.first(where: {
            Self.itemListRoles.contains(roles[$0]) && selectionIsSettable(nodes[$0], kAXSelectedChildrenAttribute)
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
            writeSelection(nodes[list], kAXSelectedChildrenAttribute, [nodes[index]]) == .success
                && (selection(nodes[list], kAXSelectedChildrenAttribute) == [nodes[index]]
                    || !wasSelected && isSelected(nodes[0]) == true)
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

    /// Selects the row at `row` of the path and answers the attribute that did it, only once a
    /// selection is read back.
    ///
    /// Measured on 06/10/2026 on Finder's sidebar, Finder in the background: `AXSelected` on the row
    /// answered 0 and selected it without navigating, while `[row]` written to the sidebar outline's
    /// `AXSelectedRows` navigated, two of two. So the nearest outline or table above the row whose
    /// selected rows are settable is written first, and the row's own `AXSelected`, which navigated
    /// in a file panel's sidebar three of three, is the fallback, read back on the row or the list.
    private func selectRow(
        at row  : Int,
        of nodes: [Node]
    ) -> Result<String, RemoteContentActuationRefusal> {
        let target = nodes[row]
        let list   = nodes[(row + 1)...].first {
            Self.rowContainerRoles.contains(role($0) ?? "") && selectionIsSettable($0, kAXSelectedRowsAttribute)
        }
        func listHoldsRow() -> Bool { list.map { selection($0, kAXSelectedRowsAttribute) == [target] } ?? false }
        if let list, writeSelection(list, kAXSelectedRowsAttribute, [target]) == .success, listHoldsRow() {
            return .success(kAXSelectedRowsAttribute)
        }
        let code = write(target, .selected)
        guard code == .success else {
            return .failure(.actionRefused(action: kAXSelectedAttribute, code: code.rawValue))
        }
        guard isSelected(target) == true || listHoldsRow() else { return .failure(.selectionNotVerified(kAXRowRole)) }
        return .success(kAXSelectedAttribute)
    }

    /// Opens what a double click on a selected row opens: AXOpen on the innermost element of the
    /// path offering it, the row last, else on the nearest of the row's descendants offering it,
    /// three levels down at most. Finder's file list offers it on the name field, wherever in the
    /// row the click landed; its sidebar rows offer only AXShowDefaultUI and AXShowAlternateUI, and
    /// navigate on the selection alone. A miss or a refused AXOpen keeps the selection it follows.
    private func open(
        row     : Node,
        under path: ArraySlice<Node>,
        selected: String
    ) -> Result<RemoteContentActuation, RemoteContentActuationRefusal> {
        func opens(_ node: Node) -> Bool { actions(node).contains(Self.openAction) }
        var opener = path.first(where: opens)
        var level  = children(row)
        for _ in 0..<3 where opener == nil && !level.isEmpty {
            opener = level.first(where: opens)
            level  = Array(level.flatMap(children).prefix(64))
        }
        guard let opener else { return .failure(.selectedNotOpened(code: nil)) }
        let code = perform(opener, Self.openAction)
        guard code == .success || code == .cannotComplete else {
            return .failure(.selectedNotOpened(code: code.rawValue))
        }
        return .success(RemoteContentActuation(
            action   : selected + ", then " + Self.openAction,
            role     : role(opener) ?? kAXUnknownRole,
            textField: nil
        ))
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
            selectionIsSettable: { node, name in
                var settable = DarwinBoolean(false)
                return AXUIElementIsAttributeSettable(node, name as CFString, &settable) == .success
                    && settable.boolValue
            },
            selection     : { attribute($0, $1) },
            writeSelection: { container, name, nodes in
                AXUIElementSetMessagingTimeout(container, effectTimeout)
                return AXUIElementSetAttributeValue(container, name as CFString, nodes as CFArray)
            },
            isSelected      : { (attribute($0, kAXSelectedAttribute) as NSNumber?)?.boolValue },
            parent          : { node in
                guard let parent: AXUIElement = attribute(node, kAXParentAttribute) else { return nil }
                AXUIElementSetMessagingTimeout(parent, BoundedAccessibilityRead.fastTimeout)
                return parent
            },
            children        : { node in
                let children: [AXUIElement] = attribute(node, kAXChildrenAttribute) ?? []
                children.forEach { AXUIElementSetMessagingTimeout($0, BoundedAccessibilityRead.fastTimeout) }
                return children
            },
            defaultButton   : { attribute($0, kAXDefaultButtonAttribute) }
        )
    }
}
