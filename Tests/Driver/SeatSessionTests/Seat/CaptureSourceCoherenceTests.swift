//
//  CaptureSourceCoherenceTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 19/09/2026.
//

import CoreGraphics
import Foundation
import SeatCapture
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

/// Which surface one observation is aimed at, and whether everything the
/// delivered sample says about itself describes that one surface: the capture
/// source, the buffer, the content rectangle inside it, the scale, the screen
/// rectangle it represents and the generation it was taken under.
///
/// The oracles here are independent of the transform under test. A landmark is
/// placed at a screen point first, its pixel is computed from the buffer's own
/// scale, and the transform is then asked to give the screen point back; the
/// coherence of a delivery is asserted against the window server reading the
/// fakes answer, not against another value the same delivery carries.
///
/// The Window IDs are the fakes' own. The live campaign's numbers are evidence
/// of what happened on one machine and are never written into a test.
@MainActor
@Suite("The capture source and the reading it is published with")
struct CaptureSourceCoherenceTests {

    static let sheetWindowNumber   = 781
    static let dialogWindowNumber  = 782
    static let unheldWindowNumber  = 783

    struct Stack {
        let seat  : AgentSeat
        let reader: ControlledSurfaceReader
        let source: ControlledObservationSource
        let host  : AdoptedWindow
        let sheet : AdoptedWindow
    }

