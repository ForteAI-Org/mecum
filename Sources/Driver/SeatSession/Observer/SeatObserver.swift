//
//  SeatObserver.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import AppKit
import CoreGraphics
import CursorGuard
import Foundation
import SeatCore

/// SeatObserver watches the User Seat while the seat is held, so that a
/// voluntary change by the person is told apart from an anomaly of the target.
/// It carries no accessibility focus sentinel: reading a focused element is
/// observation, and observation is the consumer's layer (ADR 0004), so that half
/// stays outside the kit.
///
/// **It reports and it does not attribute.** A frontmost change does not prove
/// who caused it. Every field it produces is evidence for the consumer's own
/// verdict, and the one field that is a verdict, the cursor audit's `passed`,
/// is decided by correlating the cursor with the fence's HID trace rather than
/// by an opinion.
///
/// The sampling stays at 20 ms and did not move to the watchdog's heartbeat,
/// on purpose. The two answer different questions: the watchdog asks "are the
/// seat's invariants still true", forever, which is why its cost matters; the
/// observer asks "what moved during this action", for the length of one hold,
/// where a coarse sample would miss the very movement it exists to catch.
public final class SeatObserver {

    /// The window being acted on.
    private let target: WindowReference

    /// The person's frontmost application when the hold started, nil when
    /// there was none.
    private let expectedFrontmostProcessID: Int32?

    private let expectedMainDisplayID: CGDirectDisplayID
    private let sensing              : any SeatSensing

    /// The fence and the marker of this hold, when an audit is running. The
    /// audit itself lives **inside** the fence: only the reference and the
    /// marker are here, so every access goes through the fence's own lock
    /// instead of sharing the object between the tap's thread and the main one:
    /// the tap writing while a main-thread reader reads is the race this avoids.
    private let audit: (fence: CursorFence, marker: Int64)?

    /// Whether the person's own context is part of the verdict. It is not, while
    /// a consumer's loop runs alongside the person: they are expected to keep
    /// working, so their application switches and Space changes are not
    /// anomalies. Identity and geometry are never relaxed.
    private let recordsUserContext: Bool

    /// The seat's own guard, asked every third sample. It is a closure and not
    /// a stored `SeatGuard` because the readings it needs are the seat's, and
    /// the seat is the one holding them.
    private let issueCheck: (() -> [SeatIssue])?

    private var baselineCursor: CGPoint
    private var timer         : Timer?
    private var notifications : [any NSObjectProtocol] = []
    private var sampleCount   = 0

    private var frontmostApplicationChanged = false
    private var activeSpaceChanged          = false
    private var mainDisplayChanged          = false
    private var windowOrderChanged          = false
    private var targetMovedAheadOfUserApp   = false
    private var targetWasActivated          = false
    private var detectedIssues  : [SeatIssue] = []
    private var maximumDistance : CGFloat     = 0

    private let baselineWindowOrder: Int?

    /// Whether the target window was behind the person's application when the
    /// hold started. `nil` means the relation could not be established, which
    /// is not the same as "it was not".
    public let targetStartedBehindUserApp: Bool?

    public init(
        target                    : WindowReference,
        expectedFrontmostProcessID: Int32?,
        baselineCursor            : CGPoint,
        sensing                   : any SeatSensing,
        audit                     : (fence: CursorFence, marker: Int64)? = nil,
        recordsUserContext        : Bool = true,
        issueCheck                : (() -> [SeatIssue])? = nil
    ) {
        self.target                     = target
        self.expectedFrontmostProcessID = expectedFrontmostProcessID
        self.baselineCursor             = baselineCursor
        self.sensing                    = sensing
        self.audit                      = audit
        self.recordsUserContext         = recordsUserContext
        self.issueCheck                 = issueCheck
        self.expectedMainDisplayID      = sensing.mainDisplayID
        self.baselineWindowOrder         = sensing.windowOrderIndex(of: target.windowNumber)

        self.targetStartedBehindUserApp = expectedFrontmostProcessID.flatMap {
            sensing.isBehindFrontmostWindow(windowNumber: target.windowNumber, ownedBy: $0)
        }
    }

    // MARK: The interval

