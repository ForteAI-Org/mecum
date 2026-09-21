//
//  OwnBrowserTarget.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/09/2026.
//

import AppKit
import CoreGraphics
import Dispatch
import Foundation
import SeatCore
import SeatInput
import WindowPlacement

/// OwnBrowserTarget is a Chromium window this suite **launched itself**, on a
/// profile of its own in a temporary directory.
///
/// It exists next to `ChromeTarget`, which drives the browser the person
/// already has open, and the difference is the point. A contextual menu is a
/// modal tracking loop inside the target: while one is up, that application
/// runs nothing else, and the row that measures it deliberately does not take
/// that risk with a window the person is using. The profile directory means the
/// person's tabs, session and history are neither opened nor read, and the
/// browser this target quits is one it started.
///
/// It is found by process id and never by title alone: with the person's own
/// browser running, two windows answer to the same owner name.
///
/// Every launch records its provenance in a `TrialResources.Ledger` before it
/// can fail, so a partial start leaves a reconstructable chain instead of an
/// anonymous browser and an anonymous directory.
@MainActor
final class OwnBrowserTarget {

    nonisolated static let executablePath =
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    /// A page that is one large text area, because a text area is the control
    /// every Chromium build opens a contextual menu on.
    static let pageHTML = """
        <!doctype html><html><head><meta charset="utf-8"><title>ASMENU</title></head>
        <body style="margin:0;background:#123">
        <textarea style="width:100vw;height:100vh;font:14px monospace;background:#012;
        color:#eee;border:0">menu probe</textarea>
        <script>
        const field = document.querySelector("textarea");
        function report() {
            document.title = "ASMENU s=" + (field.selectionEnd - field.selectionStart)
                + " v=" + encodeURIComponent(field.value);
        }
        document.addEventListener("selectionchange", report);
        field.addEventListener("input", report);
        report();
        </script>
        </body></html>
        """

