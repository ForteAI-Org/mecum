//
//  WorkerAgentEvent.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import ChatCore
import CLIProviders
import Foundation

/// WorkerAgentEvent is what one agent turn reports, in the order it happened:
/// the provider's own events, and each line Mecum's tools record.
enum WorkerAgentEvent: Sendable, Equatable {

    /// A decoded line of the provider's JSONL stream.
    case provider(ProviderEvent)

    /// One tool record, as `mecum chat` prints it: the call with its
    /// arguments, then its result or its error.
    case tool(String)

    /// The provider child the turn spawned, before its first event. It is
    /// recorded so a launch after a crash can end a child left running.
    case processStarted(ChildProcessIdentity)

    /// What the turn cost, once, after its other events and however it ended,
    /// when the provider reported any count. The host makes it from the
    /// provider's `.usage`, which never reaches the recorder itself.
    case usage(TurnUsage)
}
