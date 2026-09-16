//
//  VirtualDisplaySuites.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import Testing

/// The parent of every Host suite that creates a virtual display, and the
/// reason it exists is that **only one can exist in a process at a time**.
///
/// The kit always presents the same identity triple, on purpose: a random
/// serial per run would leave the person's Mac with a growing pile of
/// remembered monitors (`VirtualDisplayConfiguration`). So a second `create`
/// while one is alive is refused with `displayCreationFailed`.
///
/// `.serialized` on a suite serializes that suite's own tests, and suites in
/// different files still run in parallel with each other: measured here as
/// three `displayCreationFailed` the moment a second display-creating suite was
/// added. Serialization applies to a suite **and its sub-suites**, so both of
/// them are declared inside this one.
@Suite("Suites that own a virtual display", .serialized)
enum VirtualDisplaySuites {}
