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

    @Test func snapshotLookupMatchesTheDirectReaderOnEveryRoutingCombination() {
        let desktopFrame = CGRect(x: -272, y: -1080, width: 1920, height: 1080)
        let windows = [
            InteractionWindow(processID: 631, number: 8001, title: "Menu", layer: 101,
                              frame: CGRect(x: 700, y: 300, width: 120, height: 200)),
            overlay, finder,
            InteractionWindow(processID: 631, number: 6989, title: "Behind", layer: 0,
                              frame: CGRect(x: 400, y: 100, width: 900, height: 600)),
            InteractionWindow(processID: 601, number: 7578, title: nil, layer: -2147483603, frame: desktopFrame),
            InteractionWindow(processID: 631, number: 6876, title: nil, layer: -2147483603, frame: desktopFrame),
        ]
        let snapshot = AttributionSnapshot(generation: 3, windows: windows)
        let points = [point, .zero, CGPoint(x: 710, y: 310), CGPoint(x: 1300, y: 650), CGPoint(x: 100, y: -500),
                      CGPoint(x: 487, y: 169), CGPoint(x: 1407, y: 605), CGPoint(x: -5000, y: 0)]
        let numbers: [Int?] = [nil, 0, -1, 8001, 7541, 6988, 6989, 7578, 6876, 9999]
        let processes: [Int32?] = [nil, 0, -1, 631, 30072, 601, 4242]
        var checked = 0
        for point in points {
            for number in numbers {
                for process in processes {
                    let direct = InteractionWindowReader.window(at: point, in: windows,
                                                                recipientWindowNumber: number, targetProcessID: process)
                    let snapped = snapshot.window(at: point, recipientWindowNumber: number ?? 0,
                                                  targetProcessID: process ?? 0)
                    #expect(snapped?.number == direct?.number && snapped?.processID == direct?.processID
                                && snapped?.frame == direct?.frame && snapped.map { Int($0.layer) } == direct?.layer,
                            "point \(point) number \(String(describing: number)) pid \(String(describing: process))")
                    checked += 1
                }
            }
        }
        #expect(checked == points.count * numbers.count * processes.count)
    }

    @Test func snapshotStampsTheConfirmedSurfaceAndItsGeneration() {
        let snapshot = AttributionSnapshot(generation: 7, windows: [overlay, finder])
        var record = InputRecord(kind: .click, timestamp: 1, precedingRevision: 0, revision: 1)
        snapshot.attribute(&record, at: point, recipientWindowNumber: finder.number, targetProcessID: finder.processID)
        #expect(record.has(.windowResolved) && !record.has(.staleAttribution))
        #expect(record.attributionGeneration == 7 && record.targetPID == 631 && record.windowNumber == 6988)
        #expect(record.windowX == 487 && record.windowY == 169)
        #expect(record.windowWidth == 920 && record.windowHeight == 436)
    }

    @Test func staleSnapshotRecordsTheRoutedSurfaceUnresolvedInsteadOfTheOverlay() {
        // The routed Finder window is missing from this generation, as a window opened after it would be.
        let snapshot = AttributionSnapshot(generation: 2, windows: [overlay])
        var record = InputRecord(kind: .click, timestamp: 1, precedingRevision: 0, revision: 1)
        snapshot.attribute(&record, at: point, recipientWindowNumber: finder.number, targetProcessID: finder.processID)
        #expect(record.has(.staleAttribution) && !record.has(.windowResolved))
        #expect(record.windowNumber == 6988 && record.targetPID == 631 && record.attributionGeneration == 2)
        #expect(record.windowWidth == 0 && record.windowLayer == 0)
        let event = InteractionEvent(record: record, title: "Fixture")
        #expect(event?.window == nil && event?.processID == 631)

        var unrouted = InputRecord(kind: .click, timestamp: 1, precedingRevision: 0, revision: 1)
        snapshot.attribute(&unrouted, at: point, recipientWindowNumber: 0, targetProcessID: 0)
        #expect(!unrouted.has(.staleAttribution) && !unrouted.has(.windowResolved) && unrouted.targetPID == 0)
    }

    /// A click routed to a popup opened after the last snapshot, which holds only the overlay.
    private func popupClick(windowNumber: UInt32 = 8101, targetPID: Int32 = 631) -> InputRecord {
        let snapshot = AttributionSnapshot(generation: 4, windows: [overlay])
        var record = InputRecord(kind: .click, timestamp: 1, precedingRevision: 0, revision: 1)
        record.x = 745
        record.y = 315
        snapshot.attribute(&record, at: point, recipientWindowNumber: Int(windowNumber), targetProcessID: targetPID)
        return record
    }

    /// The popup's row as CGWindowList reports it at delivery.
    private func popupRow(owner: Int32 = 631, frame: CGRect = CGRect(x: 700, y: 300, width: 200, height: 120),
                          onscreen: Bool = true, alpha: Double = 1) -> [String: Any] {
        [kCGWindowOwnerPID as String: owner, kCGWindowNumber as String: 8101, kCGWindowLayer as String: 101,
         kCGWindowAlpha as String: alpha, kCGWindowBounds as String: frame.dictionaryRepresentation,
         kCGWindowIsOnscreen as String: onscreen, kCGWindowName as String: "New Paths"]
    }

    @Test func staleRecordResolvesTheRoutedWindowFromItsOwnRowAtDelivery() throws {
        let record = popupClick()
        #expect(record.has(.staleAttribution))
        let window = try #require(InteractionWindowReader.lateWindow(for: record, row: popupRow(), excluding: 1))
        #expect(window == InteractionWindow(processID: 631, number: 8101, title: "New Paths", layer: 101,
                                            frame: CGRect(x: 700, y: 300, width: 200, height: 120)))
        let event = InteractionEvent(record: record, title: nil, lateWindow: window)
        #expect(event?.window == window && event?.processID == 631 && event?.sequence == record.sequence)

        // Quartz can route by window alone; any owner of that exact window then qualifies.
        let anyOwner = popupClick(targetPID: 0)
        let owned = InteractionWindowReader.lateWindow(for: anyOwner, row: popupRow(owner: 900), excluding: 1)
        #expect(owned?.processID == 900)
        #expect(InteractionEvent(record: anyOwner, title: nil, lateWindow: owned)?.processID == 900)
    }

    @Test func lateResolutionNeverSubstitutesAnotherSurface() {
        let record = popupClick()
        let reader = InteractionWindowReader.self
        #expect(reader.lateWindow(for: record, row: popupRow(owner: 30072), excluding: 1) == nil, "another process")
        #expect(reader.lateWindow(for: record, row: popupRow(frame: CGRect(x: 0, y: 0, width: 50, height: 50)),
                                  excluding: 1) == nil, "the point is outside the window")
        #expect(reader.lateWindow(for: record, row: popupRow(onscreen: false), excluding: 1) == nil, "off screen")
        #expect(reader.lateWindow(for: record, row: popupRow(alpha: 0), excluding: 1) == nil, "invisible")
        #expect(reader.lateWindow(for: record, row: popupRow(), excluding: 631) == nil, "the listener's own window")
        #expect(reader.lateWindow(for: record, row: nil, excluding: 1) == nil, "closed before delivery")

        // Process-only routing has no window identity to confirm, so no frontmost window is guessed.
        let processOnly = popupClick(windowNumber: 0)
        #expect(processOnly.has(.staleAttribution) && processOnly.windowNumber == 0)
        #expect(reader.lateWindow(for: processOnly, row: popupRow(), excluding: 1) == nil, "no window number")
        let event = InteractionEvent(record: processOnly, title: nil)
        #expect(event?.window == nil && event?.processID == 631)
    }
}
