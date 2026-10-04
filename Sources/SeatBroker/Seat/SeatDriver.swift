import AppKit
import CoreGraphics
import Foundation
import OSLog
import PrivateSymbols
import ScreenCaptureKit
import SeatCapture
import SeatCore
import SeatDriving
import SeatInput
import SeatSession
import TargetReader
import VirtualScreens
import WindowPlacement

/// The one wrapper around the seat driver: virtual display, adopted window,
/// window capture stream and input turns. Nothing else in the kit imports the
/// Seat session modules except `LivePreviewView` and `ActionExecutor`.
///
/// The display and the seat outlive the application in it: `adopt` takes one
/// window, `release` gives back every window the seat holds of that
/// application, since the host follows new ones, and the next application is
/// adopted on the same seat. Remaking them per application costs the measured
/// 364 ms of setup and 66 ms of teardown, and `SeatHost.makeSeat` answers
/// `seatLimitReached` for a second seat anyway, so the one seat is kept rather
/// than remade.
@MainActor
final class SeatDriver {
    /// The kit's own subsystem, so one `log stream` shows the lab's decisions
    /// next to the seat's own lines, which is where every diagnosis has come
    /// from so far.
    private static let log = Logger(subsystem: "dev.forte.AgentSeatKit", category: "Lab")

    /// The virtual display this driver's seat is made with, fixed for its life.
    let display: SeatDisplay

    private let host: SeatHost

    /// The host takes a window in native fullscreen: it leaves fullscreen with
    /// no activation and no focus taken, then moves like any other window.
    ///
    /// What that costs, as `SeatHostConfiguration` measured it: 36 to 100 ms
    /// of visible change once the window's Space is off screen, and an
    /// accessibility read per candidate per pass of the new-window watch. A
    /// window on the Space the person is looking at is refused rather than
    /// paying the 437 to 875 ms of display animation, and so is one whose
    /// `AXFullScreen` is unreadable or read only. With the transfer off, Safari
    /// fullscreen on its own Space was a window no worker could open.
    ///
    /// The release does not put it back into fullscreen:
    /// `restoresFullScreenOnRelease` stays off because re-entering takes the
    /// focus every time, measured, so the window comes home windowed.
    init(display: SeatDisplay = .standard) {
        self.display = display
        host = SeatHost(configuration: SeatHostConfiguration(
            display                   : VirtualDisplayConfiguration(
                pixelWidth : UInt32(display.pixelWidth),
                pixelHeight: UInt32(display.pixelHeight),
                refreshRate: display.refreshRate == 120 ? .high : .standard
            ),
            followsNewWindows         : true,
            restoresUserFocus         : true,
            transfersFullScreenWindows: true
        ))
    }
    private var seat: AgentSeat?
    private(set) var window: AdoptedWindow?
    private let preview = PreviewStreamController()

    /// Every target `borrowedTarget` lent since the last revocation. They are
    /// revoked before this driver adopts or releases anything, so no borrower
    /// can observe a window it was not lent: see `revokeBorrows`.
    private var lent: [SeatTarget] = []

    /// The subscription to the host's event channel, made once for the life of
    /// this driver: a host started again keeps the stream it published.
    private var hostWatcher: Task<Void, Never>?

    /// The subscription to the current seat's event channel. Every seat has a
    /// stream of its own, so a seat made in place of a failed one gets a new
    /// watcher and the one reading the replaced seat is cancelled.
    private var seatWatcher: Task<Void, Never>?

    /// What the seat did that a run's record has to be able to name, oldest
    /// first, taken by the session when it writes one.
    ///
    /// ponytail: capped by dropping the oldest, not by paging. A run that
    /// produces more than this many notable events has bigger news than the
    /// ones that fell off the front, and the log kept all of them anyway.
    private var notes: [String] = []

    /// What the seat answered for every window handed back by the last
    /// `release`, and empty while nothing has been released since the current
    /// adoption started.
    ///
    /// One outcome per window and not one for the whole handback: the seat
    /// follows new windows, so a release gives back several of them and they
    /// do not have to end the same way. The decisions read the set.
    private var lastReleases: [WindowReleaseOutcome] = []

    /// What the last release could not close, as the kit named it: the surfaces
    /// that are still out of place, each with the identity that survives a
    /// reused Window ID and the frame it is owed.
    private var lastObligations: [AssignmentObligation] = []

    /// Only logical proxy surfaces positively listed by the public WindowServer
    /// reader may later use a repeated public absence as destruction evidence.
    /// Remote helper content remains unreadable when its owner disappears.
    private var publiclyAttestedSurfaces: Set<WindowIdentity> = []

    /// The one outcome a sentence names: the first window that did not make it
    /// home, and otherwise the first one recorded. A failure is what is worth
    /// naming, and a set that went home reads the same through any member.
    private var reportedRelease: WindowReleaseOutcome? {
        lastReleases.first { !Self.isHome($0) } ?? lastReleases.first
    }

    /// The rectangle the monitor shapes itself by: the background display's
    /// bounds while the preview is pinned to the whole display, and otherwise
    /// the adopted window's frame on it, global top-left points.
    var windowFrame: CGRect? {
        if preview.isPinnedToDisplay, let bounds = host.sensing?.virtualDisplayBounds {
            return bounds
        }
        return preview.windowFrame ?? window?.reference.frame
    }

    /// True while the preview shows the whole background display rather than
    /// the adopted window. It says nothing about what the agent perceives:
    /// `observe` takes its own Still of the window either way.
    var previewShowsDisplay: Bool { preview.isPinnedToDisplay }

