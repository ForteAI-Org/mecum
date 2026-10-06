import ApplicationServices
import CoreGraphics
import CursorGuard
import Foundation
import SeatCapture
import SeatCore
import SeatInput
import SeatSession
import TargetReader
import VirtualScreens

/// One clear sentence for every Seat error the driver can throw.
///
/// The kit answers in fields and never in prose, so `localizedDescription`
/// renders a case as "VirtualScreens.DisplayFailure error 15", which names
/// nothing: the enum tag is not even the declaration index, because Swift
/// numbers the cases that carry a payload before the ones that do not. The
/// sentences live here, the way `SeatKitBridge` writes them in the research
/// lab.
enum SeatErrorMapper {

    static func message(for error: any Error) -> String {
        switch error {
        case let failure as ObservationUnavailable:
            sentence(failure)
        case let failure as ObservationAdmissionRefusal:
            sentence(failure)
        case let failure as DisplayFailure:  sentence(failure)
        case let failure as SessionFailure:  sentence(failure)
        case let refusal as InputEndpointRefusal:
            sentence(refusal)
        case let retired as InputEndpointInvalidation:
            sentence(retired)
        case let refusal as RemoteContentActuationRefusal:
            refusal.description
        case let stop as SeatInterruption:
            "The seat stopped: " + stop.issues.map(sentence).joined(separator: "; ") + "."
        case let failure as InputPreparationFailure:
            sentence(failure)
        case let failure as NativeTextInputFailure:
            preparationCause(failure.cause)
                + (failure.cleanup.needsRecovery
                   ? " Native text composition could not be restored."
                   : " Native text composition was closed.")
        case let failure as InputFailure:    sentence(failure)
        case let failure as CaptureFailure:  sentence(failure)
        case let failure as FenceFailure:    sentence(failure)
        case let failure as WindowReaderError:
            failure.errorDescription ?? failure.localizedDescription
        case is CancellationError:           "The operation was cancelled."
        default:                             error.localizedDescription
        }
    }

    /// Why the recipient of one action could not be attested.
    ///
    /// None of these is answered by sending to the window the dialog blocks:
    /// an application waiting on its own panel is not the place its panel's
    /// input belongs, so a discovery that names nobody refuses and says which
    /// reading came up short.
    private static func sentence(_ refusal: InputEndpointRefusal) -> String {
        switch refusal {
        case .noNodeAtPoint:
            "Nothing was found at that point, twice, so the action has no recipient."
        case .pointOutsideSurface:
            "That point is outside the dialog, and the window it covers is blocked by it."
        case .subtreeUnreadable(let surface):
            "The input target on window \(surface.windowNumber) could not be identified "
                + "from its accessibility data. No input was sent."
        case .identityUnattested(let windowNumber):
            "Window \(windowNumber) has no complete window server identity."
        case .identityChangedDuringDiscovery(let windowNumber):
            "Window \(windowNumber) changed hands while it was being read: it closed, its "
                + "id was handed out again, or the helper that owned it was replaced."
        case .geometryUnavailable(let windowNumber):
            "The rectangle of window \(windowNumber) could not be read."
        case .notContainedInSurface(let windowNumber):
            "Window \(windowNumber) is real and is not drawn inside this dialog, so it "
                + "belongs to somebody else."
        case .recipientModallyBlocked(let windowNumber):
            "The selected modal blocks window \(windowNumber), so that window cannot receive this action."
        case .incoherentEndpoint(let windowNumber):
            "The readings about window \(windowNumber) do not describe one recipient."
        }
    }

    /// Why a recipient attested a moment ago may no longer be used. Every one
    /// of them happened between the reading and the first event, so nothing was
    /// sent.
    private static func sentence(_ retired: InputEndpointInvalidation) -> String {
        switch retired {
        case .expired:
            "The recipient of this action was read too long ago and has to be read again."
        case .relationNoLongerValid:
            "The seat is working on another surface now, so that recipient is not this "
                + "action's any more."
        case .identityChanged:
            "The recipient window closed, its id was handed out again, or the helper that "
                + "owned it was replaced."
        case .focusedNodeChanged:
            "The keyboard focus moved to another window, so these keys would have arrived "
                + "somewhere nobody looked."
        case .selectionSuperseded:
            "The target changed after the recipient was read."
        }
    }

    /// The adoption report the seat keeps after a failed move, which is what
    /// turns "not confirmed" into a diagnosis: what was asked, where the
    /// background display is, what the window server last saw, and whether the
    /// window came home.
    static func detail(of failure: WindowAdoptionFailure) -> String {
        var sentence = "Window \(failure.window.windowNumber) is \(size(failure.window.frame)), "
            + "requested at \(rectangle(failure.requestedFrame)) on the background display "
            + "\(rectangle(failure.virtualBounds)); the window server last saw "
            + "\(failure.lastObservedFrame.map(rectangle) ?? "nothing") and the window "
            + "\(restoration(failure.restoration))."
        sentence += " " + verdict(requested: failure.requestedFrame.size,
                                  observed: failure.lastObservedFrame?.size)
        if let error = failure.restorationError {
            sentence += " Putting it back also failed: \(message(for: error))"
        }
        return sentence
    }

    /// The same two facts for a move the seat keeps no adoption report for.
    ///
    /// `AgentSeat.stage` throws after the window has been adopted, so the
    /// rollback that writes `lastAdoptionFailure` never runs and the report is
    /// nil: the frame the window server last saw arrives in the error itself,
    /// and the size that was asked for is the one the driver handed over. The
    /// requested origin is deliberately absent, because the seat centres the
    /// window and the driver never computed one to name.
    ///
    /// No restoration and no frame is a failure that came before any move: a
    /// move the seat started writes an adoption report, and a window it took
    /// is released with an outcome. `seat.adopt` refusing a failed seat with
    /// `seatNotReady` is this case, and saying the window "was never given
    /// back" there alarmed a person about a window that never left.
    static func detail(requestedSize: CGSize, bounds: CGRect, observed: CGRect?,
                       restoration: WindowReleaseOutcome?) -> String {
        guard restoration != nil || observed != nil else {
            return "The seat was asked for \(size(requestedSize)) on the background display "
                + "\(rectangle(bounds)) and stopped before it moved any window, so there was "
                + "nothing to give back."
        }
        // The observed frame is in the failure's own sentence, which this one
        // is appended to, so it is read for the verdict and not repeated.
        return "The seat was asked for \(size(requestedSize)) on the background display "
            + "\(rectangle(bounds)); the window "
            + "\(restoration.map(self.restoration) ?? "was never given back")."
            + " " + verdict(requested: requestedSize, observed: observed?.size)
    }

