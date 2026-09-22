//
//  RawPlan.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

/// Raw plan as every provider returns it: `status`, `reason`, `steps` with a
/// `"<index>:<action>"` target. One schema, one parser, five transports.
struct RawPlan: Codable, Sendable {
    struct Step: Codable, Sendable {
        let target: String
        let text: String?
        /// The number of complete primary-button clicks for a `:click` step.
        /// Omitted means one; all other verbs leave it null.
        var count: Int? = nil
        let reason: String

        /// True only when the count asks for more than one click. Nil, 0 and 1
        /// all mean the same single press, and a structured-output mode that
        /// must emit the key fills one of those three on a step with nothing to
        /// click: refusing them refuses every plan the schema allows.
        var namesMultipleClicks: Bool { (count ?? 1) >= 2 }
    }
    let status: String
    let reason: String
    let steps: [Step]
    /// The application `status: "open"` asks for. Optional so a provider that
    /// leaves the key out entirely still decodes; validation is what refuses
    /// an open without a name.
    var application: String? = nil
}
