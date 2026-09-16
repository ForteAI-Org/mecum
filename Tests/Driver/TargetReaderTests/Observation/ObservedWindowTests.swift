//
//  ObservedWindowTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/09/2026.
//

import ApplicationServices
import CoreGraphics
import Foundation
import Testing

@testable import TargetReader

/// What a reading has to be for a caller to be able to keep it: value types
/// only, no accessibility handle inside, and enough shape to rebuild the
/// hierarchy without asking the target anything again.
@Suite("The shape of a window reading")
struct ObservedWindowTests {

    private static func node(
        _ nodeID: Int,
        parent  : Int?,
        depth   : Int = 0,
        role    : String = "AXGroup",
        value   : String = "",
        frame   : CGRect? = nil
    ) -> AXElementNode {
        AXElementNode(
            nodeID      : nodeID,
            parentNodeID: parent,
            depth       : depth,
            role        : role,
            value       : value,
            frame       : frame
        )
    }

    private static func snapshot(_ tree: [AXElementNode]) -> ObservedWindow {
        ObservedWindow(
            processID          : 501,
            applicationName    : "target",
            windowTitle        : "window",
            windowNumber       : 4242,
            windowFrame        : CGRect(x: 100, y: 200, width: 820, height: 720),
            windowOrder        : 0,
            applicationIsActive: false,
            windowIsFocused    : false,
            axTree             : tree,
            axTreeWasTruncated : false,
            signature          : 7
        )
    }

    @Test("a screen point becomes the window local point the driver needs")
    func windowLocalPoint() {
        let reading = Self.snapshot([])
        let local   = reading.pointInWindowFromTop(CGPoint(x: 150, y: 260))

        #expect(local == CGPoint(x: 50, y: 60))
    }

    @Test("the flat tree rebuilds its own hierarchy from parentNodeID alone")
    func hierarchyRebuilds() {
        let reading = Self.snapshot([
            Self.node(0, parent: nil, role: "AXWindow"),
            Self.node(1, parent: 0,   depth: 1, role: "AXButton"),
            Self.node(2, parent: 0,   depth: 1, role: "AXGroup"),
            Self.node(3, parent: 2,   depth: 2, role: "AXStaticText", value: "leaf"),
        ])

        let children = Dictionary(grouping: reading.axTree, by: \.parentNodeID)
        #expect(children[nil]?.map(\.nodeID) == [0])
        #expect(children[0]?.map(\.nodeID)   == [1, 2])
        #expect(children[2]?.map(\.nodeID)   == [3])

        var ancestors: [Int] = []
        var parent = reading.axTree[3].parentNodeID
        while let nodeID = parent {
            ancestors.append(nodeID)
            parent = reading.axTree.first { $0.nodeID == nodeID }?.parentNodeID
        }
        #expect(ancestors == [2, 0])
    }

    @Test("a role prints without its AX prefix and a plain one is untouched")
    func readableRole() {
        #expect(Self.node(0, parent: nil, role: "AXTextField").readableRole == "TextField")
        #expect(Self.node(0, parent: nil, role: "web area").readableRole    == "web area")
    }

    @Test("nothing in a reading holds an accessibility handle")
    func noAccessibilityHandleSurvivesTheRead() {
        let reading = Self.snapshot([
            Self.node(0, parent: nil, role: "AXWindow", frame: CGRect(x: 1, y: 2, width: 3, height: 4)),
            AXElementNode(
                nodeID        : 1,
                parentNodeID  : 0,
                depth         : 1,
                role          : "AXTextArea",
                value         : "text",
                selectedRange : NSRange(location: 0, length: 4),
                textStartPoint: CGPoint(x: 5, y: 6),
                textEndPoint  : CGPoint(x: 7, y: 8)
            ),
        ])

        // "Lightweight value types" is exactly this: a caller can keep a whole
        // reading without keeping the target's accessibility objects alive, so
        // a handle smuggled into a field would be the defect.
        #expect(Self.accessibilityHandlePaths(in: reading).isEmpty)
    }

    @Test("a reading crosses an isolation boundary unchanged")
    func readingIsSendable() async {
        let reading = Self.snapshot([Self.node(0, parent: nil, role: "AXWindow")])
        let carried = await Task.detached { reading.signature + reading.axTree.count }.value

        #expect(carried == 8)
    }

    /// Every field path whose value is an `AXUIElement`, an `AXObserver` or an
    /// `AXValue`, walked with `Mirror` so a field added later is covered too.
    private static func accessibilityHandlePaths(in subject: Any, path: String = "") -> [String] {
        let handleTypeIDs = [
            AXUIElementGetTypeID(), AXObserverGetTypeID(), AXValueGetTypeID(),
        ]
        if let reference = subject as AnyObject?, CFGetTypeID(reference) != 0,
           handleTypeIDs.contains(CFGetTypeID(reference)) {
            return [path.isEmpty ? "<root>" : path]
        }
        let mirror = Mirror(reflecting: subject)
        guard !mirror.children.isEmpty else { return [] }
        return mirror.children.flatMap { child in
            accessibilityHandlePaths(
                in  : child.value,
                path: path + "." + (child.label ?? "?")
            )
        }
    }
}
