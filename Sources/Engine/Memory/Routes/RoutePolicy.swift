//
//  RoutePolicy.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

/// RoutePolicy holds the limits and thresholds of procedural memory.
public enum RoutePolicy {

    public static let maxSteps = 10
    public static let maxRoutesPerApp = 50
    public static let staleAfterDays: Double = 30
    /// Consecutive replay failures that demote a route.
    public static let forgetAfterFails = 2
    /// Independent confirmations that stand in for a missing proof on a row written before proofs.
    public static let confirmationsInsteadOfProof = 2
    /// Fewer verified steps than this is an experience, not a procedure.
    public static let minimumRouteSteps = 2
}
