//
//  RemoteWindowProbe.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 19/09/2026.
//

import CoreGraphics
import Darwin
import PrivateSymbols
import SeatCore

/// RemoteWindowProbe reads the geometry of a window the public window list does
/// not enumerate, which is what the content window of an out of process panel
/// is on this build.
///
/// `WindowServerProbe.geometry(of:)` joins the identity chain to a
/// `CGWindowListCopyWindowInfo` row and answers `nil` when there is no row.
/// Measured on 26A428 against Slack's open panel, the panel's content window had
/// no row at all while `SLSGetWindowOwner` resolved its whole identity chain and
/// `SLSGetWindowBounds` answered its frame. Absence from the public list is
/// therefore not a licence to skip the geometry: it is the reason this reading
/// exists, and it carries the checks the public path gets from its row.
///
/// What it adds to one bounds call:
///
/// - the identity chain is read **before and after** the bounds, and the two
///   readings must be the same whole `WindowIdentity`, so a Window ID handed to
///   another connection or another process lifetime between the two reads is
///   refused rather than measured;
/// - the rectangle must be finite and non empty;
/// - it must lie inside the surface the caller attested it as the content of, so
///   a second panel of the same service, drawn elsewhere, cannot answer here;
/// - one display must contain it at one unambiguous scale, which is the same
///   rule `WindowGeometryProbe` applies to a listed window.
///
/// It is not a second way to reach an ordinary window. A window the public list
/// enumerates keeps the public reading and its cross check.
nonisolated public enum RemoteWindowProbe {

    /// The geometry of one unlisted window, or `nil` when any link of the
    /// chain, the rectangle or the containment could not be proved.
    ///
    /// `containedIn` is the attested surface the window is the content of, and
    /// `containmentTolerance` is the slack allowed on that containment: the two
    /// rectangles come from two window server calls taken at two instants, so
    /// the knob exists for a build that needs one. It is zero here because no
    /// measurement has asked for more.
    public static func observation(
        of windowNumber      : Int,
        containedIn container: CGRect,
        containmentTolerance : CGFloat = 0,
        allowUnvalidatedBuild: Bool = false,
        table                : SymbolTable = .shared
    ) -> WindowGeometryObservation? {

        guard container.hasFinitePositiveArea,
              containmentTolerance.isFinite, containmentTolerance >= 0,
              let observation = unlisted(
                  of                   : windowNumber,
                  allowUnvalidatedBuild: allowUnvalidatedBuild,
                  table                : table
              ),
              container.insetBy(
                  dx: -containmentTolerance,
                  dy: -containmentTolerance
              ).contains(observation.window.frame)
        else { return nil }

        return observation
    }

    /// The geometry of one window whether or not the public list enumerates it,
    /// for a recipient whose relation to its surface somebody else has already
    /// attested.
    ///
    /// This is what the Background Driver re-reads its recipient through. The
    /// containment leg is deliberately absent here and is not a check this path
    /// dropped: it is the discovery's leg, stated once against the surface, and
    /// re-asking it in the driver would need the driver to carry a surface it
    /// knows nothing about. What the driver compares instead is the frame it
    /// built the Command against with the frame it reads back, which is the
    /// stronger statement for a window already attested.
    ///
    /// The public reading is asked first and keeps its own cross check. Only a
    /// window with no row at all reaches the unlisted reading.
    public static func recipientGeometry(
        of window            : WindowReference,
        allowUnvalidatedBuild: Bool = false,
        table                : SymbolTable = .shared
    ) -> WindowGeometryObservation? {

        guard window.identity != nil else { return nil }
        return recipientGeometry(
            expected: window,
            listed: WindowServerProbe.geometryReading(
                of: window.windowNumber,
                allowUnvalidatedBuild: allowUnvalidatedBuild,
                table: table
            ),
            unlisted: {
                unlisted(
                    of: window.windowNumber,
                    allowUnvalidatedBuild: allowUnvalidatedBuild,
                    table: table
                )
            },
            scaleFactor: WindowGeometryProbe.scaleFactor(for:),
            sequence: mach_absolute_time()
        )
    }

    /// Decision table shared by the system path and unit tests. A listed row
    /// that disagrees is a refusal, never a reason to ask SLS for a second,
    /// potentially different window.
    package static func recipientGeometry(
        expected: WindowReference,
        listed: WindowServerProbe.GeometryReading,
        unlisted: () -> WindowGeometryObservation?,
        scaleFactor: (CGRect) -> CGFloat?,
        sequence: UInt64
    ) -> WindowGeometryObservation? {
        guard let identity = expected.identity else { return nil }
        switch listed {
        case .present(let current):
            guard current.identity == identity,
                  let scale = scaleFactor(current.frame)
            else { return nil }
            return WindowGeometryObservation(
                window: current,
                scaleFactor: scale,
                version: GeometryObservationVersion(observerGeneration: 0, sequence: sequence)
            )
        case .absent:
            let observation = unlisted()
            guard observation?.window.identity == identity else { return nil }
            return observation
        case .refused:
            return nil
        }
    }

    /// The reading itself, with the window server behind each of its three
    /// questions supplied by the caller. The shipping path passes the kit's own
    /// chain; the Unit tier passes functions it can make disagree, which is the
    /// only way to prove what a reused Window ID and a replaced helper do here.
    package static func observation(
        of windowNumber      : Int,
        containedIn container: CGRect,
        containmentTolerance : CGFloat,
        bounds               : (UInt32) -> CGRect?,
        identity             : (Int) -> WindowIdentity?,
        scaleFactor          : (CGRect) -> CGFloat?,
        sequence             : UInt64
    ) -> WindowGeometryObservation? {

        guard container.hasFinitePositiveArea,
              containmentTolerance.isFinite, containmentTolerance >= 0,
              let observation = unlisted(
                  of         : windowNumber,
                  bounds     : bounds,
                  identity   : identity,
                  scaleFactor: scaleFactor,
                  sequence   : sequence
              ),
              container.insetBy(
                  dx: -containmentTolerance,
                  dy: -containmentTolerance
              ).contains(observation.window.frame)
        else { return nil }

        return observation
    }

    /// Identity, rectangle and scale for one unlisted window, with no statement
    /// about what the window is drawn inside. Every caller that has a surface to
    /// state that against goes through `observation(of:containedIn:)`.
    package static func unlisted(
        of windowNumber: Int,
        bounds         : (UInt32) -> CGRect?,
        identity       : (Int) -> WindowIdentity?,
        scaleFactor    : (CGRect) -> CGFloat?,
        sequence       : UInt64
    ) -> WindowGeometryObservation? {

        guard let windowID = UInt32(exactly: windowNumber), windowID != 0,
              let first = identity(windowNumber),
              first.windowNumber == windowNumber,
              let frame = bounds(windowID),
              frame.hasFinitePositiveArea,
              let scaleFactor = scaleFactor(frame)
        else { return nil }

        // The second reading closes the window the bounds call leaves open: an
        // id reassigned between the two answers a frame nobody may act on.
        guard let second = identity(windowNumber), second == first else { return nil }

        return WindowGeometryObservation(
            window     : WindowReference(identity: first, frame: frame),
            scaleFactor: scaleFactor,
            version    : GeometryObservationVersion(
                observerGeneration: 0,
                sequence          : sequence
            )
        )
    }

    /// The unlisted reading against the running system's own window server.
    private static func unlisted(
        of windowNumber      : Int,
        allowUnvalidatedBuild: Bool,
        table                : SymbolTable
    ) -> WindowGeometryObservation? {

        let gate = FacilityGate.current(
            facility             : .remoteWindowGeometry,
            allowUnvalidatedBuild: allowUnvalidatedBuild,
            table                : table
        )
        guard gate.mayAct,
              let mainConnectionID = table.function(
                  .mainConnectionID,
                  as: SymbolABI.MainConnectionID.self
              ),
              let getWindowBounds = table.function(
                  .getWindowBounds,
                  as: SymbolABI.GetWindowBounds.self
              )
        else { return nil }

        let connectionID = mainConnectionID()
        guard connectionID != 0 else { return nil }

        let identityGate = FacilityGate.current(
            facility             : .windowIdentity,
            allowUnvalidatedBuild: allowUnvalidatedBuild,
            table                : table
        )
        return unlisted(
            of         : windowNumber,
            bounds     : { windowID in
                var frame = CGRect.zero
                guard getWindowBounds(connectionID, windowID, &frame) == 0 else { return nil }
                return frame
            },
            identity   : {
                WindowServerProbe.identity(of: $0, table: table, validatedBy: identityGate)
            },
            scaleFactor: WindowGeometryProbe.scaleFactor(for:),
            sequence   : mach_absolute_time()
        )
    }
}