    /// The frame the window server last saw, when the error carries one. The
    /// two unconfirmed moves are the only failures that report it, and for a
    /// failed stage it is the sole record of where the window ended up: the
    /// seat writes no adoption report for one.
    static func lastObservedFrame(of error: any Error) -> CGRect? {
        switch error as? DisplayFailure {
        case .placementNotConfirmed(_, let frame): frame
        case .stageNotConfirmed(_, let frame):     frame
        default:                                   nil
        }
    }

    /// What the requested and observed sizes say, and what they cannot say.
    ///
    /// The same size means the move took and something on the background
    /// display is holding the window where it is. A different size now means
    /// the delta got past `crossSourceTolerance`, since a delta inside it no
    /// longer fails at all, and two causes produce that and need opposite
    /// fixes: an application whose systematic offset is wider than the 3 pt
    /// the tolerance was calibrated on, or geometry that had genuinely not
    /// settled when the window was adopted. The numbers alone do not separate
    /// them, so the sentence names the tolerance and stops there rather than
    /// asserting a cause it cannot know.
    private static func verdict(requested: CGSize, observed: CGSize?) -> String {
        guard let observed else {
            return "No frame came back, so nothing here says which of the two it was."
        }
        return sizesMatch(requested, observed)
            ? "It arrived at the \(size(requested)) that was asked for, so something on the "
                + "background display is holding it at that size."
            : "It arrived \(size(observed)) where \(size(requested)) was asked for, past the "
                + "\(Int(VirtualWindowPlacementCheck.crossSourceTolerance)) pt allowed between "
                + "the application's own reading of its window and the window server's: either "
                + "this application disagrees with the window server by more than that, or its "
                + "geometry had not settled when it was adopted, and these numbers do not say "
                + "which."
    }

