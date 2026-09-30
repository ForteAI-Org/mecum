//
//  HiddenWindowReturns.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/09/2026.
//

import CoreGraphics
import Foundation
import os
import SeatCore
import WindowPlacement

/// HiddenWindowReturns puts back the windows a release could not, because their
/// application had ordered them out. A hidden window answers no accessibility
/// element, so nothing can write its position, and the application shows it
/// again later at the virtual display's coordinates, where no screen may be.
/// Measured with DaVinci Resolve: its Project Manager and New Project dialog,
/// hidden when a project opens, stayed at 2337,1382 after the seat was gone.
///
/// It outlives the seat that owed the return, because the display that seat
/// stood on is usually gone by the time the window is shown again. A window is
/// put back once the window server lists it again, and forgotten when it is
/// destroyed, when its number names another window, or when a seat takes it
/// in, which then owes its return itself.
public final class HiddenWindowReturns {

    public static let shared = HiddenWindowReturns()

    private static let log = Logger(subsystem: "dev.forte.AgentSeatKit", category: "Session")

    /// Moves written for one window before it is given up on: an application
    /// that keeps a position of its own for a window is not fought.
    static let moveLimit = 3

    private struct Owed {
        let window: AdoptedWindow
        var moves = 0
    }

    private var owed: [Int: Owed] = [:]
    private var watch: Task<Void, Never>?
    private let placing : any WindowPlacing
    private let geometry: (Int) -> WindowReference?
    private let identity: (Int) -> WindowIdentity?
    private let cadence : Duration

    init(
        placing : any WindowPlacing = SystemWindowPlacing(),
        geometry: @escaping (Int) -> WindowReference? = { WindowServerProbe.geometry(of: $0) },
        identity: @escaping (Int) -> WindowIdentity? = { WindowServerProbe.identity(of: $0) },
        cadence : Duration = .seconds(1)
    ) {
        self.placing  = placing
        self.geometry = geometry
        self.identity = identity
        self.cadence  = cadence
    }

    /// The windows still owed a return, by Window ID.
    var owedWindowNumbers: [Int] { owed.keys.sorted() }

    func owe(_ window: AdoptedWindow) {
        owed[window.id] = Owed(window: window)
        Self.log.info("""
            window \(window.id, privacy: .public) is hidden by its application: \
            it goes back when it is shown again
            """)
        guard watch == nil else { return }
        watch = Task { [weak self] in
            while let cadence = self?.cadence, self?.owed.isEmpty == false {
                try? await Task.sleep(for: cadence)
                self?.check()
            }
            self?.watch = nil
        }
    }

    /// A seat took the window in, and its release owes the return now.
    func forgive(_ windowNumber: Int) {
        owed[windowNumber] = nil
    }

    /// One reading of every owed window.
    func check() {
        for (number, entry) in owed {
            guard let expected = entry.window.reference.identity, identity(number) == expected else {
                owed[number] = nil
                continue
            }
            guard let server = geometry(number) else { continue }

            let home = (entry.window.originalServerFrame ?? entry.window.originalFrame).origin
            let tolerance = VirtualWindowPlacementCheck.crossSourceTolerance
            if abs(server.frame.minX - home.x) <= tolerance, abs(server.frame.minY - home.y) <= tolerance {
                Self.log.info("window \(number, privacy: .public) was shown again and is back where it was")
                owed[number] = nil
                continue
            }
            guard entry.moves < Self.moveLimit else {
                Self.log.info("""
                    window \(number, privacy: .public) was shown again and would not go back \
                    after \(Self.moveLimit, privacy: .public) moves: left where its application put it
                    """)
                owed[number] = nil
                continue
            }
            owed[number]?.moves += 1
            do { try placing.move(server, to: entry.window.originalFrame.origin) }
            catch {
                Self.log.info("""
                    window \(number, privacy: .public) was shown again and could not be moved \
                    back yet: \(String(describing: error), privacy: .public)
                    """)
            }
        }
    }
}
