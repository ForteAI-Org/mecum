//
//  RemoteSheetContentTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/09/2026.
//

import CoreGraphics
import SeatCore
@testable import SeatSession
import Testing

/// The Go to Folder sheet of an out of process file panel, as measured on
/// DaVinci Resolve on 27: the sheet answers the host's window, its text field
/// and button answer no Window ID, and the list beside them answers the panel
/// service's window, with the sheet's own frame.
@Suite("An out of process sheet whose controls answer no window")
struct RemoteSheetContentTests {

    private struct Node: Hashable {
        let identifier: Int
    }

    private static let hostPID: Int32 = 401
    private static let servicePID: Int32 = 902
    private static let panelWindow = 9_101
    private static let sheetWindow = 9_102
    private static let remoteWindow = 9_103
    private static let otherWindow = 9_104
    /// The host's own accessory view, and a service window smaller than the sheet.
    private static let accessoryWindow = 9_105
    private static let partialWindow = 9_106
    private static let partialFrame = CGRect(x: 100, y: 200, width: 460, height: 113)
    private static let sheetFrame = CGRect(x: 100, y: 100, width: 460, height: 345)
    private static let fieldFrame = CGRect(x: 115, y: 107, width: 344, height: 22)
    private static let fieldPoint = CGPoint(x: 200, y: 118)

    // 1 sheet, 2 text field, 3 button, 4 scroll area, 5 table.
    private static let sheet = Node(identifier: 1)
    private static let field = Node(identifier: 2)

    private func identity(window: Int, process: Int32, connection: Int32) -> WindowIdentity {
        WindowIdentity(
            process: ProcessIdentity(processID: process, serialNumberHigh: 1, serialNumberLow: 2),
            windowNumber: window,
            ownerConnectionID: connection
        )
    }

    private var panel: WindowIdentity { identity(window: Self.panelWindow, process: Self.hostPID, connection: 7_001) }
    private var sheet: WindowIdentity { identity(window: Self.sheetWindow, process: Self.hostPID, connection: 7_001) }
    private var remote: WindowIdentity { identity(window: Self.remoteWindow, process: Self.servicePID, connection: 8_001) }
    private var other: WindowIdentity { identity(window: Self.otherWindow, process: Self.servicePID, connection: 8_002) }
    private var accessory: WindowIdentity {
        identity(window: Self.accessoryWindow, process: Self.hostPID, connection: 7_001)
    }
    private var partial: WindowIdentity {
        identity(window: Self.partialWindow, process: Self.servicePID, connection: 8_001)
    }

    private var chain: DialogEndpointResolver<Node>.SurfaceChain {
        .init(host: panel, surface: sheet, surfaceFrame: Self.sheetFrame)
    }

    private func observation(
        _ identity: WindowIdentity,
        frame     : CGRect = sheetFrame
    ) -> WindowGeometryObservation {
        WindowGeometryObservation(
            window: WindowReference(identity: identity, frame: frame),
            scaleFactor: 2,
            version: GeometryObservationVersion(observerGeneration: 0, sequence: 1)
        )!
    }

    private func resolver(
        windows: [Int: Int] = [1: sheetWindow, 4: remoteWindow, 5: remoteWindow],
        focusedWindow: Node? = sheet,
        focused: Node? = field,
        focusedControl: (() -> DialogEndpointResolver<Node>.FocusedControlReading)? = nil,
        focusedNodes: Set<Int> = []
    ) -> DialogEndpointResolver<Node> {
        let children: [Int: DialogEndpointResolver<Node>.ChildReading] = [
            1: .children([Node(identifier: 2), Node(identifier: 3), Node(identifier: 4)]),
            4: .children([Node(identifier: 5)]),
        ]
        let frames: [Int: CGRect] = [
            1: Self.sheetFrame,
            2: Self.fieldFrame,
            3: CGRect(x: 511, y: 99, width: 50, height: 38),
            4: CGRect(x: 100, y: 136, width: 460, height: 309),
            5: CGRect(x: 100, y: 136, width: 460, height: 309),
        ]
        return DialogEndpointResolver<Node>(
            nodeAtPoint: { _ in Self.sheet },
            focusedNode: { focused },
            children: { children[$0.identifier] ?? .leaf },
            nodeFrame: { frames[$0.identifier] },
            nodeWindow: { windows[$0.identifier] },
            nodeProcess: { _ in Self.hostPID },
            identity: { window in
                switch window {
                case Self.panelWindow: panel
                case Self.sheetWindow: sheet
                case Self.remoteWindow: remote
                case Self.otherWindow: other
                case Self.accessoryWindow: accessory
                case Self.partialWindow: partial
                default: nil
                }
            },
            geometry: { window, _ in
                switch window {
                case Self.sheetWindow: observation(sheet)
                case Self.remoteWindow: observation(remote)
                case Self.otherWindow: observation(other)
                case Self.accessoryWindow: observation(accessory, frame: Self.partialFrame)
                case Self.partialWindow: observation(partial, frame: Self.partialFrame)
                default: nil
                }
            },
            now: { 1_000_000 },
            focusedControl: focusedControl,
            focusedWindow: { focusedWindow },
            windowNode: { $0 == Self.sheetWindow ? Self.sheet : nil },
            descendantFocus: { focusedNodes.contains($0.identifier) ? .focused : .unfocused }
        )
    }

