//
//  ModelTransportError.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation

/// What a conversational turn fails with. Provider-level failures (no key, a
/// non-2xx status, an answer that makes no sense) stay `ProviderError`; these
/// are the transport's own.
public enum ModelTransportError: LocalizedError, Equatable {

    /// The transport declared it cannot carry a conversational turn. Thrown
    /// before any request is made, with the reason the transport declared.
    case streamingUnsupported(String)

    /// The provider stopped sending before it declared the turn finished. What
    /// arrived is a fragment and is reported as one, never as the answer.
    case streamEndedEarly(deltas: Int)

    /// The provider ended the turn, but for a reason that is not a whole answer:
    /// the output limit, a safety filter, or a reason this module does not know.
    /// The `deltas` already delivered are a fragment. Distinct from
    /// `streamEndedEarly`, where the provider never said it ended at all.
    case stoppedShort(reason: String?, deltas: Int)

    public var errorDescription: String? {
        switch self {
        case .streamingUnsupported(let reason):
            "This model cannot hold a streamed conversation: \(reason)."
        case .streamEndedEarly:
            "The provider ended the response before it finished."
        case .stoppedShort(let reason, _):
            "The provider ended the response early. Details: \(reason ?? "No reason provided")"
        }
    }
}
