import CoreGraphics
@testable import InteractionListener
import Testing

@Suite
struct InteractionRoutingTests {
    private let point = CGPoint(x: 745, y: 315)
    private let overlay = InteractionWindow(processID: 30072, number: 7541, title: nil, layer: 24,
                                            frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
    private let finder = InteractionWindow(processID: 631, number: 6988, title: "Fixture", layer: 0,
                                           frame: CGRect(x: 487, y: 169, width: 920, height: 436))

    @Test func unknownRoutingDoesNotGuessFromStackingOrder() {
        #expect(InteractionWindowReader.window(at: point, in: [overlay, finder]) == nil)
    }

    @Test func inconsistentRecipientOrLocationStaysUnresolved() {
        #expect(InteractionWindowReader.window(at: point, in: [overlay, finder],
                                               recipientWindowNumber: finder.number, targetProcessID: overlay.processID) == nil)
        #expect(InteractionWindowReader.window(at: .zero, in: [overlay, finder],
                                               recipientWindowNumber: finder.number, targetProcessID: finder.processID) == nil)
    }

    @Test func ambientRoutingRequiresTheSamePointerLocationAndLiveRecipient() {
        let route = PointerRoute(point: point, recipientWindowNumber: finder.number, targetProcessID: finder.processID)
        #expect(route.window(at: point, in: [overlay, finder]) == finder)
        #expect(route.window(at: CGPoint(x: point.x + 10, y: point.y), in: [overlay, finder]) == nil)
        #expect(route.window(at: point, in: [overlay]) == nil)
    }

    @Test func finderClickPassesThroughOverlayToItsActualRecipient() {
        let hit = InteractionWindowReader.window(at: point, in: [overlay, finder],
                                                 recipientWindowNumber: 6988, targetProcessID: 631)
        #expect(hit == finder)
    }

    @Test func processRoutingAlsoExcludesAnotherApplicationsOverlay() {
        let hit = InteractionWindowReader.window(at: point, in: [overlay, finder], targetProcessID: 631)
        #expect(hit == finder)
    }

    @Test func vanishedRecipientDoesNotTurnIntoAClickOnTheOverlay() {
        let hit = InteractionWindowReader.window(at: point, in: [overlay],
                                                 recipientWindowNumber: 6988, targetProcessID: 631)
        #expect(hit == nil)
    }

    @Test func aRealOverlayRecipientRemainsAnOverlayClick() {
        let hit = InteractionWindowReader.window(at: point, in: [overlay, finder],
                                                 recipientWindowNumber: 7541, targetProcessID: 30072)
        #expect(hit == overlay)
    }

    @Test func desktopRecipientSurvivesSystemDesktopSurfacesInFront() {
        let frame = CGRect(x: -272, y: -1080, width: 1920, height: 1080)
        let system = InteractionWindow(processID: 601, number: 7578, title: nil, layer: -2147483603, frame: frame)
        let desktop = InteractionWindow(processID: 631, number: 6876, title: nil, layer: -2147483603, frame: frame)
        let hit = InteractionWindowReader.window(at: CGPoint(x: 100, y: -500), in: [system, desktop],
                                                 recipientWindowNumber: 6876, targetProcessID: 631)
        #expect(hit == desktop)
    }
}
