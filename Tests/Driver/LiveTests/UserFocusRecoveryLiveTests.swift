import AppKit
import CoreGraphics
import Dispatch
import CursorGuard
import Foundation
import SeatCore
import SeatInput
import SeatSession
import Testing
import VirtualScreens
import WindowPlacement

@Suite(.serialized)
@MainActor
struct UserFocusRecoveryLiveTests {
    @Test("Chrome Print restores the same user window without pointer input",
          .enabled(if: liveSkipReason(needsChrome: true) == nil,
                   Comment(rawValue: liveSkipReason(needsChrome: true) ?? "")))
    func printRestoresUserFocus() async throws {
        LivePump.prepare()
        var controls: [UInt64] = []
        for _ in 0..<1_000 {
            let start = DispatchTime.now().uptimeNanoseconds
            controls.append(DispatchTime.now().uptimeNanoseconds &- start)
        }
        controls.sort()
        print("FOCUS_CLOCK_CONTROL_NS \(controls.reduce(0, +) / UInt64(controls.count))")
        let person = UserSeatState.capture()
        let displaysBefore = Set(try DisplayList.online())
        let usesKeyRecords = ProcessInfo.processInfo.environment["AGENTSEAT_FOCUS_KEY_RECORDS"] == "1"
        // Every resource this row creates is claimed against this identity before
        // it can fail, so a partial start leaves a chain instead of an orphan.
        let trial = TrialResources.sanitized(
            trial: ProcessInfo.processInfo.environment["AGENTSEAT_FOCUS_TRIAL"]
        ) ?? "unidentified-\(TrialResources.token())"
        let ledger = TrialResources.Ledger(trial: trial)
        var configuration = SeatHostConfiguration(restoresUserFocus: true, allowUnvalidatedFocusRecovery: true)
        configuration.focusRecoveryUsesKeyRecords = usesKeyRecords
        let host = SeatHost(configuration: configuration)
        try await host.start()
        let displayIdentity = host.displayID.map { "display \($0)" } ?? "display unidentified"
        ledger.claim(.virtualDisplay, identity: displayIdentity,
                     provenance: "created by the host \(trial) started")
        let sampler = Process()
        let sampleOutput = Pipe()
        var samplerProvenance: TrialResources.ProcessProvenance?
        var browser: OwnBrowserTarget?
        do {
            let target = try OwnBrowserTarget.launched(ledger: ledger)
            browser = target
            let seat = try host.makeSeat()
            var adopted = try await seat.adopt(target.reference, platform: ChromiumPlatform())
            if !seat.isStaged(adopted) { adopted = try await seat.stage(adopted) }
            NSRunningApplication(processIdentifier: person.frontmostProcessID)?.activate()
            LivePump.run(for: 0.8)
            var observations = [FocusAXObservation.read(person.frontmostProcessID, phase: "before")]
            let userWindow = try #require(observations.last?.windowNumber)
            if ProcessInfo.processInfo.environment["AGENTSEAT_FOCUS_SCENARIO"] == "warm-menu" {
                let warmTurn = try await seat.acquire()
                let warmGeometry = try #require(WindowServerProbe.geometry(of: adopted.id))
                let warmOutcome = try await seat.withContextMenu(
                    openedAt   : try #require(target.probePoint(within: warmGeometry.frame)),
                    observation: try await liveObservation(seat),
                    turn       : warmTurn
                )
                try #require(warmOutcome.insideMenu.isEmpty)
                try #require(warmOutcome.cleanup != .verifiedClosed(.chosenItem))
                try seat.release(warmTurn)
                LivePump.run(for: 0.3)
            }
            let before = UserSeatState.capture()
            try #require(before.frontmostProcessID == person.frontmostProcessID)
            let fence = try #require(host.fence)
            let hid = fence.snapshot().observedEventCount
            let bounds = CGDisplayBounds(try #require(host.displayID))
            let turn = try await seat.acquire()
            let turnIdentity = "turn \(turn.generation)"
            ledger.claim(.seatTurn, identity: turnIdentity, provenance: "acquired by \(trial)")
            let geometry = try #require(WindowServerProbe.geometry(of: adopted.id))
            var samplerLaunched = false
            let samplerPath = ProcessInfo.processInfo.environment["AGENTSEAT_FOCUS_SAMPLER"]
            if let samplerPath {
                sampler.executableURL = URL(fileURLWithPath: samplerPath)
                // The trial token travels with the sampler, and the experimental
                // admission only when this invocation was given one. The sampler
                // refuses on its own identity check either way.
                var arguments = [String(userWindow), String(adopted.id),
                                 ProcessInfo.processInfo.environment["AGENTSEAT_FOCUS_SAMPLE_US"] ?? "100",
                                 "--trial=\(trial)"]
                if ProcessInfo.processInfo.environment["AGENTSEAT_FOCUS_RESEARCH_ADMISSION"] == "1" {
                    arguments.append("--experimental-research-admission")
                }
                sampler.arguments = arguments
                sampler.standardOutput = sampleOutput
            }
            let outcome = try await seat.withContextMenu(
                openedAt   : try #require(target.probePoint(within: geometry.frame)),
                observation: try await liveObservation(seat),
                turn       : turn
            ) { interaction in
                let pointFromTop: CGPoint
                do {
                    pointFromTop = try MenuImageChoice.point(
                        for: ["Print...", "Print…", "Stampa...", "Stampa…"],
                        in : interaction.menu.window
                    )
                } catch {
                    Issue.record("Print was not uniquely identified: \(error)")
                    return
                }
                // The click is addressed by an observation of the menu's own
                // surface. Where that capability is unqualified the item is not
                // chosen at all: the row stops with the reason named instead of
                // posting a click it aimed itself.
                guard case .success(let delivery) = await interaction.observe() else {
                    Issue.record(Comment(rawValue: "the menu's own surface could not be observed, "
                        + "so Print was not chosen and this trial exercised nothing"))
                    return
                }
                let frame = delivery.geometry.window.frame
                guard let point = InputLocation(
                    screenPoint: CGPoint(
                        x: frame.minX + pointFromTop.x,
                        y: frame.minY + pointFromTop.y
                    ),
                    observedIn : delivery.geometry
                ) else {
                    Issue.record("the identified point is outside the observed menu")
                    return
                }
                if let samplerPath, sampler.executableURL != nil {
                    do {
                        try sampler.run()
                        samplerLaunched = true
                        let provenance = TrialResources.ProcessProvenance(
                            kind                       : .samplerProcess,
                            trial                      : trial,
                            launchToken                : trial,
                            processIdentifier          : sampler.processIdentifier,
                            launchedAtUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                            command                    : samplerPath
                        )
                        samplerProvenance = provenance
                        ledger.claim(provenance)
                    } catch {
                        Issue.record("the independent focus sampler did not start: \(error)")
                    }
                }
                do {
                    _ = try await interaction.send(
                        .click(point, button: .left),
                        observation: delivery.reference
                    )
                } catch {
                    Issue.record("the Print click was refused: \(error)")
                }
            }
            #expect(outcome.insideMenu.count == 1)
            #expect(outcome.cleanup == .verifiedClosed(.chosenItem))
            let restored = LivePump.run(until: {
                seat.lastFocusRecovery?.outcome == .restored && seat.state.acceptsCommands
            }, timeout: 3)
            let report = try #require(seat.lastFocusRecovery, "No activation was recovered; this test did not exercise Print")
            #expect(restored, "\(report)")
            #expect(report.destination?.windowNumber == userWindow)
            #expect(report.requestCode == 0)
            #expect(report.timing.actionPreparationNanoseconds > 0)
            #expect(report.timing.preparedWindowsNanoseconds > 0)
            #expect(report.timing.preparedIdentityNanoseconds > 0)
            #expect(report.timing.ownerLookupNanoseconds == 0)
            #expect(report.timing.psnLookupNanoseconds == 0)
            #expect(report.timing.preparedSnapshotAgeNanoseconds <= 1_000_000_000)
            #expect((report.timing.firstKeyNanoseconds > 0) == usesKeyRecords)
            #expect((report.timing.secondKeyNanoseconds > 0) == usesKeyRecords)
            #expect(report.activatingProcessID == target.processID)
            #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == person.frontmostProcessID)
            observations.append(FocusAXObservation.read(person.frontmostProcessID, phase: "after"))
            let focusedAfter = observations.last?.windowNumber
            #expect(focusedAfter == userWindow)
            for index in 0..<4 {
                LivePump.run(for: 0.05)
                observations.append(FocusAXObservation.read(person.frontmostProcessID, phase: "stability-\(index)"))
                #expect(observations.last?.windowNumber == userWindow,
                        "Focus must remain on the recovered window after the menu action")
            }
            let after = UserSeatState.capture()
            let physicalEvents = fence.snapshot().observedEventCount &- hid
            #expect(before.cursor == after.cursor)
            #expect(physicalEvents == 0, "Physical activity makes this focus measurement inconclusive")
            #expect(bounds.contains(try #require(WindowServerProbe.geometry(of: adopted.id)).frame))
            #expect(seat.unconfirmedCommandCount == 0)
            if ProcessInfo.processInfo.environment["AGENTSEAT_FOCUS_BUDGET"] == "1" {
                #expect((report.frontmostRestoredNanoseconds ?? UInt64.max) <= 8_000_000,
                        "Focus exceeded the requested 8 ms detection-to-frontmost budget")
            }
            if samplerLaunched {
                sampler.waitUntilExit()
                #expect(sampler.terminationStatus == 0, "The independent focus sampler did not complete")
                let bytes = sampleOutput.fileHandleForReading.readDataToEndOfFile()
                print(String(decoding: bytes, as: UTF8.self))
                // Waiting for the exit is not by itself proof that the process is
                // gone: the release below observes it before it says so.
                Self.release(sampler: sampler, provenance: samplerProvenance, in: ledger)
            }
            let oracleData = try JSONEncoder().encode(observations)
            print("FOCUS_AX \(String(decoding: oracleData, as: UTF8.self))")
            let validation: [String: Bool] = [
                "cursor_unchanged": before.cursor == after.cursor,
                "no_physical_input": physicalEvents == 0,
                "same_user_app": before.frontmostProcessID == after.frontmostProcessID,
                "same_user_window": observations.allSatisfy { $0.windowNumber == userWindow },
                "recovered": restored,
                "target_virtual": bounds.contains(WindowServerProbe.geometry(of: adopted.id)?.frame ?? .null),
                "no_uncertain_commands": seat.unconfirmedCommandCount == 0
            ]
            let validationData = try JSONEncoder().encode(validation)
            print("FOCUS_VALIDATION \(String(decoding: validationData, as: UTF8.self))")
            let timingData = try JSONEncoder().encode(report.timing)
            print("FOCUS_TIMING \(String(decoding: timingData, as: UTF8.self))")
            print("FOCUS recovery=\(report.outcome.rawValue) frontmost=\(report.frontmostRestoredNanoseconds.map { Double($0) / 1e6 } ?? -1) ms detection-to-verification=\(Double(report.elapsedNanoseconds) / 1e6) ms request=\(report.requestCode ?? -999) cursor=\(before.cursor)->\(after.cursor) HID=\(physicalEvents)")
            try seat.release(turn)
            ledger.settle(.seatTurn, identity: turnIdentity,
                          outcome: .completedAndVerified("released by the trial that acquired it"))
            target.terminate()
            browser = nil
            let teardown = await host.stop()
            let displaysAfter = Set(try DisplayList.online())
            Self.settle(display: displayIdentity, teardown: teardown,
                        restored: displaysAfter == displaysBefore, in: ledger)
            print("FOCUS_CLEANUP \(ledger.json())")
            #expect(teardown.displayRemoved)
            #expect(displaysAfter == displaysBefore)
            #expect(ledger.isComplete, "Teardown left residues: \(ledger.residues)")
        } catch {
            // The original failure is the one this row reports. The teardown runs
            // beside it, resource by resource, and whatever it could not verify
            // stays visible instead of replacing the error or disappearing.
            browser?.terminate()
            Self.release(sampler: sampler, provenance: samplerProvenance, in: ledger)
            let teardown = await host.stop()
            let restored = (try? Set(DisplayList.online())) == displaysBefore
            Self.settle(display: displayIdentity, teardown: teardown,
                        restored: restored, in: ledger)
            print("FOCUS_CLEANUP \(ledger.json())")
            let failure = TrialResources.reportedFailure(original: error, residues: ledger.residues)
            if let note = failure.note { Issue.record("\(note)") }
            throw failure.error
        }
    }

    /// Ends the sampler this row started, and only that one, then records whether
    /// the end was observed. A claim with no provenance behind it is left as the
    /// residue it is.
    private static func release(
        sampler   : Process,
        provenance: TrialResources.ProcessProvenance?,
        in ledger : TrialResources.Ledger
    ) {
        guard let provenance else { return }
        switch TrialResources.ownership(
            of      : provenance,
            observed: TrialResources.observe(sampler, provenance: provenance)
        ) {
        case .notAttested(let reason):
            ledger.settle(provenance, outcome: .unknownOrIncomplete(reason))

        case .ownedAndGone:
            ledger.settle(provenance, outcome: .completedAndVerified(
                "the sampler this trial started exited with status \(sampler.terminationStatus)"))

        case .ownedAndRunning:
            sampler.terminate()
            for _ in 0 ..< 40 where sampler.isRunning { LivePump.run(for: 0.05) }
            ledger.settle(provenance, outcome: sampler.isRunning
                ? .unknownOrIncomplete("the sampler this trial started was still running after"
                                       + " its termination")
                : .completedAndVerified("the sampler this trial started ended after its termination"))
        }
    }

    /// Records the display outcome from the host's own teardown report and from
    /// the online list, never from a new removal primitive of its own.
    private static func settle(
        display  : String,
        teardown : TeardownReport,
        restored : Bool,
        in ledger: TrialResources.Ledger
    ) {
        ledger.settle(.virtualDisplay, identity: display,
                      outcome: teardown.displayRemoved && restored
            ? .completedAndVerified("the host removed its display and the online list matches"
                                    + " the one taken before the row")
            : .unknownOrIncomplete("teardown reported displayRemoved \(teardown.displayRemoved)"
                                   + " and the online list \(restored ? "matches" : "does not match")"))
    }

}

