//
//  FakeAccessibilityTree.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics
import PerceptionCore

/// FakeNode is an in-memory accessibility node, so the augmentation walk is decided by tests with no
/// live tree and no privacy grant.
final class FakeNode: @unchecked Sendable {

    var role: String?
    var title: String?
    var descriptionText: String?
    var value: String?
    var numericValue: Int?
    var frame: CGRect?
    private(set) var children: [FakeNode] = []

    init(
        _ role         : String,
        title          : String? = nil,
        descriptionText: String? = nil,
        value          : String? = nil,
        numericValue   : Int? = nil,
        frame          : CGRect? = nil
    ) {
        self.role            = role
        self.title           = title
        self.descriptionText = descriptionText
        self.value           = value
        self.numericValue    = numericValue
        self.frame           = frame
    }

    @discardableResult
    func adding(_ nodes: FakeNode...) -> FakeNode {
        children.append(contentsOf: nodes)
        return self
    }
}

/// FakeReader reads the fake node graph. Test-only: the nodes are built once and never mutated
/// while a walk runs, which is the invariant the unchecked conformance stands on.
struct FakeReader: AccessibilityTreeReading {

    func role(_ node: FakeNode) -> String? { node.role }
    func subrole(_ node: FakeNode) -> String? { nil }
    func title(_ node: FakeNode) -> String? { node.title }
    func descriptionText(_ node: FakeNode) -> String? { node.descriptionText }
    func identifier(_ node: FakeNode) -> String? { nil }
    func value(_ node: FakeNode) -> String? { node.value }
    func numericValue(_ node: FakeNode) -> Int? { node.numericValue }
    func isEnabled(_ node: FakeNode) -> Bool? { true }
    func actions(_ node: FakeNode) -> [String] { [] }
    func frame(_ node: FakeNode) -> CGRect? { node.frame }
    func children(_ node: FakeNode) -> [FakeNode] { node.children }
}
