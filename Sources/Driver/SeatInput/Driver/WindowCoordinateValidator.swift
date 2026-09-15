//
//  WindowCoordinateValidator.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import CoreGraphics
import SeatCore

/// WindowCoordinateValidator checks and, for a pure window translation, updates
/// every mouse point before `InputEvents` constructs the first native event.
/// It is pure so refusal behavior can be tested without posting anything.
nonisolated package enum WindowCoordinateValidator {

    private static let pointTolerance: CGFloat = 0.000_001

    /// requireObservations rejects legacy mouse coordinates before a geometry
    /// query can hide the real refusal behind unrelated system availability.
    package static func requireObservations(in command: InputCommand) throws {
        switch command {
        case .key, .text, .insertText:
            return
        case .click(let location, _), .scroll(let location, _):
            guard location.observedGeometry != nil else {
                throw InputFailure.coordinateObservationMissing
            }
        case .drag(let points, _):
            guard points.allSatisfy({ $0.observedGeometry != nil }) else {
                throw InputFailure.coordinateObservationMissing
            }
        }
    }

    package static func validate(
        _ command: InputCommand,
        against current: WindowGeometryObservation
    ) throws -> InputCommand {
        switch command {
        case .key, .text, .insertText:
            return command

        case .click(let location, let button):
            return .click(try validate(location, against: current), button: button)

        case .drag(let points, let flags):
            let validated = try points.map { try validate($0, against: current) }
            return .drag(points: validated, flags: flags)

        case .scroll(let location, let deltaY):
            return .scroll(try validate(location, against: current), deltaY: deltaY)
        }
    }

    /// requireUnchanged is the final pre-post check after native events have
    /// already been built and routed. At that point even a safe translation is
    /// refused: rebuilding is a new attempt, and no event has left the process.
    package static func requireUnchanged(
        _ expected: WindowGeometryObservation,
        current   : WindowGeometryObservation
    ) throws {
        guard expected.window.identity == current.window.identity else {
            throw InputFailure.coordinateIdentityChanged(
                expected: expected.window.identity,
                observed: current.window.identity
            )
        }
        guard expected.window.frame == current.window.frame else {
            throw InputFailure.coordinateGeometryChanged(
                observed: expected.window.frame,
                current : current.window.frame
            )
        }
        guard expected.scaleFactor == current.scaleFactor else {
            throw InputFailure.coordinateScaleChanged(
                observed: expected.scaleFactor,
                current : current.scaleFactor
            )
        }
    }

    private static func validate(
        _ location: InputLocation,
        against current: WindowGeometryObservation
    ) throws -> InputLocation {
        guard location.isFinite else { throw InputFailure.invalidLocation }
        guard let observed = location.observedGeometry else {
            throw InputFailure.coordinateObservationMissing
        }
        guard let expectedIdentity = observed.window.identity,
              let currentIdentity  = current.window.identity,
              expectedIdentity == currentIdentity
        else {
            throw InputFailure.coordinateIdentityChanged(
                expected: observed.window.identity,
                observed: current.window.identity
            )
        }

        let observedFrame = observed.window.frame
        let currentFrame  = current.window.frame
        guard observedFrame.hasFinitePositiveArea,
              currentFrame.hasFinitePositiveArea
        else {
            throw InputFailure.invalidCoordinateGeometry
        }
        guard observedFrame.size == currentFrame.size
        else {
            throw InputFailure.coordinateGeometryChanged(
                observed: observedFrame,
                current : currentFrame
            )
        }
        guard observed.scaleFactor == current.scaleFactor else {
            throw InputFailure.coordinateScaleChanged(
                observed: observed.scaleFactor,
                current : current.scaleFactor
            )
        }

        let local = location.windowPointFromTop
        guard local.x >= 0, local.y >= 0,
              local.x < observedFrame.width,
              local.y < observedFrame.height,
              local.x < currentFrame.width,
              local.y < currentFrame.height
        else {
            throw InputFailure.coordinateOutsideObservedWindow(
                point: local,
                frame: observedFrame
            )
        }

        let expectedScreenPoint = CGPoint(
            x: observedFrame.minX + local.x,
            y: observedFrame.minY + local.y
        )
        guard expectedScreenPoint.x.isFinite,
              expectedScreenPoint.y.isFinite,
              abs(expectedScreenPoint.x - location.screenPoint.x) <= pointTolerance,
              abs(expectedScreenPoint.y - location.screenPoint.y) <= pointTolerance
        else {
            throw InputFailure.coordinateSpacesDisagree
        }

        let translatedScreenPoint = CGPoint(
            x: currentFrame.minX + local.x,
            y: currentFrame.minY + local.y
        )
        guard translatedScreenPoint.x.isFinite, translatedScreenPoint.y.isFinite else {
            throw InputFailure.invalidLocation
        }
        return InputLocation(
            screenPoint       : translatedScreenPoint,
            windowPointFromTop: local,
            observedIn        : current
        )
    }
}