/// Offline checks of the ownership and teardown rules the focus row applies.
///
/// Every process, path, clock and native read is a supplied value, so these rows
/// run in the unit tier with no gate: nothing here launches a browser, creates a
/// display, posts input or resolves a private symbol. They exercise the same
/// functions the Live row calls, not a copy of them.
@Suite
@MainActor
struct FocusTrialOwnershipTests {

    private let launch = TrialResources.ProcessProvenance(
        kind                       : .browserProcess,
        trial                      : "trial-1-abcdef",
        launchToken                : "tok-abcdef",
        processIdentifier          : 4242,
        launchedAtUptimeNanoseconds: 1_000,
        command                    : "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    )

    private let directory = TrialResources.DirectoryProvenance(
        kind                 : .temporaryProfileDirectory,
        trial                : "trial-1-abcdef",
        path                 : "/tmp/agentseat-menu-77-abcdef",
        marker               : "trial-1-abcdef/abcdef",
        wasCreatedByThisTrial: true
    )

    private func observed(
        pid      : pid_t  = 4242,
        token    : String? = "tok-abcdef",
        running  : Bool   = true,
        attested : Bool   = true,
        startedAt: UInt64? = nil
    ) -> TrialResources.ObservedProcess {
        TrialResources.ObservedProcess(
            processIdentifier         : pid,
            launchToken               : token,
            isRunning                 : running,
            isAttestedByLaunchHandle  : attested,
            startedAtUptimeNanoseconds: startedAt
        )
    }

    private func seen(
        path     : String = "/tmp/agentseat-menu-77-abcdef",
        exists   : Bool   = true,
        link     : Bool   = false,
        directory: Bool   = true,
        marker   : String? = "trial-1-abcdef/abcdef"
    ) -> TrialResources.ObservedDirectory {
        TrialResources.ObservedDirectory(path: path, exists: exists, isSymbolicLink: link,
                                         isDirectory: directory, marker: marker)
    }

    @Test("Only the running process this trial launched may be ended")
    func ownRunningProcessIsTheOnlyOneItMayEnd() {
        #expect(TrialResources.ownership(of: launch, observed: observed()) == .ownedAndRunning)
        #expect(TrialResources.ownership(of: launch, observed: observed(running: false))
                == .ownedAndGone)
    }

