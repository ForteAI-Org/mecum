//
//  WorkspaceActivator.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import AppKit
import EngineCore
import Foundation

/// WorkspaceActivator fills `ApplicationActivating` with AppKit's workspace: which application is in
/// front, and raising one. Foreground only; a background seat never raises anything.
public struct WorkspaceActivator: ApplicationActivating {

    public init() {}

    public func frontmostProcessID() async -> pid_t? {
        await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    }

    public func activate(_ processID: pid_t) async {
        await MainActor.run { _ = NSRunningApplication(processIdentifier: processID)?.activate() }
    }
}
