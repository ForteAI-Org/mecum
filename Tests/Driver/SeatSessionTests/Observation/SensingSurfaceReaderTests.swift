//
//  SensingSurfaceReaderTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/09/2026.
//

import CoreGraphics
import SeatCore
@testable import SeatSession
import Testing
import WindowPlacement

/// A scripted native cross-check, so the window server fallback branch can be
/// driven offline. It records what every pass was asked to retain, which is the
/// one fact the fallback has to contribute.
private final class ScriptedNativePass: @unchecked Sendable {

    /// True while the native cross-check is unreadable, which is what sends the
    /// reader to the on-screen fallback.
    var fails = true

    /// The window numbers the window server still lists, and the ones the
    /// application still carries in its own accessibility scope.
    var serverWindowNumbers: [Int] = []
    var scopeWindowNumbers : [Int] = []

    private(set) var retainedPerPass: [[Int]] = []

    func snapshot(
        ownedBy processIDs: Set<Int32>,
        retaining retained: Set<WindowIdentity>,
        windowNumbers     : AccessibilityWindowNumberCache
    ) -> Result<AssignedSurfaceSnapshot, CrossCheckedSurfaceReadFailure> {

        retainedPerPass.append(retained.map(\.windowNumber).sorted())
        guard !fails else { return .failure(.windowServerUnavailable) }
        return .success(CrossCheckedSurfaceReader.assemble(
            windowServer : serverWindowNumbers.map { surface($0) },
            accessibility: scopeWindowNumbers.map {
                AccessibilitySurfaceRecord(
                    processID   : 77,
                    windowNumber: $0,
                    role        : .document,
                    isMinimised : false,
                    isModal     : false,
                    isMain      : true,
                    isFocused   : true,
                    appIsHidden : false
                )
            },
            retaining    : retained,
            observedAtNanoseconds: 0
        ))
    }
}

private func identity(_ number: Int) -> WindowIdentity {
    WindowIdentity(
        process: ProcessIdentity(
            processID       : 77,
            serialNumberHigh: 3,
            serialNumberLow : 9
        ),
        windowNumber     : number,
        ownerConnectionID: 101
    )
}

private func surface(_ number: Int) -> WindowSurface {
    WindowSurface(
        reference: WindowReference(
            identity: identity(number),
            frame   : CGRect(x: number, y: 20, width: 640, height: 480)
        ),
        level    : 0,
        isVisible: true
    )
}

@Suite("The shipped surface reader's window server fallback")
struct SensingSurfaceReaderTests {

    // MARK: The auxiliary window adopted while the cross-check was unreadable

    /// Slack puts up a 66 by 20 point auxiliary window and takes it away again
    /// seconds later. When the pass that adopted it came from the fallback, the
    /// identity used to reach no retained set at all: the next native pass never
    /// named it to the window server, no answer could prove it destroyed, and
    /// containment waited on a raw absence until the surface deadline expired.
    @Test("a surface adopted from the fallback is named by the next pass and confirmed destroyed")
    func fallbackRowIsRetainedForTheNextNamedProbe() {
        let native  = ScriptedNativePass()
        let sensing = FakeSensing()
        sensing.surfaces = [surface(41), surface(66)]
        let reader  = SensingSurfaceReader(sensing: sensing, nativePass: native.snapshot)

        let assignment = SeatAssignmentKit()
        let bounds     = CGRect(x: 0, y: 0, width: 2_000, height: 1_000)
        _ = assignment.handOver(
            instance   : identity(41).process,
            attestation: .windowServerAttested,
            at         : 0
        )

        let adopting = reader.snapshot(ownedBy: [77])
        #expect(!adopting.inventory.completeness.isQualified)
        _ = assignment.ingest(adopting.inventory, within: bounds, at: 0)
        #expect(assignment.inventory.members.map(\.windowNumber) == [41, 66])

        // The cross-check reads again a moment later, and 66 is gone. It can
        // only be told so for an identity this pass names.
        native.fails = false
        native.serverWindowNumbers = [41]
        native.scopeWindowNumbers  = [41]
        let closing = reader.snapshot(ownedBy: [77])

        #expect(native.retainedPerPass == [[], [41, 66]],
                "the fallback pass has to leave its rows behind for the pass after it")
        #expect(closing.destroyedByWindowServer == [identity(66)])
        for gone in closing.destroyedByWindowServer {
            assignment.confirmClosure(
                of      : gone.windowNumber,
                evidence: .windowServerConfirmedDestruction
            )
        }
        let settled = assignment.ingest(closing.inventory, within: bounds, at: 10_000_000)

        #expect(!settled.blocks.contains(.surfaceAbsent(windowNumber: 66)))
        #expect(settled.blocks.isEmpty)
        #expect(settled.containmentIsVerified)
    }

    /// A fallback that could not be read at all supplies no identity, so there
    /// is nothing to retain and the next pass asks for nothing.
    @Test("an unreadable fallback retains nothing")
    func unreadableFallbackRetainsNothing() {
        let native  = ScriptedNativePass()
        let sensing = FakeSensing()
        sensing.surfaces = nil
        let reader  = SensingSurfaceReader(sensing: sensing, nativePass: native.snapshot)

        _ = reader.snapshot(ownedBy: [77])
        native.fails = false
        _ = reader.snapshot(ownedBy: [77])

        #expect(native.retainedPerPass == [[], []])
    }
}
