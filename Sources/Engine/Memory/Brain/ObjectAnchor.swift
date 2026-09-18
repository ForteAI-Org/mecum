//
//  ObjectAnchor.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import Foundation
import PerceptionCore

/// ObjectAnchor is one persistent object across many observations (the "Facebook switch" seen 47
/// times), robust to recognition jitter through aliases, to state changes through the states seen,
/// and to small moves through its typical bounds, which are a matching hint and never a target.
public struct ObjectAnchor: Sendable, Equatable, Codable {

    /// Opaque stable id.
    public var anchorKey: String
    public var kind: ElementKind
    /// The canonical label, empty when never labeled.
    public var label: String
    public var labelSource: LabelSource?
    /// Other labels seen for the same object.
    public var aliases: [String]
    /// The latest normalized bounds: a hint for matching and annotation, never a click target.
    public var boundsTypical: NormalizedRect
    /// Control state raw values to how often each was seen.
    public var statesSeen: [String: Int]
    public var groupID: UUID?
    public var seenCount: Int
    public var firstSeen: Date
    public var lastSeen: Date
    /// The brain's clock when this object was last matched; forgetting is measured in observations of
    /// the application, never in days. A legacy nil is stamped with the current epoch on the next ingest.
    public var lastSeenEpoch: Int?
    /// The window (title letters family) this object was last seen in; forgetting is scoped to it.
    public var window: String?

    public init(
        anchorKey    : String = UUID().uuidString,
        kind         : ElementKind,
        label        : String,
        labelSource  : LabelSource? = nil,
        aliases      : [String] = [],
        boundsTypical: NormalizedRect,
        statesSeen   : [String: Int] = [:],
        groupID      : UUID? = nil,
        seenCount    : Int = 1,
        firstSeen    : Date,
        lastSeen     : Date,
        lastSeenEpoch: Int? = nil,
        window       : String? = nil
    ) {
        self.anchorKey     = anchorKey
        self.kind          = kind
        self.label         = label
        self.labelSource   = labelSource
        self.aliases       = aliases
        self.boundsTypical = boundsTypical
        self.statesSeen    = statesSeen
        self.groupID       = groupID
        self.seenCount     = seenCount
        self.firstSeen     = firstSeen
        self.lastSeen      = lastSeen
        self.lastSeenEpoch = lastSeenEpoch
        self.window        = window
    }

    /// A name a person or a model assigned is knowledge the application cannot take back by not
    /// showing the control for a while: decay keeps it until a contradiction retracts it.
    public var isProtected: Bool { labelSource == .llm || labelSource == .user }

    /// True when the object has shown a definite on or off state.
    public var hasShownSwitchState: Bool {
        statesSeen.keys.contains(ControlState.on.rawValue) || statesSeen.keys.contains(ControlState.off.rawValue)
    }
}
