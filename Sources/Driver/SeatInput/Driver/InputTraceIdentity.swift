//
//  InputTraceIdentity.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import Dispatch
import SeatCore
import Synchronization

/// InputTraceIdentity creates process-unique Command identifiers before an
/// actor hop. The lock protects one integer for a few instructions and is never
/// held while a Command waits or calls the system.
nonisolated package enum InputTraceIdentity {

    private static let lastCommandID = Mutex<UInt64>(0)

    package static func submitted(
        command      : InputCommand,
        window       : WindowReference,
        correlationID: Int64
    ) -> InputTraceContext {
        let submittedAt = DispatchTime.now().uptimeNanoseconds
        let commandID = lastCommandID.withLock { value in
            value &+= 1
            return value
        }
        return InputTraceContext(
            commandID             : commandID,
            commandKind           : command.kind,
            processID             : window.processID,
            windowNumber          : window.windowNumber,
            correlationID         : correlationID,
            submittedAtNanoseconds: submittedAt
        )
    }
}
