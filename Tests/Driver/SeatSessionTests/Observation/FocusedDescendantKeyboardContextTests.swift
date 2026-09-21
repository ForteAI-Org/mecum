//
//  FocusedDescendantKeyboardContextTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/09/2026.
//

import CoreGraphics
import SeatCore
@testable import SeatSession
import Testing

/// Keyboard routing for a modal sheet where AX reports no focused control but
/// does report focus on its concrete descendants. The descendant window is
/// never selected merely because it is a remote child: a complete bounded scan
/// must nominate one WindowServer recipient with positive AX focus evidence.
@Suite("Focused modal descendants without an application focused control")
struct FocusedDescendantKeyboardContextTests {

    private struct Node: Hashable {
        let identifier: Int
    }

    private enum Control {
        case absent
        case unreadable
        case node(Int)
    }

    private struct Tree {
        var children: [Int: DialogEndpointResolver<Node>.ChildReading]
        var windows: [Int: Int]
        var processes: [Int: Int32]
        var focus: [Int: DialogEndpointResolver<Node>.DescendantFocusReading]
    }

    private final class Clock {
        var readings: [UInt64]
        private var index = 0

        init(_ readings: [UInt64] = [1_000_000]) {
            self.readings = readings
        }

        func read() -> UInt64 {
            defer { index += 1 }
            return readings[min(index, readings.count - 1)]
        }
    }

    private static let hostPID: Int32 = 401
    private static let helperPID: Int32 = 902
    private static let hostWindow = 9_101
    private static let sheetWindow = 9_102
    private static let remoteWindow = 9_103
    private static let otherWindow = 9_104
    private static let sheetFrame = CGRect(x: 100, y: 100, width: 800, height: 600)
    private static let remoteFrame = CGRect(x: 120, y: 120, width: 760, height: 560)

    private var host: WindowIdentity {
        identity(window: Self.hostWindow, process: Self.hostPID, connection: 7_001)
    }

    private var sheet: WindowIdentity {
        identity(window: Self.sheetWindow, process: Self.hostPID, connection: 7_001)
    }

    private var remote: WindowIdentity {
        identity(window: Self.remoteWindow, process: Self.helperPID, connection: 8_001)
    }

    private var other: WindowIdentity {
        identity(window: Self.otherWindow, process: Self.helperPID, connection: 8_002)
    }

    private var chain: DialogEndpointResolver<Node>.SurfaceChain {
        .init(host: host, surface: sheet, surfaceFrame: Self.sheetFrame)
    }

    private func identity(window: Int, process: Int32, connection: Int32) -> WindowIdentity {
        WindowIdentity(
            process: ProcessIdentity(
                processID: process,
                serialNumberHigh: 1,
                serialNumberLow: 2
            ),
            windowNumber: window,
            ownerConnectionID: connection
        )
    }

    private func observation(
        identity: WindowIdentity,
        frame: CGRect
    ) -> WindowGeometryObservation {
        WindowGeometryObservation(
            window: WindowReference(identity: identity, frame: frame),
            scaleFactor: 2,
            version: GeometryObservationVersion(observerGeneration: 0, sequence: 1)
        )!
    }

    private func modalTree() -> Tree {
        Tree(
            children: [
                1: .children([Node(identifier: 2), Node(identifier: 3)]),
                2: .children([Node(identifier: 4)]),
                3: .leaf,
                4: .leaf,
            ],
            windows: [
                1: Self.sheetWindow,
                2: Self.sheetWindow,
                3: Self.remoteWindow,
                4: Self.remoteWindow,
            ],
            processes: [
                1: Self.hostPID,
                2: Self.helperPID,
                3: Self.hostPID,
                4: Self.helperPID,
            ],
            focus: [
                1: .notApplicable,
                2: .unfocused,
                3: .focused,
                4: .focused,
            ]
        )
    }

    private func resolver(
        tree: Tree,
        focusedControl: Control = .absent,
        focusedWindows: [Int?] = [1],
        clock: Clock = .init()
    ) -> DialogEndpointResolver<Node> {
        let control: () -> DialogEndpointResolver<Node>.FocusedControlReading = {
            switch focusedControl {
            case .absent: return .absent
            case .unreadable: return .unreadable
            case .node(let identifier): return .node(Node(identifier: identifier))
            }
        }
        var focusedWindowIndex = 0
        return DialogEndpointResolver<Node>(
            nodeAtPoint: { _ in nil },
            focusedNode: { nil },
            children: { tree.children[$0.identifier] ?? .leaf },
            nodeFrame: { _ in nil },
            nodeWindow: { tree.windows[$0.identifier] },
            nodeProcess: { tree.processes[$0.identifier] },
            identity: { window in
                switch window {
                case Self.hostWindow: return host
                case Self.sheetWindow: return sheet
                case Self.remoteWindow: return remote
                case Self.otherWindow: return other
                default: return nil
                }
            },
            geometry: { window, _ in
                switch window {
                case Self.sheetWindow: return observation(identity: sheet, frame: Self.sheetFrame)
                case Self.remoteWindow: return observation(identity: remote, frame: Self.remoteFrame)
                case Self.otherWindow: return observation(identity: other, frame: Self.remoteFrame)
                default: return nil
                }
            },
            now: clock.read,
            focusedControl: control,
            focusedWindow: {
                defer { focusedWindowIndex += 1 }
                let window = focusedWindows[min(focusedWindowIndex, focusedWindows.count - 1)]
                return window.map(Node.init(identifier:))
            },
            descendantFocus: { tree.focus[$0.identifier] ?? .notApplicable }
        )
    }

