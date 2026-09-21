//
//  OrdinaryKeyboardContextTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/09/2026.
//

import CoreGraphics
import SeatCore
@testable import SeatSession
import Testing

/// The exceptional keyboard route for applications that positively report no
/// focused control, despite reporting one complete focused window.
///
/// These tests deliberately use only fixture identities. The route is not a
/// host fallback: it is admitted only after every descendant of the focused
/// window agrees with the selected logical surface.
@Suite("Ordinary keyboard contexts without a focused control")
struct OrdinaryKeyboardContextTests {

    private struct Node: Hashable {
        let identifier: Int
    }

    private struct Tree {
        var children: [Int: DialogEndpointResolver<Node>.ChildReading] = [:]
        var windows: [Int: Int] = [:]
        var processes: [Int: Int32] = [:]
    }

    private enum Focus {
        case absent
        case unreadable
        case node(Int)
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

    private static let applicationProcess: Int32 = 401
    private static let hostWindow = 9_101
    private static let otherWindow = 9_102
    private static let surfaceFrame = CGRect(x: 100, y: 100, width: 800, height: 600)

    private var surface: WindowIdentity {
        identity(window: Self.hostWindow, process: Self.applicationProcess, connection: 7_001)
    }

    private var chain: DialogEndpointResolver<Node>.SurfaceChain {
        .init(host: surface, surface: surface, surfaceFrame: Self.surfaceFrame)
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

    private func observation(for identity: WindowIdentity) -> WindowGeometryObservation {
        WindowGeometryObservation(
            window: WindowReference(identity: identity, frame: Self.surfaceFrame),
            scaleFactor: 2,
            version: GeometryObservationVersion(observerGeneration: 0, sequence: 1)
        )!
    }

    private func resolver(
        tree: Tree,
        focusedControl: Focus,
        focusedWindow: Int? = 1,
        clock: Clock = .init(),
        inertLeafFacts: [Int: DialogEndpointResolver<Node>.InertWindowlessLeafFacts] = [:]
    ) -> DialogEndpointResolver<Node> {
        let control: () -> DialogEndpointResolver<Node>.FocusedControlReading = {
            switch focusedControl {
            case .absent:
                return .absent
            case .unreadable:
                return .unreadable
            case .node(let identifier):
                return .node(Node(identifier: identifier))
            }
        }
        return DialogEndpointResolver<Node>(
            nodeAtPoint: { _ in nil },
            focusedNode: { nil },
            children: { tree.children[$0.identifier] ?? .leaf },
            nodeFrame: { _ in nil },
            nodeWindow: { tree.windows[$0.identifier] },
            nodeProcess: { tree.processes[$0.identifier] },
            identity: { window in
                guard window == Self.hostWindow else { return nil }
                return surface
            },
            geometry: { window, _ in
                guard window == Self.hostWindow else { return nil }
                return observation(for: surface)
            },
            now: clock.read,
            focusedControl: control,
            focusedWindow: { focusedWindow.map(Node.init(identifier:)) },
            inertWindowlessLeaf: { node in
                guard let facts = inertLeafFacts[node.identifier] else { return false }
                return DialogEndpointResolver<Node>.inertWindowlessLeaf(facts)
            }
        )
    }

    private var inertWindowlessLeafFacts: DialogEndpointResolver<Node>.InertWindowlessLeafFacts {
        .init(
            role: "AXGroup",
            axWindowWasNoValue: true,
            focused: false,
            focusedIsSettable: false,
            actions: []
        )
    }

    private func sameWindowTree(
        children: [Int: DialogEndpointResolver<Node>.ChildReading] = [
            1: .children([Node(identifier: 2), Node(identifier: 3)]),
            2: .leaf,
            3: .leaf
        ]
    ) -> Tree {
        Tree(
            children: children,
            windows: [
                1: Self.hostWindow,
                2: Self.hostWindow,
                3: Self.hostWindow
            ],
            processes: [
                1: Self.applicationProcess,
                2: Self.applicationProcess,
                3: Self.applicationProcess
            ]
        )
    }

    @Test("an absent focused control and a complete same-window tree attest the ordinary window")
    func absentFocusedControlWithCompleteSameWindowTreeAttestsSurface() throws {
        let endpoint = try resolver(tree: sameWindowTree(), focusedControl: .absent)
            .ordinaryKeyboardContext(within: chain, selectionGeneration: 14)
            .get()

        #expect(endpoint.kind == .keyboardContext)
        #expect(endpoint.identity == surface)
        #expect(endpoint.logicalSurface == surface)
        #expect(endpoint.relation == .logicalSurface)
        #expect(endpoint.evidence == .focusedWindowWithoutFocusedControl)
        #expect(endpoint.accessibilityProcessID == Self.applicationProcess)
        #expect(endpoint.focusedNodeWindowNumber == Self.hostWindow)
    }

    @Test("only an explicit absent control is eligible")
    func onlyExplicitAbsentControlIsEligible() {
        let tree = sameWindowTree()
        for control in [Focus.unreadable, .node(2)] {
            #expect(resolver(tree: tree, focusedControl: control)
                .ordinaryKeyboardContext(within: chain, selectionGeneration: 1)
                == .failure(.subtreeUnreadable(surface: surface)))
        }

        // The backwards-compatible `focusedNode` closure has no typed absence
        // evidence, so omitting the new reading remains a refusal.
        let legacy = DialogEndpointResolver<Node>(
            nodeAtPoint: { _ in nil },
            focusedNode: { nil },
            children: { _ in .leaf },
            nodeFrame: { _ in nil },
            nodeWindow: { _ in Self.hostWindow },
            nodeProcess: { _ in Self.applicationProcess },
            identity: { _ in self.surface },
            geometry: { _, _ in self.observation(for: self.surface) }
        )
        #expect(legacy.ordinaryKeyboardContext(within: chain, selectionGeneration: 1)
            == .failure(.subtreeUnreadable(surface: surface)))
    }

