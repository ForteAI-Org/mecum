//
//  LiveHarness.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import AppKit
import CoreGraphics
import Foundation
import PrivateSymbols
import SeatCore

/// The Live tier runs only when the environment asks for it: it opens windows,
/// moves the person's applications and posts real events.
/// Lets the Facilities act on a macOS build the Ledger has not been promoted to.
///
/// The same circle as the host tier: a build is promoted by reading a report,
/// the report needs these suites to run, and on an unpromoted build every
/// Facility refuses. It waives the Ledger's blessing and nothing else, and the
/// self checks that protect the record offsets still run and still refuse.
private let liveResearchOptIn: Bool = {
    FacilityGate.researchOptInForUnvalidatedBuilds = true
    return true
}()

nonisolated func tierEnabled() -> Bool {
    ProcessInfo.processInfo.environment["AGENTSEAT_LIVE_TESTS"] == "1"
}

/// The first unmet precondition of a Live row, so its skip describes the gate
/// that actually disabled it. An available fixture is never called missing.
nonisolated func liveSkipReason(
    optIn: String? = nil,
    needsFixture: Bool = false,
    needsChrome: Bool = false
) -> String? {
    guard tierEnabled() else { return "AGENTSEAT_LIVE_TESTS=1 is required for the Live tier." }
    // Every Live suite passes through here, which is why the opt in is set here
    // and not only inside `LiveStage`: the contextual menu suite brings up its
    // own seat and was refused by the gate on an unpromoted build.
    _ = liveResearchOptIn
    if let optIn, ProcessInfo.processInfo.environment[optIn] != "1" {
        return "\(optIn)=1 is required: this optional calibration is disabled by default."
    }
    if needsFixture && !FixtureTarget.isAvailable { return FixtureTarget.unavailableReason }
    if needsChrome && !OwnBrowserTarget.isAvailable {
        return "Google Chrome is not executable at \(OwnBrowserTarget.executablePath)."
    }
    return nil
}

/// The settle to run the matrix with, in milliseconds, when the calibration is
/// being reproduced: `AGENTSEAT_SETTLE_MS=20|40|80`. Unset means the
/// platform's own default, which is what the acceptance run uses.
/// Whether the rows that need a person at the keyboard may run.
///
/// They are off by default and behind their own switch, not the Live one: every
/// other Live row is spoiled by a hand on the machine and reports `INCO` for it,
/// and these are the two that need exactly that hand. Running both kinds in one
/// pass would make each ruin the other.
nonisolated func manualTestsEnabled() -> Bool {
    ProcessInfo.processInfo.environment["AGENTSEAT_MANUAL_TESTS"] == "1"
}

/// Prints an instruction for the person and pumps the run loop while they do it,
/// so this process stays a real application instead of a frozen one.
@MainActor
func askThePerson(_ instruction: String, seconds: Double = 6) {
    print("\n  ===> \(instruction)")
    print("      (\(Int(seconds)) seconds)")
    LivePump.run(for: seconds)
}

/// The modifier policy to run the matrix with, when the other half of the
/// spike is being measured: `AGENTSEAT_MODIFIER_POLICY=flagsChanged`.
///
/// Unset means the platform's own, which is `eventFlags` for everything the kit
/// ships. The two halves are separate runs on purpose: the question is whether
/// the policy changes the outcome, and a single run that mixed them could not
/// answer it.
nonisolated func modifierPolicyOverride() -> ModifierPolicy? {
    switch ProcessInfo.processInfo.environment["AGENTSEAT_MODIFIER_POLICY"] {
        case "flagsChanged": .flagsChanged
        case "eventFlags"  : .eventFlags
        default            : nil
    }
}

nonisolated func settleOverrideMilliseconds() -> Int? {
    ProcessInfo.processInfo.environment["AGENTSEAT_SETTLE_MS"].flatMap(Int.init)
}

/// A real AppKit event pump, for the same reason the Host tier has one: a
/// virtual display only makes progress while `NSApplication` turns its own
/// event loop (ADR 0007), and a `swift test` process has no loop of its own.
/// Every wait in this suite pumps instead of sleeping.
@MainActor
enum LivePump {

    private static var isPrepared = false

    static func prepare() {
        guard !isPrepared else { return }
        isPrepared = true
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        run(for: 0.2)
    }

    static func run(for seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            autoreleasepool {
                if let event = NSApplication.shared.nextEvent(
                    matching: .any,
                    until   : deadline,
                    inMode  : .default,
                    dequeue : true
                ) {
                    NSApplication.shared.sendEvent(event)
                }
            }
        } while Date() < deadline
    }

    static func run(until condition: () -> Bool, timeout: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            run(for: 0.02)
        }
        return condition()
    }
}

/// UserSeatState is the person's side of every assertion in this suite: which
/// application is in front and where the physical cursor is. An action of the
/// kit may change neither.
nonisolated struct UserSeatState: Equatable {

    let frontmostProcessID: pid_t
    let frontmostName     : String
    let cursor            : CGPoint

    @MainActor
    static func capture() -> UserSeatState {
        let application = NSWorkspace.shared.frontmostApplication
        return UserSeatState(
            frontmostProcessID: application?.processIdentifier ?? -1,
            frontmostName     : application?.localizedName ?? "?",
            cursor            : CGEvent(source: nil)?.location ?? .zero
        )
    }
}

/// What the harness itself can get wrong, apart from the kit.
nonisolated enum LiveFailure: Error, CustomStringConvertible {

    case windowGeometryUnavailable(Int)

    /// A row asked the harness for something this path does not build. It is
    /// a defect of the harness, never a finding about the driver.
    case unsupported(String)

    var description: String {
        switch self {
        case .unsupported(let detail):
            detail
        case .windowGeometryUnavailable(let windowNumber):
            "the window server has no geometry for window \(windowNumber)"
        }
    }
}