    /// The kit's own cross-source tolerance, because these two sizes are the
    /// two sources it is for: the requested size is computed from the window's
    /// accessibility body and the observed one is the window server's listing.
    /// 4 pt, MarkEdit's measured 3 pt of width plus the window server's point
    /// of rounding, so the branch above divides where the kit's failure does.
    private static func sizesMatch(_ a: CGSize, _ b: CGSize) -> Bool {
        let tolerance = VirtualWindowPlacementCheck.crossSourceTolerance
        return abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// The focus recovery report the seat keeps, which is what turns "input is
    /// paused" into a diagnosis: whether the request went out at all, what the
    /// kit refused on, where it was sending the focus and how long it has been
    /// waiting. The kit computes this reason and nothing here re-decides it.
    static func detail(of report: UserFocusRecoveryReport) -> String {
        var sentence = "Focus recovery is \(report.outcome.rawValue) after "
            + "\(milliseconds(report.elapsedNanoseconds)), sending focus to "
            + (report.destination.map { "window \($0.windowNumber) of PID \($0.processID)" }
                ?? "no destination")
        // The two numbers that measure the swap the person watched. Without
        // them the only reading is "I saw it", which cannot tell 11 from 200 ms.
        if let frontmost = report.frontmostRestoredNanoseconds {
            sentence += ", your application was frontmost again after \(milliseconds(frontmost))"
        }
        if let call = report.timing.restoreCallNanoseconds {
            sentence += ", the restore call took \(milliseconds(call))"
        }
        if let code = report.requestCode { sentence += ", request code \(code)" }
        if !report.detail.isEmpty { sentence += ": \(report.detail)" }
        return sentence + "."
    }

    /// The pause reasons this failure names, looked up through the preparation
    /// and sequence wrappers the driver attaches, so a caller can tell a pause
    /// apart from everything else without unwrapping them itself.
    static func pauseReasons(of error: any Error) -> [InputPauseReason] {
        switch error {
        case let failure as InputFailure:
            if case .inputPaused(let reasons) = failure { return reasons }
            return []
        case let failure as InputPreparationFailure: return pauseReasons(of: failure.cause)
        case let failure as InputSequenceFailure:    return pauseReasons(of: failure.cause)
        case let failure as NativeTextInputFailure:  return pauseReasons(of: failure.cause)
        default:                                     return []
        }
    }

    /// True when a run can carry on from this stop.
    ///
    /// All three say the same thing: the Command was refused before it went
    /// out, and the world moved while it was on its way. The first two are the
    /// focus recovery read at two points — the gate refuses before the hop to
    /// the main actor, the recovery's own preparation after it — and the third
    /// is the seat leaving the acting state because an issue was reported
    /// during the action, which is what an application activating itself looks
    /// like from here. The answer to all three is to perceive again and decide
    /// again, and the first two are also worth waiting out first.
    ///
    /// Every other reason is structural: nothing about waiting or looking again
    /// changes it, and the run is right to end on it.
    static func mayDecideAgain(_ reasons: [InputPauseReason]) -> Bool {
        !reasons.isEmpty && reasons.allSatisfy {
            switch $0 {
            case .focusRecovery, .activationUnverified, .seatNotActing: true
            default:                                                    false
            }
        }
    }

    /// Why the gate is holding input back, in the person's words.
    ///
    /// It is exhaustive on purpose: a cause the kit adds has to be given a
    /// sentence here rather than appear in the badge as an empty explanation
    /// or, worse, as nothing at all beside a seat that looks ready.
    static func sentence(_ reason: InputPauseReason) -> String {
        switch reason {
        case .focusRecovery:
            "your focus is being put back where it was"
        case .windowTransfer:
            "the seat is moving a window"
        case .focusRecoveryStopped:
            "focus recovery stopped, and nothing reopens input after that"
        case .deliberateStop:
            "you stopped the seat, and nothing reopens input after that"
        case .holdEnded:
            "the hold that admitted input is over"
        case .activationUnverified:
            "an activation the seat has not verified yet"
        case .fenceInactive:
            "the cursor fence is not active"
        case .recoveryReplaced:
            "the preparation belongs to a recovery that has been replaced"
        case .noActionInFlight:
            "there is no action in flight to prepare for"
        case .seatNotActing:
            "the seat left the acting state while the command was on its way"
        case .turnChanged:
            "the hold this preparation was made under is no longer the current one"
        case .recoveryUnavailable:
            "the seat's recovery went away while a preparation was outstanding"
        case .destinationNotPrepared:
            "the restore named a window the prepared destination is not about"
        }
    }

    /// The one line under the seat badge: every cause the gate is holding, and
    /// nil while it is holding none.
    static func heldInput(_ reasons: [InputPauseReason]) -> String? {
        guard !reasons.isEmpty else { return nil }
        return "Input is held back: " + reasons.map(sentence).joined(separator: "; ") + "."
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> String {
        "\((Double(nanoseconds) / 1_000_000).rounded()) ms"
    }

    // MARK: The display and the window move

    private static func sentence(_ failure: DisplayFailure) -> String {
        switch failure {
        case .fullScreenStateUnreadable(let windowNumber, let code):
            "Window \(windowNumber) did not answer whether it is in native fullscreen "
                + "(code \(code.rawValue)), so the seat could not take it out and left it where it is. "
                + "Tell the person to take that window out of fullscreen, then open it again."
        case .fullScreenNotSettable(let windowNumber):
            "Window \(windowNumber) is in native fullscreen and does not let the seat take it out, "
                + "so it was left where it is. "
                + "Tell the person to take that window out of fullscreen, then open it again."
        case .fullScreenTransitionNotObserved(let windowNumber, let wanted, let lastFrame):
            "Window \(windowNumber) did not finish \(wanted ? "entering" : "leaving") fullscreen; "
                + "last frame: \(lastFrame.map(rectangle) ?? "unavailable")."
        case .fullScreenSpaceStillOnScreen(let windowNumber):
            "Window \(windowNumber) is in native fullscreen on the Space the person is looking at, and "
                + "taking it would animate their display, so it was left where it is. "
                + "Tell the person to go to their desktop or to another Space, then open it again."
        case .windowOwnerVanished(let windowNumber, let processID):
            "The application owning window \(windowNumber) (PID \(processID)) is no longer running."
        case .primitiveUnavailable(let key):
            "A private primitive this macOS build does not publish is missing: \(key)."
        case .displayCreationFailed:
            "CGVirtualDisplay refused to create the background display."
        case .modeRejected:
            "The background display refused the requested width, height and refresh rate."
        case .settingsRejected:
            "The background display refused the mode list."
        case .displayIDUnavailable:
            "The background display was created without a usable display id."
        case .displayEnumerationFailed(let code):
            "CoreGraphics did not enumerate the displays (CGError \(code.rawValue))."
        case .notRegistered(let displayID, let isActive, let isOnline, let listed):
            "The background display \(displayID) is not published yet "
                + "(active \(isActive), online \(isOnline), in the active list \(listed))."
        case .screenRegistrationTimedOut(let displayID):
            "AppKit never published an NSScreen for the background display \(displayID)."
        case .noPhysicalDisplays:
            "There is no physical display to attach the background display to."
        case .originOutOfRange(let origin):
            "The computed corner origin \(Int(origin.x)),\(Int(origin.y)) does not fit in an Int32."
        case .topologyConfigurationFailed(let step, let code):
            "The display arrangement transaction failed at \(phrase(step)) (CGError \(code.rawValue))."
        case .mainDisplayChanged(let expected, let actual):
            "The main display changed from \(expected) to \(actual) while the seat was starting."
        case .physicalDisplayMoved(let displayID):
            "Your display \(displayID) moved or was resized while the seat was running."
        case .displayStillOnline(let displayID):
            "The background display \(displayID) is still online, so the arrangement was not restored."
        case .accessibilityPermissionMissing:
            "Moving a window needs Accessibility, and it is not granted."
        case .processUnavailable(let processID):
            "The application that owns the window (PID \(processID)) is no longer running."
        case .windowElementUnavailable(let windowNumber):
            "No accessibility element could be associated with window \(windowNumber)."
        case .ambiguousWindowMatch(let windowNumber, let matches):
            "\(matches) windows match the title and size of window \(windowNumber), "
                + "so the recovery refused rather than guessing."
        case .attributeNotSettable(let name):
            "The application exposes “\(name)” but does not allow it to be written."
        case .attributeWriteFailed(let name, let code):
            "The accessibility write of “\(name)” failed with AXError \(code.rawValue)."
        case .raiseFailed(let windowNumber, let code):
            "Raising window \(windowNumber) failed with AXError \(code.rawValue)."
        case .placementNotConfirmed(let windowNumber, let lastFrame):
            "Window \(windowNumber) never came to rest inside the background display; "
                + "the window server last saw it at \(lastFrame.map(rectangle) ?? "no readable frame")."
        case .stageNotConfirmed(let windowNumber, let lastFrame):
            "Window \(windowNumber) did not come back to full size on the background display; "
                + "the window server last saw it at \(lastFrame.map(rectangle) ?? "no readable frame")."
        }
    }

    private static func phrase(_ step: TopologyStep) -> String {
        switch step {
        case .openTransaction:                    "opening the transaction"
        case .placeVirtualDisplay:                "placing the background display"
        case .placePhysicalDisplay(let display):  "setting the origin of display \(display)"
        case .commitTransaction:                  "committing the transaction"
        }
    }

    // MARK: The host and the seat

    private static func sentence(_ failure: ObservationUnavailable) -> String {
        switch failure {
        case .notAssigned:
            "The seat has no assigned application to observe."
        case .noSelectedTarget:
            "The seat has no selected target to observe."
        case .suspended(let causes):
            "The seat cannot observe while suspended: "
                + causes.map(sentence).joined(separator: "; ") + "."
        case .capabilityUnqualified(let capability):
            "The observation capability \(capability.rawValue) is not qualified on this system."
        case .evidenceInsufficient(let evidence):
            "The captured frame did not carry sufficient evidence: \(evidence)."
        case .hostedSurfaceUnresolved(let surface, let namedHost):
            "Window \(surface.windowNumber) is drawn inside window \(namedHost.windowNumber), "
                + "which this seat does not hold, so it has no picture of its own to observe."
        case .captureDeadlineExpired(let attempts):
            "The observation deadline expired after \(attempts) capture attempt\(attempts == 1 ? "" : "s")."
        case .captureFailed(let reason):
            "The observation capture failed: \(reason)"
        case .menuInteractionActive(let parent):
            "A contextual menu for window \(parent.windowNumber) is active; observe that menu instead."
        case .menuContextRevoked:
            "The contextual-menu observation is no longer current."
        }
    }

    /// One clause per reason the seat will not act, in the words a person can
    /// do something about.
    ///
    /// These used to be rendered with `String(describing:)`, which prints a
    /// case name and a payload struct: "modalBlock(modal: WindowIdentity(...))"
    /// names the one situation the person can actually clear, a dialog in
    /// front of the window, in a form nobody reads as that. The causes are
    /// independent and are reported together, so each one is a clause and the
    /// caller joins them.
    static func sentence(_ cause: SeatSuspensionCause) -> String {
        switch cause {
        case .notAssigned:
            "no application is assigned to the seat"
        case .noEligibleTarget:
            "no window of the assigned application is eligible to act in"
        case .explicitSelectionRequired(let candidates):
            "\(candidates.count) windows are equally plausible targets ("
                + candidates.map(surface).joined(separator: ", ")
                + ") and nothing observed their order, so one has to be chosen"
        case .modalBlock(let modal, let blocked):
            "a dialog is in front of the window: \(surface(modal)) is modal over "
                + "\(surface(blocked)), so answer or close the dialog before the seat can act "
                + "in the window behind it"
        case .modalRelationInDoubt(let detail):
            "the seat could not establish whether a dialog is in front of the window (\(detail)), "
                + "and it does not act on a doubt"
        case .visibilityUncertain(let surface):
            "whether \(self.surface(surface)) is visible did not decide"
        case .selectedSurfaceAbsent(let surface):
            "\(self.surface(surface)) was not in the last reading, which proves neither that it "
                + "closed nor that it is hidden"
        case .selectedSurfaceNotVerified(let surface):
            "\(self.surface(surface)) was seen once and no second reading agreed with it yet"
        case .containmentNotVerified(let blocks):
            "the assigned application is not confirmed contained on the background display"
                + (blocks.isEmpty ? ", and no reading has been folded in yet"
                    : ": \(blocks.joined(separator: ", "))")
        case .observationMissing:
            "no observation of the target is current; observe again"
        case .observationSuperseded(let observed, let current):
            "the observation was taken under selection \(observed) and the seat is on "
                + "\(current) now; observe again"
        case .observationIdentityMismatch(let observed, let selected):
            "the observation is of \(surface(observed)) and \(surface(selected)) is selected"
        case .observationGeometryStale(let surface):
            "\(self.surface(surface)) is no longer at the frame the observation was taken at"
        case .monitorSharedFault:
            "the monitor's fault reaches the capture the observation needs, so the seat is "
                + "closed to input as well as to the preview"
        }
    }

    /// The note an observation carries about windows of `application` open on the person's
    /// screen, outside the seat, and nil when there are none. `describe` names one Window ID,
    /// with its title and kind where they are known.
    ///
    /// It is only for those windows, because only there can the person do anything; a window
    /// the application hid is nobody's to close. It says to go on with the scene, because a
    /// worker told about a window it could not see stopped and waited for the person.
    static func notice(
        for shown  : [Int],
        application: String,
        describe   : (Int) -> String
    ) -> String? {
        guard !shown.isEmpty else { return nil }
        let names = shown.map(describe).joined(separator: ", ")
        let (verb, pronoun) = shown.count == 1 ? ("is", "it") : ("are", "them")
        let note = "\(names) of \(application) \(verb) open on the person's screen, outside the seat, "
            + "so this scene does not show \(pronoun) and the seat cannot act on \(pronoun). Continue "
            + "with this window; if you need \(pronoun), ask the person to close \(pronoun) or bring "
            + "\(pronoun) back, then observe again."
        return note.prefix(1).uppercased() + note.dropFirst()
    }

    private static func sentence(_ failure: ObservationAdmissionRefusal) -> String {
        switch failure {
        case .foreignReference:
            "The observation was issued by another seat or seat lifecycle."
        case .referenceSuperseded:
            "A newer observation replaced the one used for this command."
        case .noCurrentObservation(let reason):
            "The observation is no longer current (\(reason)); observe again before acting."
        case .barrierAdvanced:
            "A command or invalidation advanced the observation barrier; observe again before acting."
        case .instanceChanged:
            "The assigned application instance changed after the observation."
        case .recipientNotCurrent(let current):
            "The observed window is no longer current; window \(current.windowNumber) is selected now."
        case .selectionSuperseded:
            "The target selection changed after the observation."
        case .roleChanged:
            "The observed surface changed role after the observation."
        case .geometryChanged:
            "The observed window geometry changed; observe again before acting."
        case .frameAgeUnknown(let doubt):
            "The age of the observed frame is unknown (\(doubt)), so the command was refused."
        case .frameTooOld(let age, let limit):
            "The observed frame is too old (\(age) ns; limit \(limit) ns)."
        case .ordinaryCommandDuringMenu(let parent):
            "A contextual menu for window \(parent.windowNumber) is active; an ordinary command was refused."
        case .menuContextRevoked:
            "The contextual-menu observation is no longer current."
        }
    }

    private static func sentence(_ failure: SessionFailure) -> String {
        switch failure {
        case .fullScreenTransferDisabled(let windowNumber):
            "Window \(windowNumber) is in native fullscreen and fullscreen transfer is disabled."
        case .keysStillHeld(let count):
            "The turn still holds \(count) key(s); release them before ending the turn."
        case .turnRequired:
            "Input needs a turn, and none was held."
        case .seatNotReady(let state):
            "The seat is \(state.rawValue), so it cannot do this now."
        case .seatLimitReached:
            "This host already has a seat; one seat per background display."
        case .hostNotReady(let state):
            "The background display host is \(state.rawValue), so it cannot do this now."
        case .turnNotHeld(let generation):
            "Turn \(generation) is not the one currently held."
        case .unconfirmedCommands(let count):
            "\(count) posted command\(count == 1 ? "" : "s") "
                + "\(count == 1 ? "is" : "are") still unconfirmed, so the turn cannot be released."
        case .receiptOutOfOrder:
            "Receipts have to be confirmed in the order they were posted."
        case .nothingToConfirm:
            "There is nothing to confirm."
        case .windowNotAdopted(let windowNumber):
            "Window \(windowNumber) is not adopted by this seat."
        case .applicationNotAssigned:
            "The seat was asked to give its application back and has none assigned."
        case .assignmentStillInUse(let use):
            "The application cannot be given back while \(inFlight(use)), so the next one "
                + "cannot be adopted yet. That finishes by itself; try again in a moment."
        case .returnsStillOutstanding(let windowNumbers):
            "The return of \(windows(windowNumbers)) from an earlier application is not "
                + "finished, so this application cannot be given back and nothing else can be "
                + "adopted until it is."
        case .assignedWindowsStillHeld(let windowNumbers):
            "The seat still holds \(windows(windowNumbers)) of this application, so it cannot "
                + "be given back yet. Giving every window it holds back to your display is what "
                + "lets the next application be adopted."
        case .pumpTimedOut(let seconds):
            "The application event loop did not turn within \(Int(seconds)) s, "
                + "so the background display never appeared."
        case .startNotAtomic(let issue):
            "The seat could not start as one step: \(sentence(issue))."
        case .contextMenuAlreadyOpen(let processID):
            "The target (PID \(processID)) already has a contextual menu open."
        case .contextMenuNeverOpened(let windowNumber, let within):
            "No contextual menu opened on window \(windowNumber) within \(within)."
        case .contextMenuNotClosed(let menuWindowNumber, let processID):
            "The contextual menu \(menuWindowNumber) of PID \(processID) stayed open, "
                + "so that application is running a modal loop until somebody closes it."
        case .surfaceFamilyUnclassified(let windowNumber):
            "Nothing established what draws the surface of window \(windowNumber), so no "
                + "measured recipe covers this action and nothing was sent."
        case .windowDoesNotFit(let windowNumber, let size, let bounds):
            "Window \(windowNumber) is \(Int(size.width))×\(Int(size.height)) pt, the background "
                + "display is \(Int(bounds.width))×\(Int(bounds.height)) pt, and the application "
                + "would not take the smaller size. Nothing was moved."
        }
    }

    /// What the seat is in the middle of that the assignment is the authority
    /// for, named as the thing the person is waiting on. Every case is
    /// transient, which is why the sentence around it says to ask again.
    private static func inFlight(_ use: AssignmentUse) -> String {
        switch use {
        case .seatTearingDown:        "the seat is being taken down"
        case .commandInFlight:        "an action is still being carried out"
        case .turnHeld:               "the seat is still held for an action"
        case .adoptionInFlight:       "a window is still being taken onto the background display"
        case .windowTransferInFlight: "a window is still moving between displays"
        case .focusRecoveryRestoring: "your own focus is still being handed back to you"
        }
    }

    /// "window 36778" or "windows 36778, 36386": the two handback refusals that
    /// name a set of Window IDs both read better with the plural agreed.
    private static func windows(_ numbers: [Int]) -> String {
        "window\(numbers.count == 1 ? "" : "s") "
            + numbers.map(String.init).joined(separator: ", ")
    }

    /// The Issue's sentence, unless the cause says more than the Issue can. A
    /// screen connected is `displayChanged` like any other, but the generic
    /// sentence reads as a fault, and this one is the person's own plug.
    private static func sentence(_ issue: SeatIssue, cause: SeatIssueCause?) -> String {
        guard cause == .watchdog(.physicalDisplayAdded) else { return sentence(issue) }
        return "a screen was connected while the seat was running, so the seat stopped and "
            + "will start again, including the new screen, the next time an application is opened"
    }

    private static func sentence(_ issue: SeatIssue) -> String {
        switch issue {
        case .keysNotReleased:         "held keys could not be released safely"
        case .displayChanged:          "the background display or the physical arrangement is no longer trustworthy"
        case .fenceUnavailable:        "the cursor fence is not active"
        case .processUnavailable:      "the target application is gone"
        case .identityChanged:         "the target's PID or window id changed"
        case .targetActivated:         "the target application became active in your seat"
        case .windowUnavailable:       "the target window is momentarily unreadable"
        case .geometryChanged:         "the target window moved or was resized"
        case .snapshotChanged:         "the accessibility and window server geometry have to be reconfirmed"
        case .cursorInterference:      "the cursor moved for a reason physical input does not explain"
        case .ambiguousEffect:         "the effect of the last input is unknown, and repeating it could duplicate an action"
        case .recoveryExhausted:       "the recovery did not succeed within its budget"
        case .monitorUnavailable:      "the preview of the background display is unavailable"
        case .windowStashed:           "the window stayed stashed: Stage Manager did not put it back on stage"
        case .preparationNotRestored:  "the target's internal AppKit state did not go back, and the events are already out"
        case .contextMenuLeftOpen:     "a contextual menu the seat opened stayed on the screen"
        }
    }

    // MARK: Input

    private static func sentence(_ failure: InputPreparationFailure) -> String {
        let completed = failure.progress.completedSteps.isEmpty
            ? "none"
            : failure.progress.completedSteps.map(\.rawValue).joined(separator: ", ")
        let failed = failure.progress.failedStep?.rawValue ?? "none"
        let cleanup = switch failure.progress.cleanup {
        case .notRequired: "not required"
        case .notAttempted: "not attempted"
        case .succeeded: "succeeded"
        case .failed(let code): "failed (code \(code.map(String.init) ?? "unknown"))"
        }
        let recovery = failure.progress.neededRecovery?.rawValue ?? "none"
        let cleanupCause = failure.cleanupCause.map {
            " Cleanup failure: \(preparationCause($0))"
        } ?? ""

        return "\(preparationCause(failure.cause)) Preparation progress: completed steps \(completed); "
            + "failed step \(failed); failed step may have taken effect: "
            + "\(failure.progress.failedStepMayHaveTakenEffect ? "yes" : "no"); "
            + "cleanup \(cleanup); recovery needed: \(recovery)."
            + cleanupCause
    }

    /// A preparation wrapper can arrive as another wrapper's cause. Do not ask
    /// `message(for:)` to recurse through wrappers forever; keep the underlying
    /// typed cause visible and let the outer progress remain the report of
    /// record.
    private static func preparationCause(_ error: any Error) -> String {
        if let nested = error as? InputPreparationFailure {
            return "Another input preparation failed: \(String(describing: nested.cause))."
        }
        return message(for: error)
    }

    private static func sentence(_ failure: InputFailure) -> String {
        switch failure {
        case .keyUnresolvable(let character, let inputSourceID):
            "Key \(character) cannot be resolved in keyboard layout \(inputSourceID)."
        case .shortcutContextChanged:
            "The modifier state changed before the shortcut could be sent."
        case .invalidRepeatCount(let requested, let maximum):
            "The requested repeat count \(requested) must be between 1 and \(maximum)."
        case .invalidClickCount(let requested, let maximum):
            "The requested click count \(requested) must be between 1 and \(maximum)."
        case .modifierPolicyUnavailable:
            "The requested keyboard modifier policy is unavailable on this macOS build."
        case .textClusterTooLarge(let codeUnits, let maximum):
            "One character needs \(codeUnits) UTF-16 code units; the delivery limit is \(maximum)."
        case .invalidTextLimit(let clusters, let codeUnits):
            "The text chunk limits are invalid: \(clusters) characters and \(codeUnits) UTF-16 code units."
        case .textTooLong(let measure, let maximum):
            "The text contains \(measure.count) \(textUnit(measure.unit)); the limit is \(maximum)."
        case .primitiveUnavailable(let key):
            "An input primitive this macOS build does not publish is missing: \(key)."
        case .facilityUnavailable(let readiness):
            "The input facility is not usable here: \(phrase(readiness))."
        case .mainConnectionUnavailable:
            "The window server connection of this process is unavailable."
        case .eventSourceUnavailable:
            "No event source could be created for the input."
        case .inputPaused(let reasons):
            "Input is paused: \(reasons.map(phrase).joined(separator: ", "))."
        case .nativeTextInputRefused(let reason):
            switch reason {
            case .unsupported: "Native text composition is not qualified for this surface."
            case .contextActive: "A native text composition is already in progress."
            case .contextClosed: "The native text composition ended before this key could be sent."
            case .contextMismatch: "The key no longer targets the composing window."
            case .commandUnsupported: "This command cannot be used during native text composition."
            case .invalidDeadline: "Native text composition requires a deadline of at most five seconds."
            }
        case .processUnavailable(let processID):
            "The target application (PID \(processID)) is no longer running."
        case .invalidWindowNumber(let windowNumber):
            "\(windowNumber) is not a usable window id."
        case .windowOwnerUnavailable(let windowNumber, let code):
            "The window server did not name the owner of window \(windowNumber) (code \(code))."
        case .windowIdentityUnverified(let processID, let windowNumber):
            "Window \(windowNumber) of PID \(processID) is not attested by the window server, "
                + "so nothing may be posted to it."
        case .windowIdentityChanged(let expected, let observed),
             .coordinateIdentityChanged(.some(let expected), let observed):
            "The window changed identity: expected window \(expected.windowNumber) of "
                + "PID \(expected.processID), observed "
                + "\(observed.map { "window \($0.windowNumber) of PID \($0.processID)" } ?? "nothing")."
        case .coordinateIdentityChanged:
            "The observation the coordinates came from no longer names an attested window."
        case .noCommands:
            "The command sequence is empty."
        case .emptyText:
            "There is no text to insert."
        case .invalidLocation:
            "The input location is not a finite point."
        case .coordinateObservationMissing:
            "Coordinate input needs the observation the point was measured in."
        case .currentCoordinateGeometryUnavailable:
            "The window's current geometry could not be read, so the point cannot be trusted."
        case .invalidCoordinateGeometry:
            "The observed window geometry is not usable."
        case .coordinateGeometryChanged(let observed, let current):
            "The window moved between the observation \(rectangle(observed)) and now "
                + "\(rectangle(current)); observe again before acting."
        case .coordinateScaleChanged(let observed, let current):
            "The display scale changed from \(observed) to \(current); observe again before acting."
        case .coordinateOutsideObservedWindow(let point, let frame):
            "The point \(Int(point.x)),\(Int(point.y)) is outside the observed window "
                + "\(rectangle(frame))."
        case .coordinateSpacesDisagree:
            "The accessibility and window server coordinate readings disagree."
        case .invalidDragPath(let pointCount):
            "A drag needs at least two points, and this path has \(pointCount)."
        case .eventCreationFailed:
            "The input event could not be created."
        case .eventRecordUnavailable:
            "The private event record this build needs is unavailable."
        case .unsupportedEventRecord(let declared, let expected):
            "The event record layout is \(declared) where \(expected) was expected on this build."
        case .recordOffsetOutOfBounds(let offset, let width, let length):
            "The event record field at \(offset) (\(width) bytes) does not fit in \(length) bytes."
        case .preparationFailed(let step, let code):
            "The input preparation failed at \(step.rawValue) with code \(code)."
        case .restoreFailed(let code):
            "The target preparation state could not be restored (code \(code))."
        }
    }

    private static func textUnit(_ unit: TextUnit) -> String {
        switch unit {
        case .graphemeClusters: "characters"
        case .utf16CodeUnits: "UTF-16 code units"
        }
    }

    private static func phrase(_ reason: InputPauseReason) -> String {
        switch reason {
        case .focusRecovery:          "the person's focus is being restored"
        case .windowTransfer:         "the seat is staging or moving a window"
        case .focusRecoveryStopped:   "focus recovery stopped, which nothing resolves"
        case .deliberateStop:         "the seat was stopped by you, which nothing resolves"
        case .holdEnded:              "the hold that admitted input is over"
        case .activationUnverified:   "an activation of the target is not verified yet"
        case .fenceInactive:          "the cursor fence is not active"
        case .recoveryReplaced:       "the seat's focus recovery was replaced under this action"
        case .noActionInFlight:       "the seat has no action in flight"
        case .seatNotActing:          "the seat left the acting state while the command was on its way, "
                                        + "which an issue reported during an action does"
        case .turnChanged:            "the hold this was prepared under is no longer the current one"
        case .recoveryUnavailable:    "the seat's focus recovery is gone"
        case .destinationNotPrepared: "the restore named a window that was not prepared"
        }
    }

    private static func phrase(_ readiness: FacilityReadiness) -> String {
        switch readiness {
        case .validated(let build):          "validated on \(build)"
        case .unvalidated:                   "this macOS build is not validated for it"
        case .unavailable(let reason):       "unavailable (\(reason))"
        case .permissionMissing(let kind):   "\(kind.rawValue) is not granted"
        }
    }

    // MARK: Capture and the fence

    private static func sentence(_ failure: CaptureFailure) -> String {
        switch failure {
        case .timedOut(let step):
            "ScreenCaptureKit did not answer while \(phrase(step))."
        case .frameworkCallLimitReached(let step):
            "ScreenCaptureKit refused to answer again while \(phrase(step))."
        case .configurationUpdateInProgress:
            "The capture stream is already being reconfigured."
        case .configurationStateUnknown:
            "The capture stream's configuration state is unknown, so it fails closed."
        case .screenRecordingPermissionMissing:
            "Capturing the window needs Screen Recording, and it is not granted. "
                + "A fresh grant only reaches a new launch, so Mecum has to be relaunched."
        case .displayNotShareable(let displayID):
            "ScreenCaptureKit does not share the display \(displayID)."
        case .windowNotShareable(let windowNumber):
            "ScreenCaptureKit does not share window \(windowNumber)."
        case .windowIdentityChanged(let expected, let observed):
            "The captured window changed identity: expected window \(expected.windowNumber) of "
                + "PID \(expected.processID), observed "
                + "\(observed.map { "window \($0.windowNumber) of PID \($0.processID)" } ?? "nothing")."
        case .alreadyStarted:
            "The capture stream is already running."
        case .notStarted:
            "The capture stream is not running."
        case .frameUnavailable:
            "No frame of the adopted window was delivered."
        case .captureFailed(let domain, let code):
            "ScreenCaptureKit stopped the stream (\(domain) \(code))."
        case .frameRateUnsupported(let requested, let refreshRate):
            "\(requested) fps is more than the display's \(Int(refreshRate)) Hz."
        }
    }

    private static func phrase(_ step: CaptureStep) -> String {
        switch step {
        case .shareableContent:   "listing the shareable content"
        case .still:              "taking a still frame"
        case .streamStart:        "starting the stream"
        case .streamStop:         "stopping the stream"
        case .configurationUpdate: "updating the stream configuration"
        }
    }

    private static func sentence(_ failure: FenceFailure) -> String {
        switch failure {
        case .noPhysicalDisplays:
            "The cursor fence has no physical display to confine the cursor to."
        case .accessibilityPermissionMissing:
            "The cursor fence needs Accessibility, and it is not granted."
        case .eventTapUnavailable:
            "The cursor fence could not install its event tap."
        case .fenceThreadUnavailable:
            "The cursor fence could not start its run loop thread."
        case .cursorPositionUnavailable:
            "The global cursor position is unavailable, so the fence fails closed."
        case .regionMismatch(let active, let requested):
            "The cursor fence is confining \(active.count) region(s) where "
                + "\(requested.count) were requested."
        case .markerReserved:
            "The cursor fence marker is already reserved."
        }
    }

    // MARK: The event channel

    /// One line for one event, for the log the diagnoses are read from.
    ///
    /// Exhaustive on purpose: an event with no line here is an event the log
    /// would swallow, and the channel is the only place several of these facts
    /// are ever stated. Window numbers, reasons and outcomes are in the line
    /// because those are what a line is looked up by afterwards.
    static func line(for event: SeatEvent) -> String {
        switch event {
        case .hostStateChanged(let from, let to, let reason):
            "the host went from \(from.rawValue) to \(to.rawValue) because \(phrase(reason))"
        case .seatStateChanged(let from, let to, let reason):
            "the seat went from \(from.rawValue) to \(to.rawValue) because \(phrase(reason))"
        case .issueDetected(let issue, let cause):
            "issue \(issue.rawValue): \(sentence(issue, cause: cause))"
                + (cause.map { " (\(String(describing: $0)))" } ?? "")
        case .fenceSignals(let signals):
            "the cursor fence latched \(signals.tapDisabled) tap disable(s) and "
                + "\(signals.pointerOutOfRegion) pointer escape(s)"
        case .recoveryProgressed(let episode, let step):
            "recovery episode \(episode): \(String(describing: step))"
        case .userFocusRecoveryChanged(let report):
            detail(of: report)
        case .monitorQualityChanged(let change):
            "the preview dropped from \(change.from.frameRate) to \(change.to.frameRate) at "
                + "resolution scale \(change.to.resolutionScale), reason "
                + String(describing: change.reason)
        case .targetChanged(let from, let to, let reason):
            "the seat's target moved from \(from.map(String.init) ?? "nothing") to window "
                + "\(to.windowNumber) because \(phrase(reason))"
        case .targetChangeRefused(let windowNumber, let state, let issues):
            "the move of the target to window \(windowNumber) was refused in state "
                + "\(state.rawValue)"
                + (issues.isEmpty ? "" : ": " + issues.map(sentence).joined(separator: "; "))
        case .windowAdoptedNotTargeted(let window, let target):
            "the seat adopted window \(window.windowNumber) "
                + "(\(size(window.frame))) of the same application and kept working in "
                + (target.map { "window \($0)" } ?? "no window")
        case .windowTransferRefused(let windowNumber, let processID, let reason):
            "window \(windowNumber) of PID \(processID) was left where it was: "
                + phrase(reason)
        case .windowReleased(let windowNumber, let outcome):
            "window \(windowNumber) \(restoration(outcome))"
        case .teardownFinished(let report):
            teardown(report) ?? "the background display came down and every window went home"
        }
    }

    /// The events a run's record has to be able to name, and nil for the rest.
    ///
    /// Six of thirteen, and the cut is what a person reads afterwards rather
    /// than what a diagnosis needs: where the seat was working, what else it
    /// took, whose focus moved, what went wrong, what went home. The other
    /// seven are cadence (state transitions, fence batches, recovery steps,
    /// preview quality) and every one of them is still in the log.
    static func note(for event: SeatEvent) -> String? {
        switch event {
        case .targetChanged, .windowAdoptedNotTargeted, .userFocusRecoveryChanged,
             .issueDetected, .windowReleased, .teardownFinished:
            line(for: event)
        default:
            nil
        }
    }

    /// What a finished teardown leaves the person to know, and nil when it
    /// leaves them nothing: the windows that did not go back to their display.
    static func teardown(_ report: TeardownReport) -> String? {
        let stranded = report.windowsNotReturned
        guard !stranded.isEmpty else { return nil }
        return "The background display came down and "
            + (stranded.count == 1
                ? "window \(stranded[0]) did not go back to your display"
                : "windows \(stranded.map(String.init).joined(separator: ", ")) did not go back "
                    + "to your display")
            + ". Move \(stranded.count == 1 ? "it" : "them") back yourself, or quit the "
            + "application that owns \(stranded.count == 1 ? "it" : "them")."
    }

    /// What a release of the whole assignment left the person to do, and nil
    /// when it left them nothing.
    ///
    /// One clause per surface, because the recoveries differ: a window that
    /// would not be written is moved back or its owner quit, a window born on
    /// the background display needs a display named for it, and one nothing
    /// was attempted for is still waiting for the release to be asked again.
    static func obligations(_ obligations: [AssignmentObligation]) -> String? {
        guard !obligations.isEmpty else { return nil }
        return obligations.map(clause).joined(separator: "; ") + "."
    }

    private static func clause(_ obligation: AssignmentObligation) -> String {
        let window = "window \(obligation.windowNumber)"
        switch obligation.reason {
        case .returnRefused:
            return "\(window) would not go back to \(place(obligation.owedFrame)): move it back "
                + "yourself, or quit the application that owns it"
        case .restorationOwed:
            return "\(window) is still on the background display after a move that did not "
                + "come back: it goes home when the display is taken down"
        case .noDestinationInUserSeat:
            return "\(window) was opened on the background display and has nowhere of its own "
                + "to go back to: choose a display for it"
        case .notAttempted:
            return "\(window) was not reached before the release ran out of time: ask for the "
                + "release again"
        }
    }

    private static func place(_ frame: CGRect?) -> String {
        frame.map(rectangle) ?? "where it came from"
    }

    private static func phrase(_ reason: SeatTransitionReason) -> String {
        switch reason {
        case .requested:          "the lab asked for it"
        case .issues(let issues): issues.map(sentence).joined(separator: "; ")
        case .recovered:          "a recoverable episode closed"
        case .targetWentInactive: "the target application went back to the background"
        case .cancelled:          "the work was cancelled"
        }
    }

    private static func phrase(_ change: SeatTargetChange) -> String {
        switch change {
        case .requested:   "the lab asked for it"
        case .adopted:     "the window was adopted"
        case .detected:    "the seat recognised a window of the driven application"
        case .predecessor: "the previous target was destroyed"
        }
    }

    private static func phrase(_ refusal: WindowTransferRefusal) -> String {
        switch refusal {
        case .notMovable:                  "no accessibility element answers for it"
        case .tooLarge:                    "it does not fit on the background display and would not shrink"
        case .moveRefused:                 "the move, or one of the readings that confirm it, was refused"
        case .attemptsExhausted:           "the seat has spent its attempts on it"
        case .fullScreenTransferDisabled:  "it is in native fullscreen and fullscreen transfer is off"
        case .fullScreenNotSupported:      "it is in native fullscreen and cannot leave it"
        case .fullScreenSpaceStillOnScreen:"it is in a fullscreen Space that is still on screen"
        }
    }

    // MARK: Fields as text

    private static func rectangle(_ value: CGRect) -> String {
        "[\(Int(value.minX)),\(Int(value.minY)) \(Int(value.width))×\(Int(value.height))]"
    }

    /// One window named the way every other sentence here names one, so a
    /// suspension and an adoption failure about the same window read alike.
    private static func surface(_ identity: WindowIdentity) -> String {
        "window \(identity.windowNumber) of PID \(identity.processID)"
    }

    private static func size(_ value: CGRect) -> String {
        size(value.size)
    }

    private static func size(_ value: CGSize) -> String {
        "\(Int(value.width))×\(Int(value.height)) pt"
    }

    private static func restoration(_ outcome: WindowReleaseOutcome) -> String {
        switch outcome {
        case .returned:             "was put back where it was"
        case .leftOnVirtualDisplay: "was left on the background display"
        case .vanished:             "no longer exists"
        case .refused:              "could not be put back"
        case .returnsWhenShown:     "is hidden by its application and goes back when it is shown again"
        }
    }
}
