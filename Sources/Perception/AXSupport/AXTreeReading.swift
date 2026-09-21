import Foundation
import CoreGraphics

/// Abstraction over an Accessibility tree, so the path capture/replay/cousin-search/opaque-detection
/// algorithms (``AXPathOps``) can be unit-tested against a fake in-memory tree with no live AX / TCC.
///
/// The live conformance (`LiveAXReader`) wraps `AXUIElement` + the ApplicationServices C-API; tests
/// supply a fake tree of plain objects.
public protocol AXTreeReading {
    associatedtype Element

    func role(_ e: Element) -> String?
    func title(_ e: Element) -> String?
    func descriptionText(_ e: Element) -> String?
    func identifier(_ e: Element) -> String?
    func enabled(_ e: Element) -> Bool?
    func actions(_ e: Element) -> [String]
    func frame(_ e: Element) -> CGRect?
    func children(_ e: Element) -> [Element]
    func parent(_ e: Element) -> Element?
    func isEqual(_ a: Element, _ b: Element) -> Bool
}
