//
//  WindowIdentityWitness.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import PrivateSymbols
import SeatCore

/// WindowIdentityWitness caches the Window Identity Facility gate and symbol
/// table for repeated bounded ownership reads. Capture uses one witness per
/// stream, so a 60 fps identity check does not reload the Ledger or repeat
/// primitive resolution for every Frame.
nonisolated package struct WindowIdentityWitness: Sendable {

    private let table: SymbolTable
    private let gate : FacilityGate

    package init(allowUnvalidatedBuild: Bool = false) {
        let table = SymbolTable.shared
        self.table = table
        self.gate  = FacilityGate.current(
            facility             : .windowIdentity,
            allowUnvalidatedBuild: allowUnvalidatedBuild,
            table                : table
        )
    }

    package func identity(of windowNumber: Int) -> WindowIdentity? {
        WindowServerProbe.identity(
            of         : windowNumber,
            table      : table,
            validatedBy: gate
        )
    }
}