    @Test("keys for a windowless focused field go to the one remote window its sheet names")
    func keysGoToTheSheetsRemoteContent() throws {
        let endpoint = try resolver().keyboardContext(within: chain, selectionGeneration: 3).get()

        #expect(endpoint.kind == .keyboardContext)
        #expect(endpoint.evidence == .remoteContentOfSurface)
        #expect(endpoint.relation == .remoteContent)
        #expect(endpoint.identity == remote)
        #expect(endpoint.logicalSurface == sheet)
        #expect(endpoint.focusedNodeWindowNumber == Self.remoteWindow)
    }

    @Test("a click on a windowless field goes to the one remote window its sheet names")
    func aClickGoesToTheSheetsRemoteContent() throws {
        let endpoint = try resolver()
            .pointerEndpoint(at: Self.fieldPoint, within: chain, selectionGeneration: 3)
            .get()

        #expect(endpoint.kind == .pointer)
        #expect(endpoint.evidence == .remoteContentOfSurface)
        #expect(endpoint.identity == remote)
    }

    @Test("no remote window, two of them, or a focus outside the sheet still refuse")
    func anythingButOneRemoteWindowRefuses() {
        let refused = Result<ResolvedInputEndpoint, InputEndpointRefusal>.failure(.subtreeUnreadable(surface: sheet))

        let none = resolver(windows: [1: Self.sheetWindow])
        #expect(none.keyboardContext(within: chain, selectionGeneration: 1) == refused)
        #expect(none.pointerEndpoint(at: Self.fieldPoint, within: chain, selectionGeneration: 1) == refused)

        let two = resolver(windows: [1: Self.sheetWindow, 4: Self.remoteWindow, 5: Self.otherWindow])
        #expect(two.keyboardContext(within: chain, selectionGeneration: 1) == refused)
        #expect(two.pointerEndpoint(at: Self.fieldPoint, within: chain, selectionGeneration: 1) == refused)

        let elsewhere = resolver(focusedWindow: Node(identifier: 99))
        #expect(elsewhere.keyboardContext(within: chain, selectionGeneration: 1) == refused)
    }

    // MARK: A modal with no focused control inside it

    @Test("keys for a surface focused on its own window node keep the surface, not its remote window")
    func aFocusOnTheSurfaceWindowKeepsTheSurface() throws {
        // Escape to the panel window closed it; `/` to the service did nothing (30/09/2026).
        let focusedOnItself = resolver(focused: Self.sheet)
        let refused = Result<ResolvedInputEndpoint, InputEndpointRefusal>.failure(.subtreeUnreadable(surface: sheet))
        #expect(focusedOnItself.remoteContentKeyboardContext(within: chain, selectionGeneration: 3) == refused)

        let endpoint = try focusedOnItself.keyboardContext(within: chain, selectionGeneration: 3).get()
        #expect(endpoint.identity == sheet)
        #expect(endpoint.relation == .logicalSurface)
        #expect(endpoint.evidence == .attestedSurfaceItself)
    }

    @Test("keys for a surface whose focus cannot be read go to the one remote window it names")
    func anUnreadableFocusGoesToTheRemoteContent() throws {
        // The application's focused window lags: the surface is found by its Window ID.
        let endpoint = try resolver(focusedWindow: nil, focused: nil)
            .remoteContentKeyboardContext(within: chain, selectionGeneration: 3)
            .get()

        #expect(endpoint.kind == .keyboardContext)
        #expect(endpoint.evidence == .remoteContentOfSurface)
        #expect(endpoint.relation == .remoteContent)
        #expect(endpoint.identity == remote)
        #expect(endpoint.logicalSurface == sheet)
        #expect(endpoint.focusedNodeWindowNumber == Self.remoteWindow)
    }

    @Test("two remote windows, none, a focused control, the window node or an absent focus refuse the route")
    func anythingButAnUnreadableFocusOverOneRemoteWindowRefuses() {
        let refused = Result<ResolvedInputEndpoint, InputEndpointRefusal>.failure(.subtreeUnreadable(surface: sheet))

        let two = resolver(
            windows: [1: Self.sheetWindow, 4: Self.remoteWindow, 5: Self.otherWindow],
            focused: nil
        )
        #expect(two.remoteContentKeyboardContext(within: chain, selectionGeneration: 1) == refused)

        let none = resolver(windows: [1: Self.sheetWindow], focused: nil)
        #expect(none.remoteContentKeyboardContext(within: chain, selectionGeneration: 1) == refused)

        let control = resolver(focused: Self.field)
        #expect(control.remoteContentKeyboardContext(within: chain, selectionGeneration: 1) == refused)

        let window = resolver(focused: Self.sheet)
        #expect(window.remoteContentKeyboardContext(within: chain, selectionGeneration: 1) == refused)

        let absent = resolver(focusedControl: { .absent })
        #expect(absent.remoteContentKeyboardContext(within: chain, selectionGeneration: 1) == refused)
    }

