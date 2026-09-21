//
//  WindowInventoryProbeLiveTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import AppKit
import Darwin
import Foundation
import Testing

/// The window inventory probe, on a real machine: two sequential CoreGraphics
/// readings around each phase of two windows this suite creates itself.
///
/// It is preliminary instrumentation for app assignment and nothing else. It
/// qualifies no primitive, promotes no surface to a target, and its report is
/// diagnostic and unqualified. It does not call `WindowServerProbe.surfaces` or
/// any other adapter that performs an SPI attestation: comparing this probe with
/// those adapters is a later step and never a way to make a row pass.
///
/// ## Two switches, both off by default
///
/// `AGENTSEAT_LIVE_TESTS=1` enables the tier and
/// `AGENTSEAT_WINDOW_INVENTORY_PROBE=1` enables this probe in particular. The
/// second exists because consenting to the Live tier is not consenting to a run
/// that opens windows of its own and reads the window list of the whole session.
/// The decision is `WindowInventoryProbeGate`, which is pure and is tested
/// offline with an injected environment; it deliberately avoids `liveSkipReason`
/// because that one also turns on the global research opt in, which this probe
/// has no reason to ask for.
///
/// With either switch missing or set to anything other than `1`, discovery and
/// execution do nothing at all: no `NSApplication` setup, no window, no native
/// reading. Everything below the gate is built inside the row body.
@Suite(.serialized)
@MainActor
struct WindowInventoryProbeLiveTests {

    @Test("all and on-screen readings are recorded around the phases of two own windows",
          .enabled(if: WindowInventoryProbeGate.liveDisabledReason() == nil,
                   Comment(rawValue: WindowInventoryProbeGate.liveDisabledReason() ?? "")))
    func inventoryPairsAroundOwnWindowPhases() throws {

        let clock   = MonotonicProbeClock()
        let fixture = WindowInventoryProbeFixture(clock: clock)
        let run     = WindowInventoryProbeRun(
            fixture   : fixture,
            reader    : WindowInventoryNativeReader(),
            clock     : clock,
            budget    : .diagnosticDefault,
            provenance: ProbeRunProvenance.identified(
                runID                 : UUID().uuidString,
                operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                architecture          : Self.architecture
            )
        )

        // The report is produced whatever happened, including a stopped plan and
        // an incomplete cleanup, and it is printed before anything is asserted
        // so a failing run still leaves its evidence behind.
        let report = run.execute()
        let json   = try report.jsonData()
        print(String(decoding: json, as: UTF8.self))

        #expect(report.version == WindowInventoryProbeReport.formatVersion)
        #expect(report.verdict == WindowInventoryProbeReport.diagnosticVerdict)
        #expect(report.phases.count == ProbePhaseStep.standardPlan.count)
        // A window whose close was merely requested stays an unverified residue,
        // so an empty residual list is not what a correct cleanup looks like
        // here. What must not happen is a window still reporting itself visible
        // after its close was requested, which is `failed`.
        #expect(report.cleanup.status != .failed,
                Comment(rawValue: "cleanup failed on \(report.cleanup.residualTokens.count) "
                    + "window(s): \(report.cleanup.notes)"))
        #expect(report.cleanup.residualTokens.isEmpty || report.cleanup.status != .verified,
                Comment(rawValue: "a residue must never be reported as a verified cleanup"))
    }

    /// The machine's architecture when `uname` answers, and absent otherwise.
    /// An unknown provenance stays unknown rather than being guessed.
    static var architecture: String? {
        var information = utsname()
        guard uname(&information) == 0 else { return nil }
        let machine = withUnsafeBytes(of: &information.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return machine.isEmpty ? nil : machine
    }
}