    nonisolated static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executablePath)
    }

    let processID   : pid_t
    let windowNumber: Int

    /// What the window really measures, which is what `stage` has to confirm.
    let expectedSize: CGSize

    private let process   : Process
    private let scratch   : URL
    private let ownership : Ownership
    private var frame     : CGRect

    /// What this target may act on later, and on nothing else.
    private struct Ownership {
        let browser  : TrialResources.ProcessProvenance
        let directory: TrialResources.DirectoryProvenance
        let ledger   : TrialResources.Ledger?
    }

    private init(
        process  : Process,
        scratch  : URL,
        ownership: Ownership,
        window   : (pid_t, Int, CGRect)
    ) {
        self.process      = process
        self.scratch      = scratch
        self.ownership    = ownership
        self.processID    = window.0
        self.windowNumber = window.1
        self.frame        = window.2
        self.expectedSize = window.2.size
    }

    /// Launches the browser and waits, pumping, for its window to appear **and
    /// to stop moving**. A window that is still being placed by the browser is
    /// one whose adoption the placement confirmation refuses, correctly.
    ///
    /// The directory is claimed in `ledger` as soon as it exists and the browser
    /// as soon as it is running, so a launch that fails between those points
    /// still leaves the caller the provenance of what was created. Every failure
    /// path releases only what this call attested, and records the outcome of
    /// each release separately.
    static func launched(
        timeout : Double = 60,
        pageHTML: String = OwnBrowserTarget.pageHTML,
        ledger  : TrialResources.Ledger? = nil
    ) throws -> OwnBrowserTarget {

        let trial = ledger?.trial ?? "unidentified"
        let token = TrialResources.token()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentseat-menu-\(ProcessInfo.processInfo.processIdentifier)-\(token)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        let marker = "\(trial)/\(token)"
        try marker.write(
            to        : scratch.appendingPathComponent(TrialResources.markerName),
            atomically: true,
            encoding  : .utf8
        )
        let directory = TrialResources.DirectoryProvenance(
            kind                : .temporaryProfileDirectory,
            trial               : trial,
            path                : scratch.path,
            marker              : marker,
            wasCreatedByThisTrial: true
        )
        ledger?.claim(directory)
        let page = scratch.appendingPathComponent("menu-probe.html")
        try pageHTML.write(to: page, atomically: true, encoding: .utf8)

        let process           = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments     = [
            "--user-data-dir=\(scratch.appendingPathComponent("profile").path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-session-crashed-bubble",
            "--new-window",
            page.absoluteString,
        ]
        do {
            try process.run()
        } catch {
            // The browser never started, so the only resource to account for is
            // the directory this call created.
            release(directory: directory, ledger: ledger)
            throw error
        }
        let browser = TrialResources.ProcessProvenance(
            kind                      : .browserProcess,
            trial                     : trial,
            launchToken               : token,
            processIdentifier         : process.processIdentifier,
            launchedAtUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            command                   : executablePath
        )
        ledger?.claim(browser)
        let ownership = Ownership(browser: browser, directory: directory, ledger: ledger)

        var found: (pid_t, Int, CGRect)?
        _ = LivePump.run(
            until  : {
                found = window(ofProcess: process.processIdentifier)
                return found != nil
            },
            timeout: timeout
        )
        guard var settled = found else {
            release(process: process, ownership: ownership)
            throw OwnBrowserFailure.neverAppeared
        }
        var previous = CGRect.null
        _ = LivePump.run(
            until  : {
                guard let now = window(ofProcess: process.processIdentifier) else { return false }
                defer { previous = now.2; settled = now }
                return now.2 == previous
            },
            timeout: 20
        )

        // A window the window server lists is not yet a window the seat can
        // move. The move goes through `AXPosition`, and a browser that has just
        // started answers `AXWindows` with nothing at all for the first
        // moments: adopting inside that gap fails with a window number of zero,
        // which is the accessibility list being empty and not the window being
        // gone.
        let ready = LivePump.run(
            until  : {
                ChromeWindow.element(processID: settled.0, windowNumber: settled.1) != nil
            },
            timeout: 20
        )
        guard ready else {
            release(process: process, ownership: ownership)
            throw OwnBrowserFailure.neverBecameReadable
        }
        return OwnBrowserTarget(
            process  : process,
            scratch  : scratch,
            ownership: ownership,
            window   : settled
        )
    }

    /// Opens another window in this test's profile and waits for its attested
    /// identity and accessibility element. No existing user profile is addressed.
    func openAdditionalWindow() throws -> WindowReference {
        let existing = Set(ChromeWindow.windows(ownedBy: ChromeTarget.ownerName)
            .filter { $0.processID == processID }.map(\.windowNumber))
        let request = Process()
        request.executableURL = URL(fileURLWithPath: Self.executablePath)
        request.arguments = [
            "--user-data-dir=\(scratch.appendingPathComponent("profile").path)",
            "--new-window",
            scratch.appendingPathComponent("menu-probe.html").absoluteString
        ]
        try request.run()
        defer { if request.isRunning { request.terminate() } }
        var found: WindowReference?
        var previous: WindowReference?
        let ready = LivePump.run(
            until: {
                for candidate in ChromeWindow.windows(ownedBy: ChromeTarget.ownerName)
                    where candidate.processID == self.processID
                        && !existing.contains(candidate.windowNumber) {
                    guard let window = WindowServerProbe.geometry(of: candidate.windowNumber),
                          window.frame.width > 300, window.frame.height > 300,
                          ChromeWindow.element(processID: self.processID,
                                               windowNumber: window.windowNumber) != nil
                    else { continue }
                    defer { previous = window }
                    if previous == window { found = window; return true }
                }
                return false
            },
            timeout: 20
        )
        guard ready, let found else { throw OwnBrowserFailure.neverBecameReadable }
        return found
    }

    /// The browser's own window, found by owner process and by size: a Chromium
    /// browser owns several windows of its own besides the one with the page in
    /// it, and the page's is the large one.
    private static func window(ofProcess launched: pid_t) -> (pid_t, Int, CGRect)? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let entries = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]]
        else { return nil }

        // The renderer runs in a child process, so the window's owner is the
        // browser process this suite started or one of its descendants, and the
        // owner name plus a launch of our own is what identifies it.
        for entry in entries {
            guard (entry[kCGWindowOwnerName as String] as? String) == "Google Chrome",
                  let processID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  processID == launched,
                  let number = (entry[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let rawBounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
                  frame.width > 300, frame.height > 300
            else { continue }
            return (processID, number, frame)
        }
        return nil
    }

    var window: WindowReference {
        guard let reference = WindowServerProbe.geometry(of: windowNumber),
              reference.processID == processID
        else {
            return WindowReference(processID: processID, windowNumber: windowNumber, frame: frame)
        }
        return reference.replacingFrame(frame)
    }

    var reference: WindowReference {
        window.replacingFrame(CGRect(origin: frame.origin, size: expectedSize))
    }

    func refresh() {
        guard let geometry = WindowServerProbe.geometry(of: windowNumber) else { return }
        frame = geometry.frame
    }

    /// Well inside the page and below the browser's own chrome, which is where
    /// the text area is.
    func probePoint(within staged: CGRect) -> InputLocation? {
        guard let reference = WindowServerProbe.geometry(of: windowNumber),
              reference.frame == staged,
              let geometry = WindowGeometryProbe.observation(of: reference),
              geometry.window.frame == staged
        else { return nil }
        return InputLocation(
            screenPoint: CGPoint(x: staged.midX, y: staged.minY + staged.height * 0.6),
            observedIn : geometry
        )
    }

    /// Quits the browser this suite started, and only that one, then removes the
    /// directory it created, and only that one.
    ///
    /// Each of the two is settled in the ledger on its own: an outcome is
    /// `completedAndVerified` only when the release was observed afterwards, and
    /// anything this call could not attest stays a residue instead of turning
    /// into an action on a similar resource.
    func terminate() {
        Self.release(process: process, ownership: ownership)
    }

    /// Releases only what `ownership` attests. A refused attestation never
    /// escalates to a name, a title or a pid on its own.
    private static func release(process: Process, ownership: Ownership) {
        let browser = ownership.browser
        switch TrialResources.ownership(
            of      : browser,
            observed: TrialResources.observe(process, provenance: browser)
        ) {
        case .notAttested(let reason):
            ownership.ledger?.settle(browser, outcome: .unknownOrIncomplete(reason))

        case .ownedAndGone:
            ownership.ledger?.settle(
                browser,
                outcome: .completedAndVerified("the browser this trial launched had already exited")
            )

        case .ownedAndRunning:
            process.terminate()
            for _ in 0 ..< 40 where process.isRunning { LivePump.run(for: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            for _ in 0 ..< 20 where process.isRunning { LivePump.run(for: 0.05) }
            ownership.ledger?.settle(browser, outcome: process.isRunning
                ? .unknownOrIncomplete("the browser this trial launched was still running "
                                       + "after its termination and a SIGKILL")
                : .completedAndVerified("the browser this trial launched exited after its "
                                        + "own termination"))
        }
        release(directory: ownership.directory, ledger: ownership.ledger)
    }

    /// Removes the exact directory this trial created, and only when the marker
    /// it wrote is still inside it. A shared prefix or a link is not ownership.
    private static func release(
        directory : TrialResources.DirectoryProvenance,
        ledger    : TrialResources.Ledger?
    ) {
        switch TrialResources.ownership(
            of      : directory,
            observed: TrialResources.observe(directory: directory.path)
        ) {
        case .notAttested(let reason):
            ledger?.settle(directory, outcome: .unknownOrIncomplete(reason))

        case .ownedAndAbsent:
            ledger?.settle(
                directory,
                outcome: .completedAndVerified("the directory this trial created is no longer there")
            )

        case .ownedAndPresent:
            do {
                try FileManager.default.removeItem(atPath: directory.path)
                let after = TrialResources.observe(directory: directory.path)
                ledger?.settle(directory, outcome: after.exists
                    ? .unknownOrIncomplete("the directory this trial created is still present "
                                           + "after its removal")
                    : .completedAndVerified("the directory this trial created was removed"))
            } catch {
                ledger?.settle(directory, outcome: .failed("\(error)"))
            }
        }
    }
}

/// TrialResources is the ownership vocabulary of one focus trial: what the trial
/// created, what attests each resource as its own, and how its release ended.
///
/// The decisions are pure functions of a recorded provenance and an observation,
/// so every refusal (a recycled pid, a link, a foreign marker, a partial launch)
/// is exercised offline with supplied values instead of a live process table or a
/// live filesystem. A resource this vocabulary cannot attest is reported as a
/// residue: it is never traded for a similar looking one.
///
/// It lives beside `OwnBrowserTarget` because the ticket's scope adds no file to
/// this suite, and it is used by the focus row and by that target together.
nonisolated enum TrialResources {

    /// The file each owned directory carries, naming the trial that created it.
    static let markerName = ".agentseat-owner"

    /// A short printable token, used as the directory suffix and as the launch
    /// token the browser carries in its own arguments.
    static func token() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }

    /// Keeps a caller supplied trial name to the characters the sampler and the
    /// report accept, so an environment value cannot become an argument or a path.
    static func sanitized(trial: String?) -> String? {
        guard let trial, !trial.isEmpty, trial.count <= 64, !trial.hasPrefix("-") else { return nil }
        let allowed = trial.allSatisfy { character in
            character.isLetter || character.isNumber || character == "-"
                || character == "_" || character == "."
        }
        return allowed ? trial : nil
    }

    enum Kind: String, Codable, Sendable {
        case samplerProcess            = "sampler_process"
        case browserProcess            = "browser_process"
        case temporaryProfileDirectory = "temporary_profile_directory"
        case seatTurn                  = "seat_turn"
        case virtualDisplay            = "virtual_display"
    }

    /// A process this trial started itself, with the token it carries.
    struct ProcessProvenance: Equatable, Sendable {

        let kind                       : Kind
        let trial                      : String
        let launchToken                : String
        let processIdentifier          : pid_t
        let launchedAtUptimeNanoseconds: UInt64
        let command                    : String

        var identity  : String { "pid \(processIdentifier) token \(launchToken)" }
        var provenance: String { "started by \(trial) as \(command)" }
    }

    /// What is known about that process now. A pid on its own is recyclable, so
    /// `isAttestedByLaunchHandle` says whether the unreaped child handle of this
    /// process still stands behind the number.
    struct ObservedProcess: Equatable, Sendable {

        let processIdentifier         : pid_t
        let launchToken               : String?
        let isRunning                 : Bool
        let isAttestedByLaunchHandle  : Bool
        let startedAtUptimeNanoseconds: UInt64?

        init(
            processIdentifier         : pid_t,
            launchToken               : String?,
            isRunning                 : Bool,
            isAttestedByLaunchHandle  : Bool,
            startedAtUptimeNanoseconds: UInt64? = nil
        ) {
            self.processIdentifier          = processIdentifier
            self.launchToken                = launchToken
            self.isRunning                  = isRunning
            self.isAttestedByLaunchHandle   = isAttestedByLaunchHandle
            self.startedAtUptimeNanoseconds = startedAtUptimeNanoseconds
        }
    }

    enum ProcessOwnership: Equatable, Sendable {
        case ownedAndRunning
        case ownedAndGone
        case notAttested(String)
    }

    /// A directory this trial created, with the marker it wrote inside it.
    struct DirectoryProvenance: Equatable, Sendable {

        let kind                 : Kind
        let trial                : String
        let path                 : String
        let marker               : String
        let wasCreatedByThisTrial: Bool

        var identity  : String { path }
        var provenance: String { "created by \(trial)" }
    }

    struct ObservedDirectory: Equatable, Sendable {

        let path           : String
        let exists         : Bool
        let isSymbolicLink : Bool
        let isDirectory    : Bool
        let marker         : String?
    }

    enum DirectoryOwnership: Equatable, Sendable {
        case ownedAndPresent
        case ownedAndAbsent
        case notAttested(String)
    }

    /// The outcome of releasing one resource, kept apart on purpose: a release
    /// that was verified afterwards, one that failed, and one nobody can tell.
    enum CleanupOutcome: Equatable, Sendable {

        case completedAndVerified(String)
        case failed(String)
        case unknownOrIncomplete(String)

        var status: String {
            switch self {
            case .completedAndVerified: return "completed_verified"
            case .failed              : return "failed"
            case .unknownOrIncomplete : return "unknown_incomplete"
            }
        }

        var detail: String {
            switch self {
            case .completedAndVerified(let value): return value
            case .failed(let value)              : return value
            case .unknownOrIncomplete(let value) : return value
            }
        }

        var isComplete: Bool {
            if case .completedAndVerified = self { return true }
            return false
        }
    }

    struct CleanupRecord: Codable, Equatable, Sendable {
        let kind      : String
        let trial     : String
        let identity  : String
        let provenance: String
        let status    : String
        let detail    : String
    }

    /// Whether this trial may signal the process it recorded.
    static func ownership(
        of provenance: ProcessProvenance,
        observed     : ObservedProcess?
    ) -> ProcessOwnership {

        guard let observed else {
            return .notAttested("the process could not be observed at all")
        }
        guard observed.processIdentifier == provenance.processIdentifier else {
            return .notAttested("the observation holds pid \(observed.processIdentifier),"
                                + " not the recorded \(provenance.processIdentifier)")
        }
        guard observed.isAttestedByLaunchHandle else {
            return .notAttested("pid \(provenance.processIdentifier) is no longer attested by"
                                + " its launch handle, so reuse cannot be excluded")
        }
        guard observed.launchToken == provenance.launchToken else {
            return .notAttested("the observed process does not carry the launch token of"
                                + " \(provenance.trial)")
        }
        if let started = observed.startedAtUptimeNanoseconds,
           started < provenance.launchedAtUptimeNanoseconds {
            return .notAttested("the observed process started before this trial launched anything")
        }
        return observed.isRunning ? .ownedAndRunning : .ownedAndGone
    }

    /// Whether this trial may remove the directory it recorded. The exact path
    /// and the marker are the attestation; a shared prefix or a name is not.
    static func ownership(
        of provenance: DirectoryProvenance,
        observed     : ObservedDirectory?
    ) -> DirectoryOwnership {

        guard provenance.wasCreatedByThisTrial else {
            return .notAttested("the directory was not created by \(provenance.trial)")
        }
        guard let observed, observed.exists else { return .ownedAndAbsent }
        guard observed.path == provenance.path else {
            return .notAttested("\(observed.path) is not the recorded \(provenance.path)")
        }
        guard !observed.isSymbolicLink else {
            return .notAttested("a symbolic link is not the directory this trial created")
        }
        guard observed.isDirectory else {
            return .notAttested("the recorded path is no longer a directory")
        }
        guard observed.marker == provenance.marker else {
            return .notAttested("the ownership marker inside the directory does not match")
        }
        return .ownedAndPresent
    }

    /// The observation a launch handle supports: while this process still holds
    /// the unreaped child, its pid cannot have been recycled underneath it.
    static func observe(_ handle: Process, provenance: ProcessProvenance) -> ObservedProcess {
        let carriesToken = (handle.arguments ?? []).contains { $0.contains(provenance.launchToken) }
        return ObservedProcess(
            processIdentifier       : handle.processIdentifier,
            launchToken             : carriesToken ? provenance.launchToken : nil,
            isRunning               : handle.isRunning,
            isAttestedByLaunchHandle: handle.processIdentifier == provenance.processIdentifier
        )
    }

    /// Reads the path itself and never through a link into somebody else's tree.
    static func observe(directory path: String) -> ObservedDirectory {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        guard let attributes else {
            return ObservedDirectory(path: path, exists: false, isSymbolicLink: false,
                                     isDirectory: false, marker: nil)
        }
        let type = attributes[.type] as? FileAttributeType
        let isDirectory = type == .typeDirectory
        var marker: String?
        if isDirectory {
            marker = try? String(
                contentsOf: URL(fileURLWithPath: path).appendingPathComponent(markerName),
                encoding  : .utf8
            )
        }
        return ObservedDirectory(
            path          : path,
            exists        : true,
            isSymbolicLink: type == .typeSymbolicLink,
            isDirectory   : isDirectory,
            marker        : marker
        )
    }

    /// The failure a trial must surface. The original error comes back unchanged,
    /// and an incomplete teardown travels beside it instead of replacing it.
    static func reportedFailure(
        original: any Error,
        residues: [CleanupRecord]
    ) -> (error: any Error, note: String?) {

        guard !residues.isEmpty else { return (original, nil) }
        let listed = residues.map { "\($0.kind) \($0.identity): \($0.status), \($0.detail)" }
        return (original, "teardown left \(residues.count) resource(s) unaccounted for: "
                          + listed.joined(separator: "; "))
    }

    /// Ledger is the chain of ownership of one trial, from the moment a resource
    /// exists to the outcome of its release.
    ///
    /// A claim is recorded before anything can fail, so a partial launch still
    /// leaves the provenance behind. A claim nobody settled stays a residue: the
    /// ledger never assumes an unobserved release succeeded.
    @MainActor
    final class Ledger {

        let trial: String

        private var order: [String] = []
        private var rows : [String: CleanupRecord] = [:]

        init(trial: String) { self.trial = trial }

        func claim(_ provenance: ProcessProvenance) {
            claim(provenance.kind, identity: provenance.identity,
                  provenance: provenance.provenance)
        }

        func claim(_ provenance: DirectoryProvenance) {
            claim(provenance.kind, identity: provenance.identity,
                  provenance: provenance.provenance)
        }

        func claim(_ kind: Kind, identity: String, provenance: String) {
            let key = "\(kind.rawValue)#\(identity)"
            if rows[key] == nil { order.append(key) }
            rows[key] = CleanupRecord(
                kind      : kind.rawValue,
                trial     : trial,
                identity  : identity,
                provenance: provenance,
                status    : "unknown_incomplete",
                detail    : "claimed by this trial and not settled yet"
            )
        }

        func settle(_ provenance: ProcessProvenance, outcome: CleanupOutcome) {
            settle(provenance.kind, identity: provenance.identity, outcome: outcome)
        }

        func settle(_ provenance: DirectoryProvenance, outcome: CleanupOutcome) {
            settle(provenance.kind, identity: provenance.identity, outcome: outcome)
        }

        func settle(_ kind: Kind, identity: String, outcome: CleanupOutcome) {
            let key = "\(kind.rawValue)#\(identity)"
            guard let claimed = rows[key] else {
                // An outcome with no claim behind it is itself a gap in the chain.
                order.append(key)
                rows[key] = CleanupRecord(
                    kind: kind.rawValue, trial: trial, identity: identity,
                    provenance: "settled without a prior claim",
                    status: "unknown_incomplete",
                    detail: "no claim preceded this outcome: \(outcome.detail)"
                )
                return
            }
            rows[key] = CleanupRecord(
                kind      : claimed.kind,
                trial     : claimed.trial,
                identity  : claimed.identity,
                provenance: claimed.provenance,
                status    : outcome.status,
                detail    : outcome.detail
            )
        }

        var records : [CleanupRecord] { order.compactMap { rows[$0] } }
        var residues: [CleanupRecord] { records.filter { $0.status != "completed_verified" } }

        /// True only when at least one resource was claimed and every claim ended
        /// verified. A trial that claimed nothing has proven nothing.
        var isComplete: Bool { !records.isEmpty && residues.isEmpty }

        /// A residue stops the plan: the next cell would run on a machine whose
        /// previous resources are unaccounted for.
        var mayStartAnotherTrial: Bool { isComplete }

        /// The `FOCUS_CLEANUP` payload the supervisor reads.
        ///
        /// It does not throw: a teardown report that could not be encoded is
        /// exactly the evidence that must not be lost, so the fallback stays
        /// readable and stays incomplete.
        func json() -> String {
            let report = CleanupReport(trial: trial, complete: isComplete, resources: records)
            guard let data = try? JSONEncoder().encode(report) else {
                return #"{"trial":"unencodable","complete":false,"resources":[]}"#
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// The shape of the `FOCUS_CLEANUP` line, kept out of the ledger so its
    /// encoding has nothing to do with the main actor the ledger runs on.
    fileprivate struct CleanupReport: Codable {
        let trial    : String
        let complete : Bool
        let resources: [CleanupRecord]
    }
}

nonisolated enum OwnBrowserFailure: Error, CustomStringConvertible {

    case neverAppeared
    case neverBecameReadable

    var description: String {
        switch self {
        case .neverAppeared:
            "the probe page never appeared among the windows of the browser this suite launched"
        case .neverBecameReadable:
            "the browser this suite launched never exposed its window through accessibility,"
                + " so nothing could move it onto the Virtual Display"
        }
    }
}
