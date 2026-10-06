//
//  SmallAuxiliarySurfaceTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 06/10/2026.
//

import CoreGraphics
import Foundation
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

/// The 66 by 20 point untitled dialog macOS puts up in the driven process
/// moments after a text field takes focus, measured in DaVinci Resolve and in
/// TextEdit, and the document window the seat was working in.
///
/// It arrived after a modal closed, when the document was selected as the only
/// candidate and no recency was ever qualified. The two candidates then had no
/// observed order and every observation asked for an explicit choice, which the
/// worker answered by closing and reopening the session, twice in a minute.
@MainActor
@Suite("A small auxiliary surface beside the document")
struct SmallAuxiliarySurfaceTests {

    static let modalNumber     = 790
    static let newMainNumber   = 791
    static let indicatorNumber = 792

    /// The size measured for the indicator in both applications.
    static let indicatorFrame = CGRect(x: 2100, y: 600, width: 66, height: 20)

    static func seat(
        marker : Int64,
        sensing: FakeSensing
    ) async throws -> (seat: AgentSeat, window: AdoptedWindow, reader: ControlledSurfaceReader) {

        let reader = ControlledSurfaceReader(sensing: sensing)
        let seat   = makeSeat(
            sensing: sensing,
            marker : marker,
            reader : reader,
            source : ControlledObservationSource(sensing: sensing),
            clock  : ControlledContentClock()
        )
        let window = try await seat.adopt(
            FakeGeometry.reference(frame: FakeGeometry.userSeatWindow.frame),
            platform: AppKitPlatform()
        )
        _ = try await observe(seat)
        return (seat, window, reader)
    }

    /// Puts up an application-modal dialog born in the seat, which blocks the
    /// document and so ends the standing choice the adoption made.
    static func openModal(
        _ seat : AgentSeat,
        sensing: FakeSensing,
        reader : ControlledSurfaceReader
    ) async throws -> WindowReference {

        let modal = FakeGeometry.reference(
            frame       : CGRect(x: 2000, y: 400, width: 520, height: 200),
            windowNumber: Self.modalNumber
        )
        sensing.additionalWindows[Self.modalNumber] = modal
        reader.roles[Self.modalNumber]  = .dialog
        reader.modals[Self.modalNumber] = .application
        await seat.ownWindowBornInSeat(modal, level: 8)
        seat.refreshTargetReadings()
        #expect(seat.selectionKit.selected?.surface == modal.identity)
        return modal
    }