    @Test("A recycled pid, a foreign token, another pid or no observation are all refused")
    func everyUnattestedProcessIsRefused() {
        let refusals = [
            TrialResources.ownership(of: launch, observed: observed(attested: false)),
            TrialResources.ownership(of: launch, observed: observed(token: "tok-other")),
            TrialResources.ownership(of: launch, observed: observed(token: nil)),
            TrialResources.ownership(of: launch, observed: observed(pid: 4243)),
            TrialResources.ownership(of: launch, observed: observed(startedAt: 999)),
            TrialResources.ownership(of: launch, observed: nil),
        ]
        for refusal in refusals {
            guard case .notAttested = refusal else {
                Issue.record("an unattested process was authorised: \(refusal)")
                continue
            }
        }
    }

    @Test("A link, a different path, a foreign marker or a file are not this trial's directory")
    func everyUnattestedPathIsRefused() {
        let refusals = [
            TrialResources.ownership(of: directory, observed: seen(link: true)),
            TrialResources.ownership(of: directory, observed: seen(path: "/tmp/agentseat-menu-77")),
            TrialResources.ownership(of: directory, observed: seen(marker: "other-trial/xyz")),
            TrialResources.ownership(of: directory, observed: seen(marker: nil)),
            TrialResources.ownership(of: directory, observed: seen(directory: false)),
        ]
        for refusal in refusals {
            guard case .notAttested = refusal else {
                Issue.record("an unattested path was authorised: \(refusal)")
                continue
            }
        }
        let foreign = TrialResources.DirectoryProvenance(
            kind: directory.kind, trial: directory.trial, path: directory.path,
            marker: directory.marker, wasCreatedByThisTrial: false
        )
        guard case .notAttested = TrialResources.ownership(of: foreign, observed: seen()) else {
            Issue.record("a directory this trial did not create was authorised")
            return
        }
    }