    /// Switches the preview between the whole background display and the
    /// adopted window, and answers which of the two it is now showing.
    ///
    /// It answers false rather than true when the display was asked for and
    /// there is none yet: the display is created with the host, on the first
    /// adoption, and before that there is nothing to watch.
    func setPreviewShowsDisplay(_ showsDisplay: Bool) -> Bool {
        guard showsDisplay, let displayID = host.displayID,
              let bounds = host.sensing?.virtualDisplayBounds
        else {
            preview.pin(to: nil, pixelSize: .zero)
            return false
        }
        let scale = displayScale
        preview.pin(
            to: .display(displayID),
            pixelSize: CGSize(width: bounds.width * scale, height: bounds.height * scale)
        )
        return true
    }

    /// True while a window the seat took is not confirmed back on the person's
    /// display: a rollback the seat could not finish, or a release that refused
    /// or left the window on the background display.
    ///
    /// It is the precondition for terminating the window's owner. A window the
    /// seat has not finished with is an obligation in its restitution ledger
    /// that killing the owner makes impossible to discharge, and `release`
    /// returning is not proof on its own: it answers with an outcome, and two
    /// of the four say the window is still out there.
    var hasUnrestoredWindow: Bool {
        if seat?.hasPendingWindowRestorations == true { return true }
        if !lastObligations.isEmpty { return true }
        return Self.leavesWindowUnrestored(lastReleases)
    }

    /// Whether a handback left any window the seat took still out there. Every
    /// window is asked and one that did not come home decides for the set:
    /// terminating the owner then strands an obligation nothing can settle,
    /// and the other windows having made it home does not make that safe.
    static func leavesWindowUnrestored(_ outcomes: [WindowReleaseOutcome]) -> Bool {
        outcomes.contains { !isHome($0) }
    }

    /// Whether this outcome says the window is no longer the seat's to give
    /// back: at its original frame, or gone. The other two leave it held.
    static func isHome(_ outcome: WindowReleaseOutcome) -> Bool {
        switch outcome {
        case .returned, .vanished, .returnsWhenShown: true
        case .refused, .leftOnVirtualDisplay:         false
        }
    }

    static func setResearchOptIn(_ enabled: Bool) {
        FacilityGate.researchOptInForUnvalidatedBuilds = enabled
    }

    static func capabilities() -> CapabilityReport {
        let entries = Facility.all.map { facility -> CapabilityEntry in
            let gate = FacilityGate.current(facility: facility)
            let detail: String
            switch gate.readiness {
            case .validated(let build):
                detail = "validated on \(build)"
            case .unvalidated(let scope):
                detail = "unvalidated build (\(scope))" + (gate.mayAct ? ", research opt-in" : "")
            case .unavailable(let reason):
                detail = "unavailable: \(reason)"
            case .permissionMissing(let kind):
                detail = "permission missing: \(kind.rawValue)"
            }
            return CapabilityEntry(name: facility.name, ready: gate.mayAct, detail: detail)
        }
        return CapabilityReport(entries: entries)
    }

    /// Each grant the seat needs, in the order System Settings lists them, and whether it is held.
    static func grants() -> [DesktopGrant] {
        [
            ("Accessibility", PermissionKind.accessibility),
            ("Keyboard and Mouse Control", .postEvent),
            ("Screen Recording", .screenRecording),
        ].map { name, kind in
            DesktopGrant(
                name     : name,
                isGranted: Permissions.preflight(kind),
                kind     : kind
            )
        }
    }

    /// This Mac's build, validated when the bundled ledger has an entry for it.
    static func buildValidation() -> BuildValidation {
        let identity = BuildIdentity.current
        let ledger   = try? Ledger.bundled()
        return BuildValidation(
            build         : identity.osVersion,
            productVersion: identity.productVersion,
            isValidated   : ledger?.entry(for: identity) != nil
        )
    }

    /// The grants in the order they are asked for.
    private static let grantOrder: [PermissionKind] = [.accessibility, .postEvent, .screenRecording]

    /// Asks for the first grant still missing, and only that one, and answers whether every grant
    /// is there. Asking for all three at once raised three system prompts together and macOS showed
    /// one of them: the others were lost, and a person was left without Screen Recording and no way
    /// to tell. The next call asks for the next grant.
    @discardableResult
    static func requestMissingPermissions() -> Bool {
        guard let kind = Permissions.firstMissing(of: grantOrder) else { return true }
        request(kind)
        return false
    }

    /// Asks for one grant: its system prompt the first time, and its pane of System Settings after
    /// that. macOS shows each prompt once per app, so a request after the first would show nothing,
    /// and the pane is where the person can still turn it on.
    static func request(_ kind: PermissionKind) {
        let key = "mecum.permission.prompted.\(kind.rawValue)"
        guard !UserDefaults.standard.bool(forKey: key) else {
            openSettings(for: kind)
            return
        }
        UserDefaults.standard.set(true, forKey: key)
        Permissions.request(kind)
    }

    /// Opens the Privacy pane of the first grant the driver is missing. False
    /// when every grant is there, so a caller can leave the button out.
    @discardableResult
    static func openPermissionSettings() -> Bool {
        guard let kind = Permissions.firstMissing(of: grantOrder) else { return false }
        return openSettings(for: kind)
    }

