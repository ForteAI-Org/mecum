import CoreGraphics
@testable import AXSupport

/// An in-memory AX-like node for testing ``AXPathOps`` without any live AX / TCC.
final class FakeNode {
    var role: String?
    var title: String?
    var descriptionText: String?
    var identifier: String?
    var enabled: Bool?
    var actions: [String]
    var frame: CGRect?
    weak var parent: FakeNode?
    private(set) var children: [FakeNode] = []

    init(
        role: String?,
        title: String? = nil,
        descriptionText: String? = nil,
        identifier: String? = nil,
        enabled: Bool? = nil,
        actions: [String] = [],
        frame: CGRect? = nil
    ) {
        self.role = role
        self.title = title
        self.descriptionText = descriptionText
        self.identifier = identifier
        self.enabled = enabled
        self.actions = actions
        self.frame = frame
    }

    @discardableResult
    func adding(_ kids: FakeNode...) -> FakeNode {
        for k in kids { k.parent = self; children.append(k) }
        return self
    }

    func setChildren(_ kids: [FakeNode]) {
        for k in kids { k.parent = self }
        children = kids
    }
}

/// `AXTreeReading` over the fake node graph.
struct FakeReader: AXTreeReading {
    func role(_ e: FakeNode) -> String? { e.role }
    func title(_ e: FakeNode) -> String? { e.title }
    func descriptionText(_ e: FakeNode) -> String? { e.descriptionText }
    func identifier(_ e: FakeNode) -> String? { e.identifier }
    func enabled(_ e: FakeNode) -> Bool? { e.enabled }
    func actions(_ e: FakeNode) -> [String] { e.actions }
    func frame(_ e: FakeNode) -> CGRect? { e.frame }
    func children(_ e: FakeNode) -> [FakeNode] { e.children }
    func parent(_ e: FakeNode) -> FakeNode? { e.parent }
    func isEqual(_ a: FakeNode, _ b: FakeNode) -> Bool { a === b }
}
