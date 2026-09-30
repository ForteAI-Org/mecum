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

    private var chain: DialogEndpointResolver<Node>.SurfaceChain {
        .init(host: panel, surface: sheet, surfaceFrame: Self.sheetFrame)
    }

    private func observation(_ identity: WindowIdentity) -> WindowGeometryObservation {
        WindowGeometryObservation(
            window: WindowReference(identity: identity, frame: Self.sheetFrame),
            scaleFactor: 2,
            version: GeometryObservationVersion(observerGeneration: 0, sequence: 1)
        )!
    }

    private func resolver(
        windows: [Int: Int] = [1: sheetWindow, 4: remoteWindow, 5: remoteWindow],
        focusedWindow: Node? = sheet
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
            focusedNode: { Self.field },
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
                default: nil
                }
            },
            geometry: { window, _ in
                switch window {
                case Self.sheetWindow: observation(sheet)
                case Self.remoteWindow: observation(remote)
                case Self.otherWindow: observation(other)
                default: nil
                }
            },
            now: { 1_000_000 },
            focusedWindow: { focusedWindow }
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
}
