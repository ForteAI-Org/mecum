//
//  FakeTree.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

import CoreGraphics
import PerceptionCore

/// FakeNode is an in-memory accessibility node for the capture fixtures: the producer walks it as
/// it walks the live tree, so every fixture passes through the real harvest, merge and pipeline.
final class FakeNode: @unchecked Sendable {

    var role: String?
    var subrole: String?
    var title: String?
    var descriptionText: String?
    var value: String?
    var numericValue: Int?
    var isEnabled: Bool?
    var frame: CGRect?
    private(set) var children: [FakeNode] = []

    init(
        _ role         : String,
        subrole        : String? = nil,
        title          : String? = nil,
        descriptionText: String? = nil,
        value          : String? = nil,
        numericValue   : Int? = nil,
        frame          : CGRect? = nil,
        isEnabled      : Bool? = true
    ) {
        self.role            = role
        self.subrole         = subrole
        self.title           = title
        self.descriptionText = descriptionText
        self.value           = value
        self.numericValue    = numericValue
        self.frame           = frame
        self.isEnabled       = isEnabled
    }

    @discardableResult
    func adding(_ nodes: [FakeNode]) -> FakeNode {
        children.append(contentsOf: nodes)
        return self
    }

    @discardableResult
    func adding(_ nodes: FakeNode...) -> FakeNode { adding(nodes) }
}

/// FakeReader reads the fake node graph. The nodes are built once and never mutated while a walk
/// runs, which is the invariant the unchecked conformance of `FakeNode` stands on.
struct FakeReader: AccessibilityTreeReading {

    func role(_ node: FakeNode) -> String? { node.role }
    func subrole(_ node: FakeNode) -> String? { node.subrole }
    func title(_ node: FakeNode) -> String? { node.title }
    func descriptionText(_ node: FakeNode) -> String? { node.descriptionText }
    func identifier(_ node: FakeNode) -> String? { nil }
    func value(_ node: FakeNode) -> String? { node.value }
    func numericValue(_ node: FakeNode) -> Int? { node.numericValue }
    func isEnabled(_ node: FakeNode) -> Bool? { node.isEnabled }
    func actions(_ node: FakeNode) -> [String] { [] }
    func frame(_ node: FakeNode) -> CGRect? { node.frame }
    func children(_ node: FakeNode) -> [FakeNode] { node.children }
}
