//
//  SeatIssueLevel.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//


/// SeatIssueLevel says whose invariant an Issue broke, which decides who
/// fails: the host owns the virtual display and the shared fence, so a host
/// Issue takes every seat down with it; a seat Issue fails that seat alone and
/// leaves the host free to adopt something else; a window Issue is narrower
/// still and leaves the seat usable.
public enum SeatIssueLevel: String, Sendable, Equatable {
    case host
    case seat
    case window
}