    @Test("one focused remote window in a complete sheet subtree attests keyboard delivery")
    func focusedRemoteDescendantsAttestTheRemoteRecipient() throws {
        let endpoint = try resolver(tree: modalTree())
            .focusedDescendantKeyboardContext(within: chain, selectionGeneration: 14)
            .get()

        #expect(endpoint.kind == .keyboardContext)
        #expect(endpoint.evidence == .focusedSurfaceDescendant)
        #expect(endpoint.relation == .remoteContent)
        #expect(endpoint.identity == remote)
        #expect(endpoint.logicalSurface == sheet)
        #expect(endpoint.focusedNodeWindowNumber == Self.remoteWindow)
    }

    @Test("modal descendant routing requires an explicit absent focused control")
    func onlyAnExplicitAbsentControlMayUseTheModalDescendantRoute() {
        let tree = modalTree()
        for control in [Control.unreadable, .node(3)] {
            #expect(resolver(tree: tree, focusedControl: control)
                .focusedDescendantKeyboardContext(within: chain, selectionGeneration: 1)
                == .failure(.subtreeUnreadable(surface: sheet)))
        }
    }

    @Test("a focused candidate must name one complete WindowServer window and AX process")
    func focusedCandidateNeedsOneAttestableWindowAndProcess() {
        var missingWindow = modalTree()
        missingWindow.windows[3] = nil
        #expect(resolver(tree: missingWindow)
            .focusedDescendantKeyboardContext(within: chain, selectionGeneration: 1)
            == .failure(.subtreeUnreadable(surface: sheet)))

        var missingProcess = modalTree()
        missingProcess.processes[3] = nil
        #expect(resolver(tree: missingProcess)
            .focusedDescendantKeyboardContext(within: chain, selectionGeneration: 1)
            == .failure(.subtreeUnreadable(surface: sheet)))

        var twoRecipients = modalTree()
        twoRecipients.windows[4] = Self.otherWindow
        #expect(resolver(tree: twoRecipients)
            .focusedDescendantKeyboardContext(within: chain, selectionGeneration: 1)
            == .failure(.subtreeUnreadable(surface: sheet)))
    }

    @Test("unreadable focus or children never becomes a missing focus fallback")
    func incompleteSubtreeOrFocusRefusesTheModalRoute() {
        var unreadableFocus = modalTree()
        unreadableFocus.focus[4] = .unreadable
        #expect(resolver(tree: unreadableFocus)
            .focusedDescendantKeyboardContext(within: chain, selectionGeneration: 1)
            == .failure(.subtreeUnreadable(surface: sheet)))

        var unreadableChildren = modalTree()
        unreadableChildren.children[2] = .unreadable
        #expect(resolver(tree: unreadableChildren)
            .focusedDescendantKeyboardContext(within: chain, selectionGeneration: 1)
            == .failure(.subtreeUnreadable(surface: sheet)))
    }

    @Test("a changed focused sheet or no positive descendant focus refuses delivery")
    func changedFocusedWindowOrNoFocusedDescendantRefusesTheModalRoute() {
        var noCandidate = modalTree()
        noCandidate.focus[3] = .unfocused
        noCandidate.focus[4] = .notApplicable
        #expect(resolver(tree: noCandidate)
            .focusedDescendantKeyboardContext(within: chain, selectionGeneration: 1)
            == .failure(.subtreeUnreadable(surface: sheet)))

        var movedWindow = modalTree()
        movedWindow.windows[8] = Self.otherWindow
        movedWindow.processes[8] = Self.hostPID
        #expect(resolver(tree: movedWindow, focusedWindows: [1, 8])
            .focusedDescendantKeyboardContext(within: chain, selectionGeneration: 1)
            == .failure(.subtreeUnreadable(surface: sheet)))
    }

    @Test("the scan refuses depth, node, and monotonic time budget exhaustion")
    func boundedScanRefusesIncompleteProof() {
        var depthChildren: [Int: DialogEndpointResolver<Node>.ChildReading] = [:]
        var depthWindows: [Int: Int] = [:]
        var depthProcesses: [Int: Int32] = [:]
        var depthFocus: [Int: DialogEndpointResolver<Node>.DescendantFocusReading] = [:]
        for identifier in 1...66 {
            depthWindows[identifier] = identifier == 1 ? Self.sheetWindow : Self.remoteWindow
            depthProcesses[identifier] = Self.hostPID
            depthFocus[identifier] = identifier == 66 ? .focused : .notApplicable
            depthChildren[identifier] = identifier == 66
                ? .leaf
                : .children([Node(identifier: identifier + 1)])
        }
        #expect(resolver(tree: .init(
            children: depthChildren,
            windows: depthWindows,
            processes: depthProcesses,
            focus: depthFocus
        ))
        .focusedDescendantKeyboardContext(within: chain, selectionGeneration: 1)
        == .failure(.subtreeUnreadable(surface: sheet)))

        let nodes = (2...1_026).map(Node.init(identifier:))
        let nodeBudget = Tree(
            children: [1: .children(nodes)],
            windows: Dictionary(uniqueKeysWithValues: ([1] + Array(2...1_026)).map {
                ($0, $0 == 1 ? Self.sheetWindow : Self.remoteWindow)
            }),
            processes: Dictionary(uniqueKeysWithValues: ([1] + Array(2...1_026)).map {
                ($0, Self.hostPID)
            }),
            focus: [1: .notApplicable]
        )
        #expect(resolver(tree: nodeBudget)
            .focusedDescendantKeyboardContext(within: chain, selectionGeneration: 1)
            == .failure(.subtreeUnreadable(surface: sheet)))

        #expect(resolver(tree: modalTree(), clock: .init([0, 301_000_000]))
            .focusedDescendantKeyboardContext(within: chain, selectionGeneration: 1)
            == .failure(.subtreeUnreadable(surface: sheet)))
    }
}
