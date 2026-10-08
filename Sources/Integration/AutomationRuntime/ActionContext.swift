//
//  ActionContext.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import Foundation
import Memory

/// ActionContext is who is acting and under which trace, passed explicitly with every call a session
/// performs: the event the call is recorded as, its producer (`source`, `streamID`: the app's worker,
/// the chat's worker, a command line invocation), the trace it belongs to (a message, a conversation,
/// an invocation), the session it names and, for a batch step, its parent and position. Nothing here
/// is read from a global: the producer that makes the call makes the context, and the recorder that
/// writes the call's samples and learning gets it with the call.
nonisolated public struct ActionContext: Sendable, Equatable {

    public let eventID: String
    public let source: MemoryEventSource
    public let streamID: String
    public let traceID: String?
    public let sessionID: String?
    public let parentEventID: String?
    public let parentPosition: Int?

    /// The call this context's observation was taken for (`another(sessionID:)`): the durable link
    /// from a session's own observation to its `open_session`, kept on the event. Nil for a call.
    public let originEventID: String?

    public init(
        eventID       : String = UUID().uuidString,
        source        : MemoryEventSource,
        streamID      : String,
        traceID       : String? = nil,
        sessionID     : String? = nil,
        parentEventID : String? = nil,
        parentPosition: Int? = nil,
        originEventID : String? = nil
    ) {
        self.eventID        = eventID
        self.source         = source
        self.streamID       = streamID
        self.traceID        = traceID
        self.sessionID      = sessionID
        self.parentEventID  = parentEventID
        self.parentPosition = parentPosition
        self.originEventID  = originEventID
    }

    /// The context of a batch's step at `position`: the batch's producer, trace and session, under
    /// the batch's event.
    public func child(_ position: Int, eventID: String = UUID().uuidString) -> ActionContext {
        ActionContext(
            eventID: eventID, source: source, streamID: streamID, traceID: traceID, sessionID: sessionID,
            parentEventID: self.eventID, parentPosition: position
        )
    }

    /// A context for the observation a session takes on its own once `open_session` has opened the
    /// application, which the call's own event could not name when it was planned: another event of
    /// the same producer and trace, under `sessionID`, whose origin is this call. One trace may hold
    /// many openings; the origin says which one, durably.
    public func another(eventID: String = UUID().uuidString, sessionID: String?) -> ActionContext {
        ActionContext(eventID: eventID, source: source, streamID: streamID, traceID: traceID, sessionID: sessionID,
                      originEventID: self.eventID)
    }

    /// The event this context's call is recorded as, at `occurredAtMS`, for `app` when the producer
    /// knows it. The capture status starts unknown and moves as samples arrive.
    public func event(
        app         : AppContextIdentity?,
        occurredAtMS: Int64,
        monotonicNS : Int64? = nil,
        kind        : MemoryEventKind = .action
    ) -> MemoryEventRecord {
        MemoryEventRecord(
            eventID       : eventID,
            source        : source,
            streamID      : streamID,
            traceID       : traceID,
            sessionID     : sessionID,
            parentEventID : parentEventID,
            parentPosition: parentPosition,
            kind          : kind,
            app           : app,
            occurredAtMS  : occurredAtMS,
            monotonicNS   : monotonicNS,
            originEventID : originEventID
        )
    }
}