    @Test("A prefix of the recorded path is never the recorded path")
    func aSharedPrefixIsNotOwnership() {
        let sibling = seen(path: directory.path + "-2")
        guard case .notAttested = TrialResources.ownership(of: directory, observed: sibling) else {
            Issue.record("a sibling directory with the same prefix was authorised")
            return
        }
        #expect(TrialResources.ownership(of: directory, observed: seen(exists: false))
                == .ownedAndAbsent)
        #expect(TrialResources.ownership(of: directory, observed: nil) == .ownedAndAbsent)
        #expect(TrialResources.ownership(of: directory, observed: seen()) == .ownedAndPresent)
    }

    @Test("A launch that failed halfway leaves its chain reconstructable")
    func partialLaunchKeepsItsChain() {
        let ledger = TrialResources.Ledger(trial: "trial-1-abcdef")
        ledger.claim(directory)
        // The browser never started, so nothing claims it and the directory is
        // the only resource this trial has to account for.
        ledger.settle(directory, outcome: .completedAndVerified("removed"))
        #expect(ledger.records.count == 1)
        #expect(ledger.isComplete)
        let broken = TrialResources.Ledger(trial: "trial-2-abcdef")
        broken.claim(directory)
        broken.claim(launch)
        #expect(broken.records.map(\.kind)
                == ["temporary_profile_directory", "browser_process"])
        #expect(broken.residues.count == 2)
        #expect(broken.records.allSatisfy { $0.status == "unknown_incomplete" })
        #expect(broken.records.first?.provenance == "created by trial-1-abcdef")
    }

    @Test("An unsettled claim is a residue and stops the next cell")
    func anUnsettledClaimStopsTheNextCell() {
        let ledger = TrialResources.Ledger(trial: "trial-3-abcdef")
        ledger.claim(.seatTurn, identity: "turn 1", provenance: "acquired by trial-3-abcdef")
        ledger.claim(launch)
        ledger.settle(launch, outcome: .completedAndVerified("exited"))
        #expect(!ledger.isComplete)
        #expect(!ledger.mayStartAnotherTrial)
        #expect(ledger.residues.map(\.kind) == ["seat_turn"])
        ledger.settle(.seatTurn, identity: "turn 1", outcome: .completedAndVerified("released"))
        #expect(ledger.isComplete)
        #expect(ledger.mayStartAnotherTrial)
    }

    @Test("Concluded, failed and unknown outcomes stay three different answers")
    func outcomesStayDistinguishable() {
        let ledger = TrialResources.Ledger(trial: "trial-4-abcdef")
        ledger.claim(launch)
        ledger.claim(directory)
        ledger.claim(.virtualDisplay, identity: "display 7", provenance: "created by the host")
        ledger.settle(launch, outcome: .completedAndVerified("exited after its termination"))
        ledger.settle(directory, outcome: .failed("the removal reported an error"))
        ledger.settle(.virtualDisplay, identity: "display 7",
                      outcome: .unknownOrIncomplete("the online list does not match"))
        #expect(ledger.records.map(\.status)
                == ["completed_verified", "failed", "unknown_incomplete"])
        #expect(ledger.residues.count == 2)
        #expect(!ledger.isComplete)
    }

    @Test("An empty ledger has proven nothing")
    func anEmptyLedgerIsNotComplete() {
        #expect(!TrialResources.Ledger(trial: "trial-5-abcdef").isComplete)
    }

    @Test("An outcome with no claim behind it is itself a gap")
    func anUnclaimedOutcomeIsAGap() {
        let ledger = TrialResources.Ledger(trial: "trial-6-abcdef")
        ledger.settle(launch, outcome: .completedAndVerified("exited"))
        #expect(ledger.records.count == 1)
        #expect(ledger.records.first?.status == "unknown_incomplete")
        #expect(!ledger.isComplete)
    }

    @Test("A cleanup failure never replaces the error the row is reporting")
    func cleanupNeverMasksTheOriginalError() {
        let ledger = TrialResources.Ledger(trial: "trial-7-abcdef")
        ledger.claim(launch)
        ledger.settle(launch, outcome: .unknownOrIncomplete("still running after SIGKILL"))
        let failure = TrialResources.reportedFailure(original: OwnBrowserFailure.neverAppeared,
                                                     residues: ledger.residues)
        #expect(failure.error is OwnBrowserFailure)
        #expect(failure.note?.contains("still running after SIGKILL") == true)
        #expect(failure.note?.contains("browser_process") == true)
        let clean = TrialResources.Ledger(trial: "trial-8-abcdef")
        clean.claim(launch)
        clean.settle(launch, outcome: .completedAndVerified("exited"))
        #expect(TrialResources.reportedFailure(original: OwnBrowserFailure.neverBecameReadable,
                                               residues: clean.residues).note == nil)
    }

    @Test("The teardown record carries every resource and its outcome")
    func teardownRecordCarriesEveryResource() throws {
        let ledger = TrialResources.Ledger(trial: "trial-9-abcdef")
        ledger.claim(launch)
        ledger.claim(directory)
        ledger.settle(launch, outcome: .completedAndVerified("exited"))
        let payload = try #require(ledger.json().data(using: .utf8))
        let object = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(object["trial"] as? String == "trial-9-abcdef")
        #expect(object["complete"] as? Bool == false)
        let resources = try #require(object["resources"] as? [[String: Any]])
        #expect(resources.count == 2)
        #expect(resources.first?["status"] as? String == "completed_verified")
        #expect(resources.last?["status"] as? String == "unknown_incomplete")
        #expect(resources.last?["identity"] as? String == directory.path)
    }

    @Test("A trial name from the environment cannot become an argument or a path")
    func trialNamesAreKeptToWhatTheSamplerAccepts() {
        #expect(TrialResources.sanitized(trial: "trial-1-abcdef") == "trial-1-abcdef")
        for rejected in ["", "trial 1", "--experimental-research-admission", "../escape",
                         "a/b", String(repeating: "x", count: 65)] {
            #expect(TrialResources.sanitized(trial: rejected) == nil)
        }
        #expect(TrialResources.sanitized(trial: nil) == nil)
    }
}
