//
//  ObjectSource.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

/// ObjectSource says how an observed object's facts were obtained: `ax` from the accessibility tree,
/// structured and trusted; `cv` from pixels and text recognition, for applications whose tree is one
/// opaque group.
public enum ObjectSource: String, Sendable, Codable {

    case ax
    case cv
}