    /// start begins observing. The two workspace notifications are the only
    /// event-driven half: an activation and a Space change are published, so
    /// they are not polled.
    public func start() {

        let center = NSWorkspace.shared.notificationCenter

        notifications.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object : nil,
            queue  : .main
        ) { [weak self] notification in

            guard let self,
                  let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                      as? NSRunningApplication
            else { return }

            MainActor.assumeIsolated {
                if application.processIdentifier == self.target.processID {
                    self.targetWasActivated = true
                }
                if self.recordsUserContext,
                   application.processIdentifier != self.expectedFrontmostProcessID {
                    self.frontmostApplicationChanged = true
                }
            }
        })

        notifications.append(center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object : nil,
            queue  : .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.recordsUserContext else { return }
                self.activeSpaceChanged = true
            }
        })

        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    /// observation is the interval so far, without the cursor audit's verdict:
    /// reading that verdict ends the audit, and the audit spans the whole hold
    /// rather than one Command inside it. `conclude()` is where it arrives.
    public func observation() -> SeatObservation {

        sample()

        return SeatObservation(
            frontmostApplicationChanged: frontmostApplicationChanged,
            activeSpaceChanged         : activeSpaceChanged,
            mainDisplayChanged         : mainDisplayChanged,
            maximumCursorDistance      : maximumDistance,
            windowOrderChanged         : windowOrderChanged,
            targetMovedAheadOfUserApp  : targetMovedAheadOfUserApp,
            cursorAudit                : nil
        )
    }

    /// issues re-reads the seat's guard now and adds `targetActivated` when the
    /// person activated the target during the interval, which a reading taken
    /// after they left it would no longer show.
    public func issues() -> [SeatIssue] {

        sample()

        var issues = detectedIssues

        if targetWasActivated, !issues.contains(.targetActivated) {
            issues.append(.targetActivated)
        }

        return issues
    }

    /// finishCursorSampling closes the sampled interval after the last Command
    /// and its settle. The tap stays attached, so the callbacks of the last
    /// sample can still arrive and be reconciled: the caller waits
    /// `CursorMotionAudit.deliveryPublicationLimit` before concluding.
    public func finishCursorSampling() {

        sample()

        guard let audit else { return }
        audit.fence.finishAuditSampling(forSyntheticMarker: audit.marker)
    }

    /// Moves the cursor baseline, for a caller that legitimately warped the
    /// cursor and does not want the warp counted as movement.
    public func resetCursorMeasurement(to cursor: CGPoint) {
        baselineCursor  = cursor
        maximumDistance = 0
    }

    /// conclude stops observing and answers the whole interval, cursor audit
    /// included. Calling it twice answers the same fields with no audit the
    /// second time: an audit is removed from the fence when it is read.
    @discardableResult
    public func conclude() -> SeatObservation {

        sample()

        timer?.invalidate()
        timer = nil

        let center = NSWorkspace.shared.notificationCenter
        notifications.forEach(center.removeObserver)
        notifications.removeAll()

        return SeatObservation(
            frontmostApplicationChanged: frontmostApplicationChanged,
            activeSpaceChanged         : activeSpaceChanged,
            mainDisplayChanged         : mainDisplayChanged,
            maximumCursorDistance      : maximumDistance,
            windowOrderChanged         : windowOrderChanged,
            targetMovedAheadOfUserApp  : targetMovedAheadOfUserApp,
            cursorAudit                : audit.flatMap {
                $0.fence.endAudit(forSyntheticMarker: $0.marker)
            }
        )
    }

    // MARK: One sample

    /// Every sample reads the cheap facts; the ones that cost a window server
    /// round trip run every third sample, which is the measured cadence.
    private func sample() {

        if sensing.isActive(processID: target.processID) == true {
            targetWasActivated = true
        }

        if recordsUserContext, sensing.frontmostProcessID != expectedFrontmostProcessID {
            frontmostApplicationChanged = true
        }

        if sensing.mainDisplayID != expectedMainDisplayID {
            mainDisplayChanged = true
        }

        if let audit {
            audit.fence.sampleAudit(
                forSyntheticMarker: audit.marker,
                point             : sensing.cursorLocation,
                timestamp         : DispatchTime.now().uptimeNanoseconds
            )
        }

        if let cursor = sensing.cursorLocation {
            maximumDistance = max(
                maximumDistance,
                hypot(cursor.x - baselineCursor.x, cursor.y - baselineCursor.y)
            )
        }

        sampleCount += 1
        guard sampleCount.isMultiple(of: 3) else { return }

        if detectedIssues.isEmpty, let issueCheck {
            detectedIssues = issueCheck()
        }

        guard recordsUserContext else { return }

        if sensing.windowOrderIndex(of: target.windowNumber) != baselineWindowOrder {
            windowOrderChanged = true
        }

        if targetStartedBehindUserApp == true, let expectedFrontmostProcessID,
           sensing.isBehindFrontmostWindow(
               windowNumber: target.windowNumber,
               ownedBy     : expectedFrontmostProcessID
           ) == false {
            targetMovedAheadOfUserApp = true
        }
    }

    /// `isolated deinit` so that the timer and the workspace observers are
    /// torn down on the actor that created them. A nonisolated `deinit` cannot
    /// touch either of them, and leaving a repeating `Timer` behind would keep
    /// the observer alive and sampling after the hold is over.
    isolated deinit {
        timer?.invalidate()
        let center = NSWorkspace.shared.notificationCenter
        notifications.forEach(center.removeObserver)
    }
}
