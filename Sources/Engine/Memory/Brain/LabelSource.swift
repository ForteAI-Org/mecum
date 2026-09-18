//
//  LabelSource.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

/// LabelSource is the provenance of an anchor's name. An observed name came from perception and
/// updates freely; a name a model or a person assigned is immutable to observation churn, because a
/// misread caption must never overwrite an approved name. A legacy row without a source behaves as
/// observed.
public enum LabelSource: String, Sendable, Codable {

    case observed
    case llm
    case user
}
