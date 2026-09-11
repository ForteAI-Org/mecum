//
//  SeatGuard.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics

/// SeatGuard holds the identity a seat was fixed to, after the placement was
/// confirmed twice, and answers one question: is this still the same window, on
/// the same display, with the person's seat untouched. It compares identity and
/// geometry only. Focus events, application switches and Space changes in the
/// User Seat are the person's business and never enter the comparison.
public struct SeatGuard: Sendable, Equatable {

    /// The window the seat acts on, as it was when the placement was confirmed.
    public let target: WindowReference

    /// The virtual display the window was placed on.
    public let displayID: CGDirectDisplayID

    /// The bounds that display had when the coordinates were computed.
    public let displayBounds: CGRect

    public init(
        target        : WindowReference,
        displayID    : CGDirectDisplayID,
        displayBounds: CGRect
    ) {
        self.target        = target
        self.displayID     = displayID
        self.displayBounds = displayBounds
    }

    /// issues returns every Issue the current readings show, empty when the
    /// seat is intact. The caller supplies the readings: the guard performs no
    /// system call, so the same comparison runs in a test and in the watchdog.
    ///
    /// `observed` is an optional second reading of the same window from the
    /// consumer's observation layer, with `observedIsActive` its recorded
    /// activation. It is kept apart from the live `targetIsActive` on purpose:
    /// a reading taken while the app was active stays evidence even after the
    /// app went back to the background.
    public func issues(
        server              : WindowReference?,
        observed            : WindowReference? = nil,
        observedIsActive    : Bool = false,
        currentDisplayID    : CGDirectDisplayID?,
        currentDisplayBounds: CGRect,
        displayIsOnline     : Bool,
        cursorFenceIsActive : Bool,
        targetIsActive      : Bool?,
        frontmostProcessID  : Int32?,
        targetWasActivated  : Bool = false
    ) -> [SeatIssue] {
        
        var issues: [SeatIssue] = []
        
        if currentDisplayID != displayID || !displayIsOnline ||
           !VirtualWindowPlacementCheck.framesMatch(displayBounds, currentDisplayBounds) {
            issues.append(.displayChanged)
        }
        
        if !cursorFenceIsActive { issues.append(.fenceUnavailable) }
        
        if targetIsActive == nil {
            issues.append(.processUnavailable)
            
        } else if targetIsActive == true || frontmostProcessID == target.processID || targetWasActivated {
            issues.append(.targetActivated)
        }
        
        if let server {
            if !server.hasSameIdentity(as: target) {
                issues.append(.identityChanged)
            }
            
            if !VirtualWindowPlacementCheck.framesMatch(server.frame, target.frame)
                || !displayBounds.contains(server.frame) {
                issues.append(.geometryChanged)
            }
            
        } else { issues.append(.windowUnavailable) }
        
        if let observed {
            
            if !observed.hasSameIdentity(as: target) {
                issues.append(.identityChanged)
            }
            
            if observedIsActive { issues.append(.targetActivated) }
           
            if !VirtualWindowPlacementCheck.framesMatch(observed.frame, target.frame) {
                issues.append(.snapshotChanged)
            }
            
        }
        
        return issues
    }
}
