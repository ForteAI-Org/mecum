//
//  SceneRendering.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import Foundation

/// SceneRendering turns a scene into the text a language model reads: a compact map of named
/// panels with their notable elements, or the flat list when no structure was found.
extension SceneSnapshot {

    /// Renders the map tier: every section with its count and up to `notable` elements, stateful
    /// controls first because actionable state must never be hidden by summarization, then learned
    /// affordances, then labeled controls and icons. Roughly two thousand characters where the
    /// full scene is ninety thousand. An open menu shows up to sixty rows: its rows are the surface.
    public func mapText(notable: Int = 8) -> String {
        guard !sections.isEmpty else { return text() }
        var out = header()
        out += "map: \(elements.count) elements in \(sections.count) sections (describe_section(name) drills in)\n"
        for section in sections {
            let members = elements.filter { $0.section == section.name }
            out += sectionLine(section, count: members.count)
            let ranked = members.enumerated().sorted { a, b in
                let ra = Self.mapRank(a.element), rb = Self.mapRank(b.element)
                if ra != rb { return ra < rb }
                let xa = a.element.bounds.x, xb = b.element.bounds.x
                return xa != xb ? xa < xb : a.offset < b.offset
            }.map(\.element)
            // Nameless clutter is filtered before truncating, so the budget is spent on real rows.
            let showable = ranked.filter { !$0.isUnlabeled || $0.state != nil }
            let budget = showable.count <= 10 ? showable.count
                : (section.name == "open menu" ? min(60, showable.count) : notable)
            let shown = showable.prefix(budget)
            for element in shown {
                let state = element.state.map { " [\($0.rawValue)]" } ?? ""
                let does  = element.does.map { " — \($0)" } ?? ""
                let label = element.isUnlabeled ? "(unlabeled icon — target id '\(element.id)')" : element.label
                out += "    \(label)\(state)\(does)\n"
            }
            if showable.count > shown.count {
                out += "    … +\(showable.count - shown.count) more (describe_section)\n"
            }
        }
        let loose = elements.filter { $0.section == nil }.count
        if loose > 0 { out += "(+\(loose) unsectioned elements)\n" }
        if !commands.isEmpty { out += "commands: \(commands.count) menu paths known\n" }
        return out
    }

    /// Renders the full scene: one line per element, nested under its panel when sections exist.
    public func text() -> String {
        var out = header()
        out += "viewport: \(viewportPixelSize.width)x\(viewportPixelSize.height)\n"
        if sections.isEmpty {
            out += "elements (\(elements.count)):\n"
            for element in elements { out += Self.elementLine(element, indent: "  ") }
        } else {
            out += "elements (\(elements.count)) in \(sections.count) sections:\n"
            for section in sections {
                let members = elements.filter { $0.section == section.name }
                out += sectionLine(section, count: members.count)
                for element in members { out += Self.elementLine(element, indent: "    ") }
            }
            let loose = elements.filter { $0.section == nil }
            if !loose.isEmpty {
                out += "▣ (unsectioned) — \(loose.count) elements\n"
                for element in loose { out += Self.elementLine(element, indent: "    ") }
            }
        }
        if !commands.isEmpty {
            out += "commands (\(commands.count)): " + commands.prefix(40).joined(separator: " · ") + "\n"
        }
        return out
    }

    private func header() -> String {
        "app: \(appName) (\(bundleID))\(windowTitle.isEmpty ? "" : " — \"\(windowTitle)\"")\n"
    }

    private func sectionLine(_ section: SceneSection, count: Int) -> String {
        let b = section.bounds
        let position = String(format: "%.2f,%.2f %.2f×%.2f", b.x, b.y, b.width, b.height)
        let vertical   = section.verticalScrollNote.map { " · \($0)" } ?? ""
        let horizontal = section.horizontalScrollNote.map { " · \($0)" } ?? ""
        return "▣ \(section.name)  @ \(position) — \(count) elements\(vertical)\(horizontal)\n"
    }

    private static func elementLine(_ element: SceneElement, indent: String) -> String {
        let position = String(format: "%.2f,%.2f", element.bounds.x, element.bounds.y)
        let state    = element.state.map { " [\($0.rawValue)]" } ?? ""
        let tag      = element.isUnlabeled ? "icon?" : element.kind.rawValue
        let group    = element.group.map { " (\($0))" } ?? ""
        let recalled = element.isRecalled ? " ~recalled" : ""
        let does     = element.does.map { " — \($0)" } ?? ""
        return "\(indent)[\(tag)] \(element.label)\(state)\(group)\(recalled)\(does)  @ \(position)\n"
    }

    /// Map order: stateful first, learned affordance second, any labeled control or icon third.
    private static func mapRank(_ element: SceneElement) -> Int {
        if element.state != nil { return 0 }
        if element.does != nil { return 1 }
        if (element.kind == .control || element.kind == .icon), !element.isUnlabeled { return 2 }
        return 3
    }
}
