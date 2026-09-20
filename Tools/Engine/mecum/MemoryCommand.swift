import AutomationRuntime
//
//  MemoryCommand.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import AppKit
import FileKnowledge
import Foundation
import Memory
import PerceptionCore

/// MemoryCommand prints what memory holds for an application: the brain's size and clock, its most
/// established anchors with what they do, its groups, and its routes with their standing.
enum MemoryCommand {

    static func run(_ invocation: Invocation) async throws {
        let application = try ApplicationLookup.running(try invocation.positional(0, "<app>"))
        let runtime = Runtime(invocation: invocation)
        let bundleID = application.bundleIdentifier ?? "pid.\(application.processIdentifier)"
        guard let knowledge = try await runtime.store.load(bundleID: bundleID) else {
            print("nothing remembered about \(bundleID) under \(await runtime.store.directory.path)")
            return
        }
        let brain = knowledge.brain
        print("\(bundleID): \(brain.objects.count) anchors, \(brain.groups.count) groups, "
            + "\(brain.transitions.count) transitions, \(knowledge.windows.count) window states "
            + "(\(knowledge.objectCount) objects), \(knowledge.menuCommands.count) menu commands, "
            + "\(knowledge.routes.count) routes; observed \(brain.ingestEpoch) times")
        let established = brain.objects.sorted { $0.seenCount > $1.seenCount }.prefix(15)
        if !established.isEmpty { print("anchors, most seen first:") }
        for anchor in established {
            let name = anchor.label.isEmpty ? "(unnamed)" : anchor.label
            let source = anchor.labelSource.map { " [\($0.rawValue)]" } ?? ""
            let does = brain.does(anchorKey: anchor.anchorKey).map { ", \($0)" } ?? ""
            let states = anchor.statesSeen.isEmpty
                ? ""
                : ", states " + anchor.statesSeen.keys.sorted().joined(separator: "/")
            let at = String(format: "%.2f,%.2f", anchor.boundsTypical.x, anchor.boundsTypical.y)
            print("  \(name)\(source) ×\(anchor.seenCount) at \(at)\(does)\(states)")
        }
        for group in brain.groups {
            let members = "\(group.memberAnchors.count) \(group.sharedKind.rawValue)s"
            print("group \(group.name ?? group.axis.rawValue): \(members), seen \(group.seenCount)×")
        }
        for route in knowledge.routes {
            let standing = route.isActionable
                ? "actionable"
                : (route.demotedAt == nil ? "unearned" : "demoted: \(route.demotionCause ?? "")")
            print("route \"\(route.name)\" ✓×\(route.evidence) \(standing)")
            for step in route.steps { print("    \(step.summary)") }
        }
        let opportunities = brain.namingOpportunities(limit: 5)
        if !opportunities.isEmpty { print("worth naming:") }
        for opportunity in opportunities {
            print("  \(opportunity.anchor.anchorKey.prefix(8)) score \(opportunity.score): \(opportunity.context)")
        }
    }
}