    /// Opens the Privacy pane of System Settings where `kind` is turned on.
    @discardableResult
    static func openSettings(for kind: PermissionKind) -> Bool {
        // Post Event lives in the Accessibility pane, next to the grant that
        // lets an app control the computer.
        let pane = switch kind {
        case .accessibility, .postEvent: "Privacy_Accessibility"
        case .screenRecording:           "Privacy_ScreenCapture"
        }
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?" + pane
        ) else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// True when Screen Recording is granted according to ScreenCaptureKit but
    /// this process still reads it as missing: TCC caches that grant per
    /// process, so only a relaunch makes capture work.
    static func screenRecordingNeedsRelaunch() async -> Bool {
        guard !Permissions.preflight(.screenRecording) else { return false }
        return (try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)) != nil
    }

    /// Points to pixels for the background display, which is the only unit a
    /// capture buffer can be measured in.
    ///
    /// It used to be a hardcoded 2, and on this display that is wrong twice
    /// over: the seat kit creates the Virtual Display with `hiDPI` off, so one
    /// point is one pixel there. A buffer twice the window in each direction
    /// leaves the window drawn at its own size in the top left corner of a
    /// frame four times its area, with black around the rest, which is what the
    /// preview showed for every window it was given. The screen the display
    /// publishes is the one thing that knows the answer, and when it publishes
    /// none the answer is 1, never 2: an unscaled buffer shows the window
    /// whole, and a doubled one cannot.
    ///
    /// It is read per adoption rather than remembered: the display is remade
    /// across a host restart and the person can change its resolution under it.
    private var displayScale: CGFloat {
        guard let displayID = host.displayID,
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                      .uint32Value == displayID
              })
        else { return 1 }
        return screen.backingScaleFactor
    }

    /// Attests the window, brings the display and fence up on the first call,
    /// moves the window onto the display and starts a capture stream of it.
    func adopt(_ target: TargetWindow) async throws {
        guard window == nil else {
            throw SeatBrokerError.driver(
                "The seat is still holding a window; release it before adopting another.")
        }
        await revokeBorrows()
        guard let server = WindowServerProbe.geometry(of: target.windowNumber),
              server.identity != nil, server.processID == target.pid
        else { throw SeatBrokerError.windowNotAttested(windowNumber: target.windowNumber) }

        lastReleases    = []
        lastObligations = []
        // Kept outside the transaction because a failure has to name them and
        // the seat writes an adoption report for only some of the failures.
        var requested: CGSize?
        var displayBounds: CGRect?
        // What the preview would be started with, filled in by the adoption and
        // acted on only once the adoption has come through.
        var previewRequest: (identity: WindowIdentity, frame: CGRect, pixelSize: CGSize)?
        do {
            // The window's own frame, not the window server's. Stage Manager
            // publishes a stashed window to the server as its strip thumbnail:
            // measured on 26A428, a 1291x949 pt window reads as 164x180 pt at
            // x = -227, off the left edge of the screen, while the window
            // itself still reports the full frame. Adopting the thumbnail
            // makes the seat centre the wrong rectangle and then wait for a
            // frame that size, so the placement can never be confirmed:
            // `adopt` fails with `placementNotConfirmed` after two seconds and
            // rolls the window back. The frame has to come from the window,
            // which is what `AgentSeat.adopt` asks the consumer for.
            let reference: WindowReference
            switch try await Self.agreeingFrame(within: .milliseconds(600),
                                                read: { try WindowRelocator.frame(of: server) }) {
            case .agreed(let frame):
                reference = server.replacingFrame(frame)
            case .unreadable:
                // The window answers no frame of its own, which is what the
                // window server's reading has always been the fallback for.
                reference = server
            case .stillMoving(let first, let last):
                throw SeatBrokerError.driver(
                    "The window was still resizing when the seat tried to take it: it read "
                        + "\(Int(first.width))×\(Int(first.height)) pt and then "
                        + "\(Int(last.width))×\(Int(last.height)) pt, with no two readings "
                        + "agreeing. Let it settle and try again.")
            }
            requested = reference.frame.size

            let seat = try await liveSeat()
            guard let bounds = host.sensing?.virtualDisplayBounds else {
                throw SeatBrokerError.driver(
                    "The background display started but published no bounds.")
            }
            displayBounds = bounds
            // A window larger than the background display is the seat's to
            // adapt: it fits it, and returns the found frame on the release.

            // Which recipe this one application is driven with. A process that
            // answers nothing is the unmeasured case, which is the default.
            let running = NSRunningApplication(processIdentifier: target.pid)
            let choice = TargetPlatform.chosen(
                bundleURL       : running?.bundleURL,
                bundleIdentifier: running?.bundleIdentifier
            )
            Self.log.info("""
                \(running?.localizedName ?? "pid \(target.pid)", privacy: .public) \
                (\(running?.bundleIdentifier ?? "no bundle identifier", privacy: .public)) \
                is driven with \(choice.platformName, privacy: .public): \
                \(choice.reason, privacy: .public)
                """)

            var adopted = try await seat.adopt(
                reference,
                platform: choice.platform(for: running?.bundleIdentifier),
                title   : target.title
            )
            // Recorded before staging: `stage` throws with the window already
            // adopted, and `release` skips a window this driver never recorded.
            window = adopted
            // Stage Manager stashes whatever arrives on the display it owns.
            // A stashed window is a thumbnail, and input aimed at a thumbnail
            // lands nowhere, so it goes back on stage before anything else.
            if !seat.isStaged(adopted) { adopted = try await seat.stage(adopted) }
            window = adopted
            guard let identity = adopted.reference.identity else {
                throw SeatBrokerError.windowNotAttested(windowNumber: target.windowNumber)
            }
            let scale = displayScale
            previewRequest = (
                identity : identity,
                frame    : adopted.reference.frame,
                pixelSize: CGSize(width: adopted.reference.frame.width * scale,
                                  height: adopted.reference.frame.height * scale)
            )
        } catch {
            // The adoption report has to be read before anything else runs on
            // the seat: it is what turns "not confirmed" into a diagnosis.
            let adoption = seat?.lastAdoptionFailure
            // The display and the seat stay up: the seat rolled its own adoption
            // back, and what is left to undo is whatever this call did take.
            await release()
            if let error = error as? SeatBrokerError { throw error }
            let sentence = SeatErrorMapper.message(for: error)
            // A failed `stage` keeps no adoption report: the rollback that
            // writes one never ran. The evidence is still here all the same.
            guard let adoption else {
                guard let requested, let displayBounds else {
                    throw SeatBrokerError.driver(sentence)
                }
                throw SeatBrokerError.driver(sentence + " " + SeatErrorMapper.detail(
                    requestedSize: requested,
                    bounds: displayBounds,
                    observed: SeatErrorMapper.lastObservedFrame(of: error),
                    restoration: reportedRelease
                ))
            }
            throw SeatBrokerError.driver(sentence + " " + SeatErrorMapper.detail(of: adoption))
        }

        // The preview is not the adoption, and it is started outside the
        // transaction for exactly that reason: it used to sit in the same `do`,
        // so a capture that failed to start ran `release()` and handed the
        // window back. The window is taken either way. What a failure here
        // costs is the picture, which suspends itself and comes back on its own
        // bounded recovery, and never a coordinate: input still waits for a
        // fresh observation, which is `observe` and not this stream.
        guard let previewRequest else { return }
        do {
            try await preview.start(
                identity : previewRequest.identity,
                frame    : previewRequest.frame,
                pixelSize: previewRequest.pixelSize
            )
        } catch {
            keep("The window was taken and the live preview did not start: "
                + SeatErrorMapper.message(for: error)
                + " The seat is holding the window and the agent still perceives it; "
                + "the picture is being tried again.")
        }
    }

    /// Why the person has no live picture, and nil while they have one or none
    /// was asked for. It never says the application was lost: a preview that
    /// failed is a preview that failed, and the seat is still holding the
    /// window through all of it.
    var previewSuspension: String? { Self.suspensionSentence(preview.availability) }

    /// The sentence for one availability, apart from the controller so the
    /// rule that a lost picture is never a lost application can be asserted.
    static func suspensionSentence(_ availability: PreviewAvailability) -> String? {
        switch availability {
        case .idle, .live:            nil
        case .suspended(let why):
            "The live preview stopped and is being started again: \(why) "
                + "The seat is still holding the window."
        case .unavailable(let why):
            "The live preview could not be started and is no longer being retried: \(why) "
                + "The seat is still holding the window."
        }
    }

    /// What repeated readings of one window's own frame came to.
    enum FrameAgreement: Equatable {

        /// Two readings in a row agreed, within the kit's placement tolerance.
        case agreed(CGRect)

        /// The window answered no frame at all, which is not a disagreement.
        case unreadable

        /// The bound expired with no two readings agreeing: the first reading
        /// and the last one, which is what a sentence names.
        case stillMoving(CGRect, CGRect)
    }

    /// Reads `read` until two readings in a row agree, or `limit` expires.
    ///
    /// The comparison is the kit's own `framesMatch`, so "agreeing" here means
    /// what it means everywhere else in the seat: both rectangles usable and
    /// within the placement tolerance. Two readings taken while a window is
    /// moving do not match, which is the whole point of asking twice.
    ///
    /// A window that has just been launched, restored or zoomed is still
    /// resizing, and one reading of it can be any frame along the way. The seat
    /// is then asked to confirm a rectangle the window is already leaving, and
    /// the failure it reports names a placement rather than the resize behind
    /// it, which is the diagnosis this exists to stop losing.
    ///
    /// A reading that answers nil ends it as `unreadable` rather than being
    /// retried: nil is the window exposing no frame of its own, and waiting
    /// does not change that, while the caller already has the window server's
    /// reading to fall back to.
    ///
    /// A reading that throws is not caught here either: an accessibility read
    /// that failed is the adoption's own failure and has a sentence of its own.
    ///
    /// It takes the reading as a closure so the rule can be driven by a test
    /// with a scripted sequence: nothing here needs a window.
    static func agreeingFrame(
        within limit: Duration,
        pause       : Duration = .milliseconds(60),
        read        : () throws -> CGRect?
    ) async throws -> FrameAgreement {
        let deadline = ContinuousClock.now.advanced(by: limit)
        var first: CGRect?
        var previous: CGRect?
        repeat {
            guard let reading = try read() else { return .unreadable }
            if first == nil { first = reading }
            if let previous, VirtualWindowPlacementCheck.framesMatch(previous, reading) {
                return .agreed(reading)
            }
            previous = reading
            try? await Task.sleep(for: pause)
        } while ContinuousClock.now < deadline
        return .stillMoving(first ?? .zero, previous ?? .zero)
    }

    /// One frame and the authority that binds a decision to that exact surface,
    /// geometry and observation barrier. Mecum owns retries and qualification.
    func observe() async throws -> SeatObservationDelivery {
        guard let seat, window != nil else { throw SeatBrokerError.sessionClosed }
        switch await seat.observe() {
        case .success(let delivery):
            preview.follow(delivery)
            return delivery
        case .failure(let reason):
            let sentence = SeatErrorMapper.message(for: reason)
            if case .suspended = reason { throw SeatBrokerError.observationSuspended(sentence) }
            throw SeatBrokerError.driver(sentence)
        }
    }

    /// A `SeatTarget` that borrows this driver's host and seat, so the Engine's roles act on the
    /// window adopted here. This driver stays the owner: the target never starts or stops the host
    /// and never releases a window, and it is valid only while the current adoption lasts: the
    /// next `adopt`, `release` or `stop` revokes it.
    ///
    /// Each call makes a new target with an observation of its own. The seat keeps one outstanding
    /// observation, so `observe` here or on another borrow supersedes it and its next Command is
    /// refused before any event. Every observation the borrow takes moves the preview, as one taken
    /// by `observe` does, so the monitor shows the dialog the engine reads. Throws `sessionClosed`
    /// while there is no seat or no window.
    func borrowedTarget() throws -> SeatTarget {
        guard let seat, window != nil else { throw SeatBrokerError.sessionClosed }
        let target = SeatTarget(
            borrowing: host,
            seat     : seat
        ) { [weak self] delivery in
            self?.preview.follow(delivery)
        }
        lent.append(target)
        return target
    }

    /// Ends every borrow lent since the last revocation. A revoked target has
    /// no seat, so it refuses as `notAdopted` rather than observing: a session
    /// parked warm and handed to the next worker must not let an earlier
    /// borrower read that worker's window as its own. Idempotent.
    private func revokeBorrows() async {
        let revoked = lent
        lent = []
        for target in revoked { await target.stop() }
    }

    func attach(_ layer: MonitorLayer) { preview.attach(layer) }
    func detach(_ layer: MonitorLayer) { preview.detach(layer) }

    func windowTitle(for recipient: WindowIdentity) -> String {
        seat?.adoptedWindows.first {
            $0.reference.identity == recipient
        }?.title ?? ""
    }

    func acquireTurn() async throws -> Turn {
        guard let seat else { throw SeatBrokerError.sessionClosed }
        return try await mapped { try await seat.acquire() }
    }

    func send(_ input: ActionInput, observation: SeatObservationReference,
              turn: Turn) async throws -> InputReceipt {
        guard let seat, window != nil else { throw SeatBrokerError.sessionClosed }
        return try await mapped {
            switch input {
            case .command(let command):
                return try await seat.send(command, observation: observation, turn: turn)
            case .shortcut(let shortcut):
                return try await seat.send(shortcut, observation: observation, turn: turn)
            }
        }
    }

    /// MenuChoice is what one whole contextual menu interaction came to.
    struct MenuChoice {
        /// The sentence the step history carries: the item that was chosen, or
        /// the refusal in its own words.
        let note: String

        /// Every event the interaction posted, the right click that opened the
        /// menu included. None of them is the caller's to confirm: the seat
        /// witnessed all of them itself.
        let eventCount: Int
    }

    /// Opens the contextual menu at `location`, chooses the item titled `item`
    /// inside it and answers what the step is worth saying about.
    ///
    /// The closing is `withContextMenu`'s and there is deliberately no second
    /// one here. A menu left open is a thrown failure in the kit and never a
    /// silent receipt, so a closing or a retry of this driver's own could only
    /// race the guarantee that already exists.
    ///
    /// It answers no Receipt on purpose, which is the one way this action
    /// differs from `send`. Every other Command is the caller's to confirm
    /// because the seat cannot see its effect and the caller can. These two the
    /// seat saw itself: the menu appeared, the menu closed. So the kit keeps
    /// none of them outstanding, this action leaves `endTurn` nothing to answer
    /// for, and the Turn is released having confirmed nothing. The events are
    /// still counted, because a count is a measurement and not a permission,
    /// and what the chosen item did inside the target is answered where every
    /// other action's effect is, on the after-frame.
    func chooseFromContextMenu(_ item: String, openedAt location: InputLocation,
                               observation: SeatObservationReference,
                               turn: Turn) async throws -> MenuChoice {
        guard let seat, window != nil else { throw SeatBrokerError.sessionClosed }
        let parent = observation.recipient
        var note = "The contextual menu opened and was closed with nothing read inside it."
        let outcome = try await mapped {
            try await seat.withContextMenu(openedAt: location, observation: observation, turn: turn) { interaction in
                note = await Self.choose(item, in: interaction, openedFrom: parent)
                // The note quotes the menu's own titles, which are the app's content (§15.5).
                Self.log.info("contextual menu, chose: \(note, privacy: .private)")
            }
        }
        return MenuChoice(
            note: note,
            eventCount: outcome.insideMenu.reduce(outcome.opening.eventCount) { $0 + $1.eventCount }
        )
    }

    /// The body of one interaction: read the menu that is up, match the title
    /// to a row, and post the click against an observation of the menu's own
    /// surface, which is the only reference that click is admitted against.
    ///
    /// The reading is asked for by the **parent's** Window ID and never the
    /// menu's. An AppKit contextual menu is an `AXMenu` child of the window it
    /// was opened from, and the menu's own window is in no application's
    /// `AXWindows` at all, so naming it reads every menu as unreadable.
    private static func choose(_ item: String, in interaction: SeatMenuInteraction,
                               openedFrom parent: WindowIdentity) async -> String {
        let reading: ObservedContextMenu
        do {
            reading = try WindowReader.contextMenu(processID: parent.processID,
                                                   windowNumber: parent.windowNumber)
        } catch {
            return "The contextual menu is open and the accessibility reading of it failed: "
                + "\(error). Nothing was chosen."
        }
        let (chosen, note) = choice(of: item, in: reading)
        guard let chosen else { return note }

        switch await interaction.observe() {
        case .failure(let refusal):
            return "\"\(item)\" is in this contextual menu and the click could not be aimed at it: the "
                + "menu's own surface was not observable. \(SeatErrorMapper.message(for: refusal)) "
                + "Nothing was clicked."
        case .success(let delivery):
            let screen = ContextMenuChoice.screenPoint(chosen, readAt: interaction.menu.frame,
                                                       observedAt: delivery.geometry.window.frame)
            guard let aimed = InputLocation(screenPoint: screen, observedIn: delivery.geometry) else {
                return "\"\(item)\" was read at a point the observed menu does not contain, so no click "
                    + "was posted: the reading and the observation describe different rectangles."
            }
            do {
                _ = try await interaction.send(.click(aimed, button: .left), observation: delivery.reference)
                return note
            } catch {
                return "\"\(item)\" is in this contextual menu and the click on it was refused: "
                    + SeatErrorMapper.message(for: error)
            }
        }
    }

    /// What the body decides from its reading alone: the point to aim at, in
    /// the coordinates the reader answered with, or the sentence the step
    /// history carries in place of a click.
    ///
    /// It is apart from the interaction because the interaction needs a live
    /// seat and this does not, and because a refusal here is the whole step:
    /// no point means nothing at all is posted inside the menu.
    static func choice(of item: String, in reading: ObservedContextMenu) -> (point: CGPoint?, note: String) {
        switch ContextMenuChoice.choosing(item, in: reading) {
        case .click(let point): (point, "Chose \"\(item)\" in the contextual menu.")
        case .refused(let why): (nil, why)
        }
    }

    /// Confirms every receipt in send order, then releases the turn.
    func endTurn(_ turn: Turn, receipts: [InputReceipt], confirmation: EffectConfirmation) throws {
        guard let seat else { throw SeatBrokerError.sessionClosed }
        try mapped {
            for receipt in receipts {
                try seat.confirm(receipt, confirmation)
            }
            try seat.release(turn)
        }
    }

    /// Every Seat error that leaves this driver leaves it as one sentence: the
    /// kit answers in fields, and `NSError` renders its enums as a bare case
    /// number that names nothing.
    private func mapped<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() }
        catch let error as SeatBrokerError { throw error }
        catch { throw driverError(error) }
    }

    private func mapped<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let error as SeatBrokerError { throw error }
        catch { throw driverError(error) }
    }

    /// A pause held by focus recovery carries the recovery's own report with it.
    /// The sentence alone says input is paused; the report says whether the
    /// request went out, what the kit refused on and where it was aiming, which
    /// is the difference between a wait that will end and one that will not.
    private func driverError(_ error: any Error) -> SeatBrokerError {
        let reasons = SeatErrorMapper.pauseReasons(of: error)
        var sentence = SeatErrorMapper.message(for: error)
        // Every stop is reported with whatever the recovery was doing, because
        // a stop and a recovery in flight are rarely unrelated. Only the two
        // that end by themselves are worth waiting out.
        if !reasons.isEmpty, let report = seat?.lastFocusRecovery {
            sentence += " " + SeatErrorMapper.detail(of: report)
        }
        return SeatErrorMapper.mayDecideAgain(reasons)
            ? .inputPaused(sentence)
            : .driver(sentence)
    }

    /// Waits while a focus recovery is still in flight, and answers whether
    /// input is admissible again, together with the recovery's own report.
    ///
    /// A restoration that is verified takes milliseconds, and the Command that
    /// met the closed gate posted nothing. Waiting it out is the difference
    /// between a run that perceives the dialog it just opened and a run that
    /// dies on a stop that was already over. It waits and nothing more: the
    /// caller observes and decides again, and no Command is replayed here.
    ///
    /// The detail comes back on the recovery that succeeded as well as the one
    /// that did not, because a recovery that worked is where the whole cost of
    /// the swap is measured and it was the one outcome nothing reported.
    ///
    /// **`waitingForUser` is waited out, and that is the whole fix.** It used
    /// to end this call at once, which on the measured path meant giving up
    /// 254 ms in: the kit's verification window is 250 ms, a request that has
    /// not produced two agreeing readings inside it is published as
    /// `waitingForUser`, and ADR 0012 in the kit records the focus arriving
    /// after that window all the same. The kit does not stop at the window
    /// either: the recovery re-verifies on every activation notification and on
    /// the seat's heartbeat, and publishes `restored` whenever the readings do
    /// agree. So the outcome at 254 ms is not a verdict, it is the state of an
    /// answer still coming, and the only honest end of the wait is the caller's
    /// own limit.
    ///
    /// **The limit belongs to the caller and is reasoned where it is passed.**
    /// Only `restored` and `userTookControl` admit input, because only those
    /// two say the keyboard is somewhere the seat may act around.
    /// `cancelled` and `unrecoverable` stay terminal: nothing is coming, the
    /// episode is over, and waiting on either would burn the caller's whole
    /// budget for a report that is already final.
    ///
    /// **It is an active wait and not a poll of a fixed length.** Three things
    /// end it and each of them is a reading of the kit: the gate admitting
    /// again, a terminal outcome, and the caller's own deadline. The gate is
    /// asked as well as the report because a recovery that ends without
    /// publishing again would otherwise be waited out to the last millisecond
    /// of a limit it stopped needing. What it answers with is the same reading
    /// the badge shows, so the sentence a run records and the state the person
    /// is looking at cannot disagree.
    func waitWhileRecoveringFocus(within limit: Duration)
        async -> (admitted: Bool, cause: SeatActivity, detail: String?) {
        guard seat != nil else { return (false, .noSeat, nil) }
        let deadline = ContinuousClock.now.advanced(by: limit)
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return (false, activity, focusRecoveryDetail()) }
            let reading = activity
            if reading == .ready, seat != nil {
                return (true, reading, focusRecoveryDetail())
            }
            // A prior `.restored` is historical evidence. Admission belongs to
            // the current kit gate, which may still be held by containment,
            // a deliberate stop, or another pause.
            guard reading == .recovering || reading == .waitingForUser else {
                return (false, reading, focusRecoveryDetail())
            }
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch is CancellationError {
                return (false, activity, focusRecoveryDetail())
            } catch {
                return (false, activity, focusRecoveryDetail())
            }
        }
        return (false, activity, focusRecoveryDetail())
    }

    /// Whether the surface a Command was aimed at is gone.
    ///
    /// It is read from the window server by identity and never from the
    /// picture: a background that repainted is not a dialog that closed, which
    /// is the reading that let an ineffective Cancel be reported as done.
    /// Comparing the whole identity rather than the Window ID is what makes an
    /// id the system handed out again answer "gone" instead of "still there".
    ///
    /// The window identity facility is the one `adopt` already attested this
    /// window through, so a seat holding a window has it working.
    enum SurfacePresence: Equatable {
        case present
        case withdrawn
        case destroyed
        case replaced
        case unreadable
    }

    func notePublicSurface(_ identity: WindowIdentity) {
        guard WindowServerProbe.geometry(of: identity.windowNumber)?.identity == identity else { return }
        publiclyAttestedSurfaces.insert(identity)
    }

    func surfacePresence(_ identity: WindowIdentity) -> SurfacePresence {
        let logical = seat?.reconcileLogicalClosure(of: identity) ?? .unreadable
        return Self.surfacePresence(
            identity,
            logical: logical,
            reading: WindowServerProbe.identityReading(
                of: identity.windowNumber,
                wasPubliclyAttested: publiclyAttestedSurfaces.contains(identity)
            )
        )
    }

    static func surfacePresence(
        _ identity: WindowIdentity,
        logical: LogicalSurfacePresence,
        reading: WindowServerProbe.IdentityReading
    ) -> SurfacePresence {
        switch logical {
        case .present:   return .present
        case .withdrawn: return .withdrawn
        case .destroyed: return .destroyed
        case .replaced:  return .replaced
        case .unreadable:
            return surfacePresence(identity, reading: reading)
        }
    }

    static func surfacePresence(
        _ identity: WindowIdentity,
        reading: WindowServerProbe.IdentityReading
    ) -> SurfacePresence {
        switch reading {
        case .present(let current): return current == identity ? .present : .replaced
        case .absent: return .destroyed
        case .unreadable: return .unreadable
        }
    }

    func surfaceIsGone(_ identity: WindowIdentity) -> Bool {
        switch surfacePresence(identity) {
        case .withdrawn, .destroyed, .replaced: true
        case .present, .unreadable: false
        }
    }

    /// What the seat is doing, as the kit answers it: its own state, its focus
    /// recovery and the causes holding its gate closed, with nothing of this
    /// lab's mixed in.
    var activity: SeatActivity {
        SeatActivity.reading(state: seat?.state,
                             recovery: seat?.lastFocusRecovery?.outcome,
                             pauses: seat?.inputPauseReasons ?? [])
    }

    /// Every cause the gate is holding input back for, as one sentence, and
    /// nil while it holds none.
    var inputHold: String? { SeatErrorMapper.heldInput(seat?.inputPauseReasons ?? []) }

    /// What one recovery outcome settles, and nil for the two that settle
    /// nothing yet and are waited on.
    ///
    /// No recovery at all admits: there is nothing to wait for and the pause
    /// the caller met was about something else.
    static func admission(of outcome: UserFocusRecoveryReport.Outcome?) -> Bool? {
        switch outcome {
        case .restoring, .waitingForUser:  nil
        case .restored, .userTookControl:  true
        // Both are final and neither admits: `unrecoverable` is the kit saying
        // a closure transition spent its whole budget and will not ask again.
        case .cancelled, .unrecoverable:   false
        case nil:                          false
        }
    }

    private func focusRecoveryDetail() -> String? {
        seat?.lastFocusRecovery.map { SeatErrorMapper.detail(of: $0) }
    }

    /// Gives every window the seat holds of the adopted application back to the
    /// person's seat and leaves the display and the seat up for the next one.
    ///
    /// After this the seat holds nothing of that application, which is the
    /// precondition for quitting its process: a window the seat still holds is
    /// an obligation in its restitution ledger that terminating the owner
    /// makes impossible to discharge.
    ///
    /// It is one call into the kit and no longer a loop over the windows this
    /// driver can see. The seat holds three registers of its own — the Adopted
    /// Windows, the rollbacks a failed adoption still owes and the members it
    /// moved in without adopting — and the consumer can reach exactly one of
    /// them. Returning that one and being refused over the other two is how a
    /// single leftover window kept the assignment bound and stopped the person
    /// moving on to a second application.
    func release() async {
        await revokeBorrows()
        await preview.stop()
        self.window = nil
        // Kept, not discarded, and one per window: "release returned" and "the
        // window went home" are two facts, and a termination waits on all.
        guard let report = await seat?.releaseAssignment() else {
            lastReleases    = []
            lastObligations = []
            return
        }
        lastReleases    = report.windows.keys.sorted().compactMap { report.windows[$0] }
        lastObligations = report.obligations
        // `hasUnrestoredWindow` already stops the quit; this is what names the
        // window and says how to finish it by hand.
        if let sentence = SeatErrorMapper.obligations(report.obligations) { keep(sentence) }
    }

    /// Gives the assigned application back, so the next `adopt` may hand a
    /// different instance over. Answers nil when the seat let it go and the
    /// refusal's own sentence when it kept it.
    ///
    /// It goes after `release`, which is now the call that ends the assignment
    /// as well: what is left here is the case where nothing released it, and
    /// the refusal of a seat that is still in the middle of something.
    ///
    /// What the release could not put back is **not** answered here. That is a
    /// stranded window and not an application the seat is still holding: it
    /// stops the quit through `hasUnrestoredWindow`, which already says so in
    /// the person's own words, and it is named in the run's notes.
    ///
    /// `applicationNotAssigned` is not reported: it says the seat was never
    /// entrusted with an application, which on the finishing path is a seat
    /// that adopted nothing and not a failure to tell anybody about.
    func releaseAssignedApplication() -> String? {
        do {
            try seat?.releaseAssignedApplication()
            return nil
        } catch SessionFailure.applicationNotAssigned {
            return nil
        } catch {
            return SeatErrorMapper.message(for: error)
        }
    }

    /// Closes the seat's input gate and nothing else, so a panic stops Commands
    /// at the moment it is pressed rather than when the teardown finally gets
    /// to run. A seat that was never made has nothing to close.
    func stopAdmittingCommands() {
        seat?.stopAdmittingCommands()
    }

    /// Releases whatever is held, takes the background display down and answers
    /// the one thing the teardown leaves a person to do.
    ///
    /// The report used to be discarded. It is the only place that says which
    /// windows the host could not put back, and a teardown that stranded a
    /// window while the closing sentence said everything went home is the one
    /// case where that sentence is a lie. The whole report goes to the log and
    /// `windowsNotReturned` comes back for the sentence.
    func stop() async -> String? {
        await release()
        // After `release` because that is the one that gives the windows back,
        // and explicit because a release no longer takes the preview down on
        // its own: a pin to the display survives a handover and must not
        // survive the host that owns the display.
        await preview.tearDown()
        seat = nil
        let report = await host.stop()
        Self.log.info("""
            teardown: display removed \(report.displayRemoved, privacy: .public), \
            fence released \(report.fenceReleased, privacy: .public), \
            main display restored \(report.mainDisplayRestored, privacy: .public), \
            topology \(String(describing: report.topologyRestoration), privacy: .public), \
            windows \(String(describing: report.windows), privacy: .public), \
            removal \(report.removalNanoseconds / 1_000_000, privacy: .public) ms
            """)
        // The watchers are left running: the teardown's own events are still
        // coming. The seat's is cancelled only when a new seat replaces it.
        return SeatErrorMapper.teardown(report)
    }

    /// The host and the seat are brought up on first use and then kept: one
    /// host per process, one seat per host, and `makeSeat` refuses the second.
    ///
    /// A seat that has failed is the exception, and it is torn down and made
    /// again here. `failed` is terminal: the seat refuses every adoption from
    /// then on, and keeping it handed the same refusal to every later session
    /// of the process until the app was restarted. `makeSeat` refuses a second
    /// seat while the host holds one, so the whole host goes down with it,
    /// through the same `stop` a closing session uses, and comes back from
    /// `off`. What that teardown could not put back goes to the run's notes.
    ///
    /// Every adoption gets its seat here, which is why the rule lives here: a
    /// warm session from the queue and a session reopening an application go
    /// through the same line.
    /// Brings the host and the seat up as the next `adopt` would, and adopts nothing, so an open
    /// whose own first step has an effect (a window it opens) takes it only once the seat is ready.
    /// A seat holding a window is up already and is left alone: remaking a failed one here would
    /// take that window home outside the release that has to account for it, so `adopt` does it.
    func prepareSeat() async throws {
        guard window == nil else { return }
        _ = try await liveSeat()
    }

    private func liveSeat() async throws -> AgentSeat {
        if let seat {
            guard seat.state == .failed else { return seat }
            Self.log.info("the seat failed: taking the host down to make a new seat")
            if let sentence = await stop() { keep(sentence) }
            // The failed seat's releases are named in the notes already, and
            // they are no window of the adoption that is about to start.
            lastReleases    = []
            lastObligations = []
        }
        try await host.start()
        let created = try host.makeSeat()
        seat = created
        // The host's stream once per driver and the seat's once per seat. The
        // replaced seat's watcher had the whole restart to drain its stream.
        if hostWatcher == nil { hostWatcher = watch(host.events) }
        seatWatcher?.cancel()
        seatWatcher = watch(created.events)
        return created
    }

    /// Reads one event stream for as long as it lasts, logging every event and
    /// keeping the ones a record may name.
    ///
    /// **One iterator per stream, and this is it.** An `AsyncStream` has one
    /// continuation, so a second `for await` anywhere in the lab would take
    /// events away from this one rather than see the same ones; anything else
    /// that wants them reads `takeNotes` or the log. It is also why the host's
    /// subscription is guarded rather than remade: a host that is started again
    /// keeps the stream it published, and iterating it twice splits it. A seat
    /// made in place of a failed one publishes a new stream, so its watcher is
    /// new and the replaced seat's is cancelled: still one iterator per stream.
    ///
    /// **Nothing here acts on what it reads.** `windowAdoptedNotTargeted` in
    /// particular is recorded and not answered: the kit's rule is that only the
    /// consumer moves the target, precisely because the seat cannot tell a
    /// dialog a person operates from a 66 by 20 point system surface, and this
    /// lab's decision is to stay in the window it adopted and let the record
    /// say another one appeared.
    private func watch(_ events: AsyncStream<SeatEvent>) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            for await event in events {
                Self.log.info("seat event: \(SeatErrorMapper.line(for: event), privacy: .public)")
                guard let self else { return }
                if let note = SeatErrorMapper.note(for: event) { self.keep(note) }
            }
        }
    }

    private func keep(_ note: String) {
        notes.append(note)
        if notes.count > 20 { notes.removeFirst(notes.count - 20) }
    }

    /// The notes since the last time anybody asked, and empties the buffer.
    ///
    /// Draining rather than marking: the lab runs one thing at a time, so what
    /// is in the buffer when a record is written is what happened while it ran.
    func takeNotes() -> [String] {
        defer { notes = [] }
        return notes
    }
}