    /// A seat holding a host window and the sheet drawn inside it, with the
    /// modal relation attested in both directions the seat reads it from.
    static func hosted(marker: Int64) async throws -> Stack {

        let sensing = FakeSensing()
        let reader  = ControlledSurfaceReader(sensing: sensing)
        let source  = ControlledObservationSource(sensing: sensing)
        let seat    = makeSeat(
            sensing: sensing,
            marker : marker,
            reader : reader,
            source : source
        )
        let host = try await seat.adopt(
            FakeGeometry.reference(frame: FakeGeometry.userSeatWindow.frame),
            platform: AppKitPlatform()
        )
        let sheet = try await adopt(Self.sheetWindowNumber, into: seat, sensing: sensing)

        reader.roles[sheet.id]  = .dialog
        reader.modals[sheet.id] = .window(try #require(host.reference.identity))
        seat.refreshTargetReadings()
        seat.refreshTargetReadings()

        return Stack(seat: seat, reader: reader, source: source, host: host, sheet: sheet)
    }

    static func adopt(
        _ windowNumber: Int,
        into seat     : AgentSeat,
        sensing       : FakeSensing
    ) async throws -> AdoptedWindow {

        let offset    = CGFloat(windowNumber - FakeGeometry.windowNumber) * 60
        let reference = FakeGeometry.reference(
            frame       : FakeGeometry.adoptedWindow.frame.offsetBy(dx: offset, dy: offset),
            windowNumber: windowNumber
        )
        sensing.additionalWindows[windowNumber] = reference
        return try await seat.adopt(reference, platform: AppKitPlatform())
    }

    // MARK: One surface, one reading

    @Test("the pixels of a hosted panel are the qualified host's, in one coherent reading")
    func theSourceIsTheQualifiedHost() async throws {
        let stack     = try await Self.hosted(marker: 1_906)
        let hostID    = try #require(stack.host.reference.identity)
        let sheetID   = try #require(stack.sheet.reference.identity)
        let delivery  = try await observe(stack.seat)
        let geometry  = delivery.frame.geometry

        // The source identity is the host, while the pixels are an explicit
        // host-and-sheet crop. A sheet-only capture would be the black band.
        #expect(delivery.frame.source == .window(hostID))
        #expect(geometry.source == .window(hostID))
        #expect(!stack.source.requested.contains(sheetID),
                "the sheet is never handed to the capture")
        let request = try #require(stack.source.requestedRegions.last)
        #expect(request.host == hostID)
        #expect(request.children == [sheetID])

        // And the surface the consumer operates is still named, which is what
        // sends a Command to the panel rather than to the window under it.
        #expect(delivery.reference.surface == hostID)
        #expect(delivery.reference.role == .hostedSheet(sheet: sheetID))

        // The oracle is the window server reading the seat itself takes, not
        // another field of the same delivery.
        let reading = try #require(stack.seat.sensing.windowGeometry(of: hostID.windowNumber))
        let sheetReading = try #require(stack.seat.sensing.windowGeometry(of: sheetID.windowNumber))
        #expect(geometry.screenRect == reading.frame.union(sheetReading.frame),
                "the frame represents the complete attested family crop")
        #expect(geometry.sourceWindowFrame == reading.frame)
        #expect(delivery.geometry.window.frame == reading.frame,
                "window-local coordinates retain the host frame")
        #expect(delivery.geometry.window.identity == hostID)
        #expect(delivery.geometry.scaleFactor == geometry.scaleFactor)
        #expect(delivery.reference.observedFrame == reading.frame)
        #expect(delivery.reference.geometryVersion == geometry.version,
                "the generation on the reference is the sample's own")
        #expect(geometry.capturesFullWindow)
        #expect(geometry.contentPixelSize == geometry.pixelSize,
                "the whole configured union is content, so no host-sized padding is reported")
    }

    @Test("a dialog nested in a panel keeps the outermost host as the source")
    func aNestedDialogKeepsTheOutermostHost() async throws {
        let stack    = try await Self.hosted(marker: 1_907)
        let sensing  = try #require(stack.seat.sensing as? FakeSensing)
        let hostID   = try #require(stack.host.reference.identity)
        let sheetID  = try #require(stack.sheet.reference.identity)

        let dialog   = try await Self.adopt(Self.dialogWindowNumber, into: stack.seat, sensing: sensing)
        let dialogID = try #require(dialog.reference.identity)
        stack.reader.roles[dialog.id]  = .dialog
        stack.reader.modals[dialog.id] = .window(sheetID)
        stack.seat.refreshTargetReadings()
        stack.seat.refreshTargetReadings()

        let delivery = try await observe(stack.seat)

        #expect(delivery.frame.source == .window(hostID),
                "one step up would aim the capture at the panel, which is a proxy too")
        #expect(delivery.reference.role == .hostedSheet(sheet: dialogID))
        guard case .attestedWindowRegion(let capturedHost, let children, _, _, _) = delivery.captureTarget
        else {
            Issue.record("the nested preview did not receive the exact attested family target")
            return
        }
        #expect(capturedHost == hostID)
        #expect(children == [dialogID, sheetID],
                "the preview must not reconstruct a leaf-only family")
        #expect(!stack.source.requested.contains(sheetID))
        #expect(!stack.source.requested.contains(dialogID))
    }

    // MARK: No recognised host

    @Test("a panel whose host the seat does not hold is diagnosed, never captured")
    func anUnrecognisedHostIsRefusedAfterOneMoreReading() async throws {
        let sensing = FakeSensing()
        let reader  = ControlledSurfaceReader(sensing: sensing)
        let source  = ControlledObservationSource(sensing: sensing)
        let seat    = makeSeat(sensing: sensing, marker: 1_908, reader: reader, source: source)

        let panel = try await seat.adopt(
            FakeGeometry.reference(frame: FakeGeometry.userSeatWindow.frame),
            platform: AppKitPlatform()
        )
        let panelID = try #require(panel.reference.identity)

        // The application draws the panel inside a window the seat never took,
        // so its rectangle would be filled with that other window's picture.
        let unheld = FakeGeometry.identity(windowNumber: Self.unheldWindowNumber)
        reader.roles[panelID.windowNumber]  = .dialog
        reader.modals[panelID.windowNumber] = .window(unheld)
        seat.refreshTargetReadings()
        seat.refreshTargetReadings()

        let passesBefore = reader.passes
        let outcome = await seat.observe()

        guard case .failure(let refusal) = outcome else {
            Issue.record("a frame of the panel was published: \(outcome)")
            return
        }
        #expect(refusal == .hostedSurfaceUnresolved(surface: panelID, namedHost: unheld))
        #expect(source.requested.isEmpty, "no risky frame was asked for")
        #expect(reader.passes >= passesBefore + 2,
                "the parentage got one more bounded reading before the refusal")
        #expect(!seat.coherentState.hasCurrentObservation)
    }

    // MARK: The same point in both modes

    /// The buffer the Lab's preview stream is configured with for this
    /// delivery, and the geometry its own frames then carry: the same window at
    /// the same place, sampled at another scale.
    ///
    /// `PreviewStreamController.follow` sizes the preview from
    /// `contentPixelSize` and follows `reference.recipient`, so both modes are
    /// looking at one window through two buffers. That is the whole reason a
    /// point has to land in the same place through either of them.
    static func previewGeometry(
        of still: FrameGeometryObservation,
        scale   : CGFloat
    ) -> FrameGeometryObservation {
        FrameGeometryObservation(
            source              : still.source,
            screenRect          : still.screenRect,
            contentRectInSurface: CGRect(origin: .zero, size: still.screenRect.size),
            scaleFactor         : scale,
            contentScale        : 1,
            pixelSize           : CGSize(
                width : still.screenRect.width  * scale,
                height: still.screenRect.height * scale
            ),
            version             : GeometryObservationVersion(
                observerGeneration: still.version.observerGeneration &+ 1,
                sequence          : 1
            ),
            capturesFullWindow  : still.capturesFullWindow
        )
    }

    @Test("a point on a control is the same screen point through the still and the preview")
    func oneControlIsOneScreenPointInBothModes() async throws {
        let stack    = try await Self.hosted(marker: 1_909)
        let delivery = try await observe(stack.seat)
        let still    = delivery.frame.geometry
        let preview  = Self.previewGeometry(of: still, scale: 2)

        // The landmark is placed in screen coordinates first and its pixel in
        // each buffer computed from that buffer's own scale.
        let control = CGPoint(
            x: still.screenRect.minX + 137,
            y: still.screenRect.minY + 88
        )
        let stillPixel = CGPoint(
            x: (control.x - still.screenRect.minX) * still.scaleFactor,
            y: (control.y - still.screenRect.minY) * still.scaleFactor
        )
        let previewPixel = CGPoint(
            x: (control.x - preview.screenRect.minX) * preview.scaleFactor,
            y: (control.y - preview.screenRect.minY) * preview.scaleFactor
        )
        #expect(stillPixel != previewPixel, "two buffers, so two pixels of the same control")

        let fromStill   = try #require(InputLocation(pixelPoint: stillPixel, observedIn: still))
        let fromPreview = try #require(InputLocation(pixelPoint: previewPixel, observedIn: preview))

        #expect(fromStill.screenPoint == control)
        #expect(fromPreview.screenPoint == control)
        #expect(fromStill.windowPointFromTop == fromPreview.windowPointFromTop)
        #expect(fromStill.observedGeometry?.window.identity
                    == fromPreview.observedGeometry?.window.identity)
    }

    @Test("padding in the buffer is never offered as a place to click")
    func paddingIsNeverContent() async throws {
        let stack    = try await Self.hosted(marker: 1_910)
        let delivery = try await observe(stack.seat)
        let filled   = delivery.frame.geometry

        // The window shrank after the stream was configured, so a smaller
        // picture is written into the same buffer and the rest stays black.
        let content = CGRect(
            origin: .zero,
            size  : CGSize(
                width : filled.screenRect.width  / 2,
                height: filled.screenRect.height / 2
            )
        )
        let padded = FrameGeometryObservation(
            source              : filled.source,
            screenRect          : CGRect(origin: filled.screenRect.origin, size: content.size),
            contentRectInSurface: content,
            scaleFactor         : filled.scaleFactor,
            contentScale        : 1,
            pixelSize           : filled.pixelSize,
            version             : filled.version,
            capturesFullWindow  : true
        )
        #expect(padded.contentPixelSize != padded.pixelSize)
        #expect(padded.contentPixelSize == CGSize(
            width : content.width  * padded.scaleFactor,
            height: content.height * padded.scaleFactor
        ))

        let inPadding = CGPoint(
            x: padded.pixelSize.width - 1,
            y: padded.pixelSize.height - 1
        )
        #expect(InputLocation(pixelPoint: inPadding, observedIn: padded) == nil,
                "a pixel of the black is not a place on the window")
        let inContent = CGPoint(x: 4, y: 4)
        #expect(InputLocation(pixelPoint: inContent, observedIn: padded) != nil)
    }

    // MARK: The full-display capture

    @Test("a full-display capture is a comparison oracle and never an observation")
    func aDisplayCaptureIsNeverAnObservation() async throws {
        let stack    = try await Self.hosted(marker: 1_912)
        let hostID   = try #require(stack.host.reference.identity)
        let delivery = try await observe(stack.seat)
        let window   = delivery.frame.geometry

        // The same rectangle and buffer, taken of the display the window sits
        // on: what a pixel comparison runs against, carrying no window lifetime.
        let asDisplay = FrameGeometryObservation(
            source              : .display(FakeGeometry.mainDisplayID),
            screenRect          : window.screenRect,
            contentRectInSurface: window.contentRectInSurface,
            scaleFactor         : window.scaleFactor,
            contentScale        : window.contentScale,
            pixelSize           : window.pixelSize,
            version             : window.version,
            capturesFullWindow  : true
        )
        #expect(asDisplay.windowObservation == nil)
        #expect(InputLocation(pixelPoint: CGPoint(x: 4, y: 4), observedIn: asDisplay) == nil)

        let frame = SeatFrame(
            surface          : delivery.frame.surface,
            pixelBuffer      : delivery.frame.pixelBuffer,
            presentationTime : delivery.frame.presentationTime,
            receivedAt       : delivery.frame.receivedAt,
            displayGeneration: delivery.frame.displayGeneration,
            source           : .display(FakeGeometry.mainDisplayID),
            geometry         : asDisplay
        )
        let verdict = FrameSampleQualifier(clock: ControlledContentClock())
            .qualify(frame, of: hostID, atNanoseconds: 1)

        guard case .failure(let evidence) = verdict else {
            Issue.record("a display capture qualified as an observation of the window")
            return
        }
        #expect(evidence == .absent(.identityNotAttested))
    }

    // MARK: The generation

    @Test("a new generation retires the coordinates decided on the previous one")
    func aNewGenerationRetiresTheOldCoordinates() async throws {
        let stack      = try await Self.hosted(marker: 1_911)
        let first      = try await observe(stack.seat)
        let sheetID    = try #require(stack.sheet.reference.identity)
        let generation = try #require(stack.seat.selectionKit.selected?.generation)

        #expect(stack.seat.admissionRefusal(
            for      : first.reference,
            expecting: .hostedSheet(sheet: sheetID)
        ) == nil, "the reading it was taken under is still the current one")

        // The panel closes, so the host's own context is a new generation.
        stack.reader.destroyed     = [sheetID]
        stack.reader.windowNumbers = [stack.host.id]
        stack.seat.refreshTargetReadings()

        #expect(stack.seat.selectionKit.selected?.generation != generation)
        #expect(stack.seat.admissionRefusal(
            for      : first.reference,
            expecting: .hostedSheet(sheet: sheetID)
        ) != nil, "coordinates decided under the retired generation are no longer admissible")
        #expect(!stack.seat.coherentState.hasCurrentObservation)
    }
}