    static func closeModal(
        _ modal: WindowReference,
        _ seat : AgentSeat,
        sensing: FakeSensing,
        reader : ControlledSurfaceReader
    ) throws {
        sensing.additionalWindows[Self.modalNumber] = nil
        reader.destroyed = [try #require(modal.identity)]
        seat.refreshTargetReadings()
        reader.destroyed = []
    }

    /// The indicator, born in the seat and held by the follower as it was live.
    ///
    /// The controlled reader writes roles directly, so the indicator's role is
    /// the one the shipped reader claims for the record AX reads for it: a
    /// non-modal dialog at the measured size.
    static func showIndicator(
        _ seat : AgentSeat,
        sensing: FakeSensing,
        reader : ControlledSurfaceReader
    ) async {
        let indicator = FakeGeometry.reference(
            frame       : Self.indicatorFrame,
            windowNumber: Self.indicatorNumber
        )
        sensing.additionalWindows[Self.indicatorNumber] = indicator
        reader.roles[Self.indicatorNumber] = CrossCheckedSurfaceReader.role(
            of    : AccessibilitySurfaceRecord(
                processID   : indicator.processID,
                windowNumber: Self.indicatorNumber,
                role        : .dialog,
                isMinimised : false,
                isModal     : false,
                appIsHidden : false
            ),
            readAs: .dialog,
            frame : Self.indicatorFrame
        )
        await seat.ownWindowBornInSeat(indicator, level: 0)
        seat.refreshTargetReadings()
    }

    @Test("a dialog changed and closed, then the indicator: the document stays observable")
    func theIndicatorAfterADialogClosed() async throws {

        let sensing = FakeSensing()
        let (seat, window, reader) = try await Self.seat(marker: 1_951, sensing: sensing)

        let modal = try await Self.openModal(seat, sensing: sensing, reader: reader)
        try Self.closeModal(modal, seat, sensing: sensing, reader: reader)
        #expect(seat.selectionKit.selected?.surface == window.reference.identity)

        await Self.showIndicator(seat, sensing: sensing, reader: reader)
        #expect(seat.adoptedWindows.map(\.id).contains(Self.indicatorNumber))

        let delivery = try await observe(seat)
        #expect(delivery.reference.recipient == window.reference.identity)
        #expect(seat.currentTarget?.id == window.id)
    }

    @Test("a project created, its manager hidden, then the indicator: the new main window stays observable")
    func theIndicatorAfterTheTargetMovedByDetection() async throws {

        let sensing = FakeSensing()
        let (seat, window, reader) = try await Self.seat(marker: 1_952, sensing: sensing)

        let modal = try await Self.openModal(seat, sensing: sensing, reader: reader)
        // The manager hides itself as the project opens, and the project's own window is born.
        reader.visibilities[window.id] = .hiddenEstablished
        try Self.closeModal(modal, seat, sensing: sensing, reader: reader)
        let newMain = FakeGeometry.reference(
            frame       : CGRect(x: 1600, y: 100, width: 1345, height: 949),
            windowNumber: Self.newMainNumber
        )
        sensing.additionalWindows[Self.newMainNumber] = newMain
        await seat.ownWindowBornInSeat(newMain, level: 0)
        seat.refreshTargetReadings()
        #expect(seat.currentTarget?.id == Self.newMainNumber, "the seat followed the application")

        await Self.showIndicator(seat, sensing: sensing, reader: reader)

        let delivery = try await observe(seat)
        #expect(delivery.reference.recipient == newMain.identity)
        #expect(seat.currentTarget?.id == Self.newMainNumber)
    }

    @Test("two documents with no observed order still ask for an explicit choice")
    func twoDocumentsStillAsk() async throws {

        let sensing = FakeSensing()
        let (seat, _, reader) = try await Self.seat(marker: 1_953, sensing: sensing)

        let modal = try await Self.openModal(seat, sensing: sensing, reader: reader)
        try Self.closeModal(modal, seat, sensing: sensing, reader: reader)
        let other = FakeGeometry.reference(
            frame       : CGRect(x: 1600, y: 100, width: 800, height: 600),
            windowNumber: Self.newMainNumber
        )
        sensing.additionalWindows[Self.newMainNumber] = other
        await seat.ownWindowBornInSeat(other, level: 0)
        seat.refreshTargetReadings()

        guard case .failure(.suspended(let causes)) = await seat.observe() else {
            Issue.record("two documents with no observed order must still be chosen between")
            return
        }
        #expect(causes.contains {
            if case .explicitSelectionRequired = $0 { true } else { false }
        })
    }

    @Test("the reader names the indicator a decoration, and a dialog of a real size a dialog")
    func theReaderNamesTheIndicatorADecoration() throws {

        func identity(_ number: Int) -> WindowIdentity {
            WindowIdentity(
                process          : ProcessIdentity(processID: 77, serialNumberHigh: 0, serialNumberLow: 9),
                windowNumber     : number,
                ownerConnectionID: 5
            )
        }
        func surface(_ number: Int, _ frame: CGRect) -> WindowSurface {
            WindowSurface(
                reference: WindowReference(identity: identity(number), frame: frame),
                level    : 0,
                isVisible: true
            )
        }
        func dialog(_ number: Int, modal: Bool) -> AccessibilitySurfaceRecord {
            AccessibilitySurfaceRecord(
                processID   : 77,
                windowNumber: number,
                role        : .dialog,
                isMinimised : false,
                isModal     : modal,
                appIsHidden : false
            )
        }

        let snapshot = CrossCheckedSurfaceReader.assemble(
            windowServer : [
                surface(11, CGRect(x: 0, y: 0, width: 1345, height: 949)),
                surface(12, Self.indicatorFrame),
                surface(13, CGRect(x: 100, y: 100, width: 501, height: 225)),
                surface(14, Self.indicatorFrame)
            ],
            accessibility: [
                AccessibilitySurfaceRecord(
                    processID   : 77,
                    windowNumber: 11,
                    role        : .document,
                    isMinimised : false,
                    isModal     : false,
                    appIsHidden : false
                ),
                dialog(12, modal: false),
                dialog(13, modal: false),
                dialog(14, modal: true)
            ]
        )
        let roles = Dictionary(
            uniqueKeysWithValues: snapshot.claims.roles.map { ($0.surface.windowNumber, $0.role) }
        )
        #expect(roles[11] == .document)
        #expect(roles[12] == .decoration, "a non-modal dialog of the indicator's size is no target")
        #expect(roles[13] == .dialog)
        #expect(roles[14] == .dialog, "a modal answers for itself whatever its size")
    }
}