    @Test("a window of the sheet's own process beside the service's content does not count against it")
    func aSameProcessAccessoryIsNotACandidate() throws {
        // Photoshop's Save As panel, 30/09/2026: the service's window with the
        // panel's frame, and an accessory view of Photoshop's own below it.
        let windows = [1: Self.sheetWindow, 3: Self.accessoryWindow, 4: Self.remoteWindow, 5: Self.remoteWindow]
        let endpoint = try resolver(windows: windows, focused: nil)
            .remoteContentKeyboardContext(within: chain, selectionGeneration: 3)
            .get()

        #expect(endpoint.identity == remote)
        #expect(endpoint.evidence == .remoteContentOfSurface)
        #expect(endpoint.focusedNodeWindowNumber == Self.remoteWindow)

        // The other callers keep their rule: two named windows are still two.
        let refused = Result<ResolvedInputEndpoint, InputEndpointRefusal>.failure(.subtreeUnreadable(surface: sheet))
        #expect(resolver(windows: windows).keyboardContext(within: chain, selectionGeneration: 3) == refused)
    }

    @Test("two foreign windows, or one that is not drawn over the whole sheet, still refuse the keys")
    func twoForeignWindowsOrAPartialOneRefuse() {
        let refused = Result<ResolvedInputEndpoint, InputEndpointRefusal>.failure(.subtreeUnreadable(surface: sheet))

        let two = resolver(
            windows: [1: Self.sheetWindow, 3: Self.accessoryWindow, 4: Self.remoteWindow, 5: Self.otherWindow],
            focused: nil
        )
        #expect(two.remoteContentKeyboardContext(within: chain, selectionGeneration: 1) == refused)

        let partial = resolver(
            windows: [1: Self.sheetWindow, 3: Self.accessoryWindow, 4: Self.partialWindow, 5: Self.partialWindow],
            focused: nil
        )
        #expect(partial.remoteContentKeyboardContext(within: chain, selectionGeneration: 1) == refused)
    }

    // MARK: A modal focused on its own window node, with a field clicked inside it

    @Test("a panel whose window node alone is focused keeps the surface as its keys' recipient")
    func onlyTheWindowNodeFocusedKeepsTheSurface() {
        // A fresh Save As panel, 30/09/2026: AXFocused on the window node and nowhere else.
        let refused = Result<ResolvedInputEndpoint, InputEndpointRefusal>.failure(.subtreeUnreadable(surface: sheet))
        let fresh = resolver(windows: [1: Self.sheetWindow, 2: Self.remoteWindow, 4: Self.remoteWindow],
                             focused: Self.sheet, focusedNodes: [1])
        #expect(fresh.focusedContentKeyboardContext(within: chain, selectionGeneration: 3) == refused)
    }

    @Test("a field focused in the foreign content window takes the keys, beside the focused window node")
    func aClickedFieldInTheContentTakesTheKeys() throws {
        // After a click on the name field: AXFocused on the window node and on the field, the
        // field answering the service's window, the application's focus still the window node.
        let endpoint = try resolver(
            windows: [1: Self.sheetWindow, 2: Self.remoteWindow, 3: Self.accessoryWindow, 4: Self.remoteWindow],
            focused: Self.sheet,
            focusedNodes: [1, 2]
        )
        .focusedContentKeyboardContext(within: chain, selectionGeneration: 3)
        .get()

        #expect(endpoint.identity == remote)
        #expect(endpoint.relation == .remoteContent)
        #expect(endpoint.evidence == .focusedSurfaceDescendant)
        #expect(endpoint.focusedNodeWindowNumber == Self.remoteWindow)
    }

    @Test("a focused descendant of the surface's own process, of two windows, or a focus off the window node refuse")
    func anythingButAFocusedDescendantInTheContentRefuses() {
        let refused = Result<ResolvedInputEndpoint, InputEndpointRefusal>.failure(.subtreeUnreadable(surface: sheet))
        let windows = [1: Self.sheetWindow, 2: Self.remoteWindow, 3: Self.accessoryWindow, 4: Self.remoteWindow]

        let accessory = resolver(windows: windows, focused: Self.sheet, focusedNodes: [1, 3])
        #expect(accessory.focusedContentKeyboardContext(within: chain, selectionGeneration: 1) == refused)

        let both = resolver(windows: windows, focused: Self.sheet, focusedNodes: [1, 2, 3])
        #expect(both.focusedContentKeyboardContext(within: chain, selectionGeneration: 1) == refused)

        let unreadable = resolver(windows: windows, focused: nil, focusedNodes: [1, 2])
        #expect(unreadable.focusedContentKeyboardContext(within: chain, selectionGeneration: 1) == refused)

        let twoForeign = resolver(
            windows: [1: Self.sheetWindow, 2: Self.remoteWindow, 4: Self.remoteWindow, 5: Self.otherWindow],
            focused: Self.sheet,
            focusedNodes: [1, 2]
        )
        #expect(twoForeign.focusedContentKeyboardContext(within: chain, selectionGeneration: 1) == refused)
    }
}
