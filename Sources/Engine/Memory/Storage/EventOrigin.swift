//
//  EventOrigin.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 10/10/2026.
//

/// EventOrigin is where a fact of the shared archive came from when an earlier archive gave it (an
/// external client's private archive, unified): the origin, where it was, the fact's identity there and
/// how it came in. A fact the shared archive's own producers wrote has none; a fact two origins both
/// held, a proven duplicate, has one per origin.
public struct EventOrigin: Sendable, Equatable {

    /// Disposition is how the fact came in: as it was, as a proven duplicate of one already here (it adds
    /// no evidence), or under a new identity because its own was another fact's here.
    public enum Disposition: String, Sendable, Equatable {
        case added, duplicate, renamed
    }

    public let originID: String
    public let location: String
    public let sourceEventID: String
    public let disposition: Disposition

    public init(originID: String, location: String, sourceEventID: String, disposition: Disposition) {
        self.originID      = originID
        self.location      = location
        self.sourceEventID = sourceEventID
        self.disposition   = disposition
    }
}
