//
//  AXNodeAttributeReader.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/09/2026.
//

import ApplicationServices
import Foundation

/// AXNodeAttributeReader turns one bulk accessibility read into values, one
/// failure and a list of warnings.
///
/// It exists because the bulk call and the per attribute call disagree about
/// what an error means. Some providers answer `AXError.failure` for optional
/// metadata while exposing role, children and value perfectly well: treating
/// that as a lost subtree throws away a whole window, so it is a warning and
/// the attribute is read again on its own. A missing **role** is the one thing
/// that really invalidates the node.
///
/// The reader takes the results instead of making the calls, so the whole
/// policy is testable without an application to read from.
nonisolated public enum AXNodeAttributeReader {

    public struct Result {

        public var values  : [String: AnyObject] = [:]
        public var failure : String?
        public var warnings: [String] = []

        public init(
            values  : [String: AnyObject] = [:],
            failure : String? = nil,
            warnings: [String] = []
        ) {
            self.values   = values
            self.failure  = failure
            self.warnings = warnings
        }
    }

    /// Reads `names` out of one bulk answer, retrying single attributes the
    /// bulk call reported as `failure`.
    public static func read(
        names     : [String],
        bulkError : AXError,
        bulkValues: [AnyObject]?,
        single    : (String) -> (AXError, AnyObject?)
    ) -> Result {

        guard [.success, .notImplemented, .attributeUnsupported, .failure].contains(bulkError) else {
            return Result(failure: "bulk accessibility read failed (\(bulkError.rawValue))")
        }
        var result = Result()
        let optionalMetadata = Set([kAXDescriptionAttribute, kAXHelpAttribute,
                                    kAXPlaceholderValueAttribute, kAXIdentifierAttribute])

        func accept(_ name: String, error: AXError, value: AnyObject?) {
            if error == .success {
                if let value, CFGetTypeID(value) != CFNullGetTypeID() { result.values[name] = value }
            } else if error != .noValue && error != .attributeUnsupported {
                let diagnostic = "accessibility attribute \(name) is unreadable (\(error.rawValue))"
                if error == .failure && optionalMetadata.contains(name) {
                    result.warnings.append(diagnostic)
                } else if result.failure == nil { result.failure = diagnostic }
            }
        }

        if bulkError == .success, let bulkValues, bulkValues.count == names.count {
            for (name, value) in zip(names, bulkValues) {
                if CFGetTypeID(value) == AXValueGetTypeID() {
                    let axValue = unsafeDowncast(value, to: AXValue.self)
                    if AXValueGetType(axValue) == .axError {
                        var error = AXError.success
                        guard AXValueGetValue(axValue, .axError, &error) else {
                            result.failure = "undecodable accessibility error for \(name)"
                            continue
                        }
                        if error == .failure {
                            let (retried, recovered) = single(name)
                            accept(name, error: retried, value: recovered)
                        } else { accept(name, error: error, value: nil) }
                        continue
                    }
                }
                accept(name, error: .success, value: value)
            }
        } else {
            for name in names {
                let (error, value) = single(name)
                accept(name, error: error, value: value)
            }
        }
        if result.values[kAXRoleAttribute] == nil { result.failure = "accessibility role unavailable" }
        return result
    }
}