    @Test("a remote child rejects the ordinary route even when the root looks ordinary")
    func remoteChildRejectsOrdinaryRoute() {
        var tree = sameWindowTree()
        tree.windows[3] = Self.otherWindow
        tree.processes[3] = 902

        #expect(resolver(tree: tree, focusedControl: .absent)
            .ordinaryKeyboardContext(within: chain, selectionGeneration: 1)
            == .failure(.subtreeUnreadable(surface: surface)))
    }

    @Test("a complete inert windowless leaf does not turn an ordinary keyboard context into remote content")
    func inertWindowlessLeafMayHaveNoWindowID() throws {
        var tree = sameWindowTree(children: [
            1: .children([Node(identifier: 2), Node(identifier: 4)]),
            2: .leaf,
            4: .children([]),
        ])
        tree.windows[4] = nil
        tree.processes[4] = Self.applicationProcess

        let endpoint = try resolver(
            tree: tree,
            focusedControl: .absent,
            inertLeafFacts: [4: inertWindowlessLeafFacts]
        )
        .ordinaryKeyboardContext(within: chain, selectionGeneration: 1)
        .get()

        #expect(endpoint.identity == surface)
        #expect(endpoint.evidence == .focusedWindowWithoutFocusedControl)
    }

    @Test("only the complete AX evidence classifies a windowless leaf as inert")
    func onlyCompleteInertLeafEvidenceQualifies() {
        #expect(DialogEndpointResolver<Node>.inertWindowlessLeaf(inertWindowlessLeafFacts))

        let invalid: [DialogEndpointResolver<Node>.InertWindowlessLeafFacts] = [
            .init(role: "AXButton", axWindowWasNoValue: true, focused: false,
                  focusedIsSettable: false, actions: []),
            .init(role: nil, axWindowWasNoValue: true, focused: false,
                  focusedIsSettable: false, actions: []),
            .init(role: "AXGroup", axWindowWasNoValue: true, focused: true,
                  focusedIsSettable: false, actions: []),
            .init(role: "AXGroup", axWindowWasNoValue: true, focused: nil,
                  focusedIsSettable: false, actions: []),
            .init(role: "AXGroup", axWindowWasNoValue: true, focused: false,
                  focusedIsSettable: false, actions: ["AXPress"]),
            .init(role: "AXGroup", axWindowWasNoValue: true, focused: false,
                  focusedIsSettable: nil, actions: []),
            .init(role: "AXGroup", axWindowWasNoValue: true, focused: false,
                  focusedIsSettable: true, actions: []),
            .init(role: "AXGroup", axWindowWasNoValue: true, focused: false,
                  focusedIsSettable: false, actions: nil),
            .init(role: "AXGroup", axWindowWasNoValue: false, focused: false,
                  focusedIsSettable: false, actions: []),
        ]
        for facts in invalid {
            #expect(!DialogEndpointResolver<Node>.inertWindowlessLeaf(facts))
        }
    }

    @Test("a foreign leaf remains a refusal unless it is complete and inert")
    func foreignLeafRequiresCompleteInertEvidence() {
        var tree = sameWindowTree(children: [
            1: .children([Node(identifier: 4)]),
            4: .children([]),
        ])
        tree.windows[4] = Self.otherWindow
        tree.processes[4] = Self.applicationProcess

        #expect(resolver(tree: tree, focusedControl: .absent)
            .ordinaryKeyboardContext(within: chain, selectionGeneration: 1)
            == .failure(.subtreeUnreadable(surface: surface)))

        let endpoint = try? resolver(
            tree: tree,
            focusedControl: .absent,
            inertLeafFacts: [4: inertWindowlessLeafFacts]
        )
        .ordinaryKeyboardContext(within: chain, selectionGeneration: 1)
        .get()
        #expect(endpoint?.identity == surface)
    }

    @Test("an inert-looking foreign leaf with descendants or a foreign PID still refuses")
    func nonLeafAndForeignPIDStillRefuse() {
        var nonLeaf = sameWindowTree(children: [
            1: .children([Node(identifier: 4)]),
            4: .children([Node(identifier: 5)]),
            5: .leaf,
        ])
        nonLeaf.windows[4] = nil
        nonLeaf.processes[4] = Self.applicationProcess
        nonLeaf.windows[5] = Self.hostWindow
        nonLeaf.processes[5] = Self.applicationProcess
        #expect(resolver(
            tree: nonLeaf,
            focusedControl: .absent,
            inertLeafFacts: [4: inertWindowlessLeafFacts]
        )
        .ordinaryKeyboardContext(within: chain, selectionGeneration: 1)
        == .failure(.subtreeUnreadable(surface: surface)))

        var foreignPID = sameWindowTree(children: [
            1: .children([Node(identifier: 4)]),
            4: .children([]),
        ])
        foreignPID.windows[4] = nil
        foreignPID.processes[4] = 902
        #expect(resolver(
            tree: foreignPID,
            focusedControl: .absent,
            inertLeafFacts: [4: inertWindowlessLeafFacts]
        )
        .ordinaryKeyboardContext(within: chain, selectionGeneration: 1)
        == .failure(.subtreeUnreadable(surface: surface)))
    }

    @Test("an unreadable child remains input-bearing even when its parent facts look inert")
    func unreadableChildWithInertFactsStillRefuses() {
        var tree = sameWindowTree(children: [
            1: .children([Node(identifier: 4)]),
            4: .unreadable,
        ])
        tree.windows[4] = nil
        tree.processes[4] = Self.applicationProcess

        #expect(resolver(
            tree: tree,
            focusedControl: .absent,
            inertLeafFacts: [4: inertWindowlessLeafFacts]
        )
        .ordinaryKeyboardContext(within: chain, selectionGeneration: 1)
        == .failure(.subtreeUnreadable(surface: surface)))
    }

    @Test("the proof refuses unreadable descendants and incomplete descendant identities")
    func incompleteDescendantsRejectOrdinaryRoute() {
        var unreadable = sameWindowTree()
        unreadable.children[2] = .unreadable
        #expect(resolver(tree: unreadable, focusedControl: .absent)
            .ordinaryKeyboardContext(within: chain, selectionGeneration: 1)
            == .failure(.subtreeUnreadable(surface: surface)))

        var missingWindow = sameWindowTree()
        missingWindow.windows[2] = nil
        #expect(resolver(tree: missingWindow, focusedControl: .absent)
            .ordinaryKeyboardContext(within: chain, selectionGeneration: 1)
            == .failure(.subtreeUnreadable(surface: surface)))

        var wrongProcess = sameWindowTree()
        wrongProcess.processes[2] = 903
        #expect(resolver(tree: wrongProcess, focusedControl: .absent)
            .ordinaryKeyboardContext(within: chain, selectionGeneration: 1)
            == .failure(.subtreeUnreadable(surface: surface)))
    }

    @Test("a different focused window cannot lend its control absence to the selected surface")
    func wrongFocusedWindowRejectsOrdinaryRoute() {
        var tree = sameWindowTree()
        tree.windows[2] = Self.otherWindow
        #expect(resolver(
            tree: tree,
            focusedControl: .absent,
            focusedWindow: 2
        )
        .ordinaryKeyboardContext(within: chain, selectionGeneration: 1)
        == .failure(.subtreeUnreadable(surface: surface)))
    }

    @Test("a tree exceeding the explicit depth or node budget is refused")
    func boundedTreeRejectsDepthAndNodeExhaustion() {
        var depthChildren: [Int: DialogEndpointResolver<Node>.ChildReading] = [:]
        var depthWindows: [Int: Int] = [:]
        var depthProcesses: [Int: Int32] = [:]
        for identifier in 1...66 {
            depthWindows[identifier] = Self.hostWindow
            depthProcesses[identifier] = Self.applicationProcess
            depthChildren[identifier] = identifier == 66
                ? .leaf
                : .children([Node(identifier: identifier + 1)])
        }
        #expect(resolver(
            tree: Tree(children: depthChildren, windows: depthWindows, processes: depthProcesses),
            focusedControl: .absent
        )
        .ordinaryKeyboardContext(within: chain, selectionGeneration: 1)
        == .failure(.subtreeUnreadable(surface: surface)))

        let nodes = (1...1_025).map(Node.init(identifier:))
        let nodeBudget = Tree(
            children: [1: .children(nodes)],
            windows: Dictionary(uniqueKeysWithValues: (1...1_025).map {
                ($0, Self.hostWindow)
            }),
            processes: Dictionary(uniqueKeysWithValues: (1...1_025).map {
                ($0, Self.applicationProcess)
            })
        )
        #expect(resolver(tree: nodeBudget, focusedControl: .absent)
            .ordinaryKeyboardContext(within: chain, selectionGeneration: 1)
            == .failure(.subtreeUnreadable(surface: surface)))
    }

    @Test("a scan that crosses its monotonic budget refuses rather than using a partial tree")
    func treeScanTimeBudgetRejectsPartialProof() {
        let clock = Clock([0, 301_000_000])
        #expect(resolver(
            tree: sameWindowTree(),
            focusedControl: .absent,
            clock: clock
        )
        .ordinaryKeyboardContext(within: chain, selectionGeneration: 1)
        == .failure(.subtreeUnreadable(surface: surface)))
    }
}
