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
                : (section.name == Self.openMenu ? min(60, showable.count) : notable)
            let shown = showable.prefix(budget)
            for element in shown {
                let state = element.state.map { " [\($0.rawValue)]" } ?? ""
                let details = Self.liveDetails(element)
                let does  = element.does.map { ": \($0)" } ?? ""
                let label = element.isUnlabeled ? "(unlabeled icon: target id '\(element.id)')" : element.label
                let field = AccessibilityAugmentation.textEntryRoles.contains(element.role ?? "")
                let reference = field ? "[field] \(label) id:'\(element.id)'" : label
                out += "    \(reference)\(state)\(details)\(does)\n"
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

    /// Renders the full scene in the compact form the model reads: one header line, then one line
    /// per element under its `## section` line, with unlabeled plain icons gathered on one `icons:` line.
    ///
    /// Panels, and the elements inside each, come in reading order rather than in the order
    /// composition gathered them, so one screen renders one text. An open menu keeps its own order.
    /// The format is lossless for target resolution: every label, id, section and state it resolved
    /// by is still printed, and a `{container}` is printed where it changes within a section.
    public func text() -> String {
        var out = compactHeader(counting: true)
        let shared = labelsSharedAcrossOwners
        if sections.isEmpty {
            out += compactLines(of: elements, sharedLabels: shared)
        } else {
            for section in sectionsInReadingOrder {
                out += compactSectionLine(section)
                out += compactLines(
                    of          : elements.filter { $0.section == section.name },
                    sharedLabels: shared,
                    keepingOrder: section.name == Self.openMenu
                )
            }
            let loose = elements.filter { $0.section == nil }
            if !loose.isEmpty {
                out += "## \(Self.unsectioned)\n"
                out += compactLines(of: loose, sharedLabels: shared)
            }
        }
        if !commands.isEmpty { out += commandsLine() }
        return out
    }

    /// The heading of the elements that belong to no section.
    static let unsectioned = "unsectioned"

    /// The section name of an open pop-up menu: its rows are its surface, kept in the menu's order.
    static let openMenu = "open menu"

    /// How far apart two vertical centers may be and still share a row: eight captured pixels, meant
    /// to keep a label on the row of the icon beside it and two lines of UI text on rows of their own.
    var rowTolerance: Double { 8 / Double(max(viewportPixelSize.height, 1)) }

    /// The sections in reading order, the same rule as elements.
    var sectionsInReadingOrder: [SceneSection] {
        Self.readingOrder(sections, rowTolerance: rowTolerance, bounds: \.bounds, tieBreak: \.name)
    }

    /// The labels, lowercased, that more than one container owns: a line copied alone must still name
    /// its container for `resolve` to tell them apart, so those lines print it even when it holds.
    var labelsSharedAcrossOwners: Set<String> {
        var owners: [String: Set<String?>] = [:]
        for element in elements { owners[element.label.lowercased(), default: []].insert(element.container) }
        return Set(owners.filter { $0.value.count > 1 }.keys)
    }

    /// The lines of `members` in the compact form: reading order unless `keepingOrder`, a container
    /// printed where it differs from the line before or where `sharedLabels` names the label, and the
    /// plain unlabeled icons on one last line.
    func compactLines(
        of members  : [SceneElement],
        sharedLabels: Set<String>,
        keepingOrder: Bool = false
    ) -> String {
        let ordered = keepingOrder ? members : Self.readingOrder(
            members.map { ($0, Self.elementLine($0)) },
            rowTolerance: rowTolerance,
            bounds      : \.0.bounds,
            tieBreak    : \.1
        ).map(\.0)
        var out = ""
        var icons: [SceneElement] = []
        var owner: String?
        for element in ordered {
            if Self.isPlainIcon(element) {
                icons.append(element)
                continue
            }
            // The owner holds until another one is printed; `{}` says the line has none.
            let repeated = element.container == owner
                && !(element.container != nil && sharedLabels.contains(element.label.lowercased()))
            let note = repeated ? "" : element.container.map { " {\($0)}" } ?? " {}"
            owner = element.container
            out += Self.elementLine(element, ownerNote: note)
        }
        if !icons.isEmpty { out += Self.iconsLine(icons) }
        return out
    }

    /// `items` in reading order: rows top to bottom, then left to right within a row. A row holds
    /// every item whose vertical center lies within `rowTolerance` of its first item's. `tieBreak`
    /// orders items at one place, so equal sets of items come out equal whatever order they came in.
    static func readingOrder<Item>(
        _ items     : [Item],
        rowTolerance: Double,
        bounds      : (Item) -> NormalizedRect,
        tieBreak    : (Item) -> String
    ) -> [Item] {
        let byCenter = items.sorted {
            (bounds($0).midY, bounds($0).x, tieBreak($0)) < (bounds($1).midY, bounds($1).x, tieBreak($1))
        }
        var rows: [[Item]] = []
        var rowCenter = -Double.infinity
        for item in byCenter {
            if bounds(item).midY - rowCenter > rowTolerance {
                rows.append([item])
                rowCenter = bounds(item).midY
            } else {
                rows[rows.count - 1].append(item)
            }
        }
        return rows.flatMap { row in
            row.sorted {
                (bounds($0).x, bounds($0).midY, tieBreak($0)) < (bounds($1).x, bounds($1).midY, tieBreak($1))
            }
        }
    }

    func header() -> String {
        "app: \(appName) (\(bundleID))\(windowTitle.isEmpty ? "" : ": \"\(windowTitle)\"")\n"
    }

    /// `App (bundle) "title"`, then the viewport and the element count when `counting`.
    func compactHeader(counting: Bool) -> String {
        let title = windowTitle.isEmpty ? "" : " \"\(windowTitle)\""
        guard counting else { return "\(appName) (\(bundleID))\(title)\n" }
        return "\(appName) (\(bundleID))\(title) \(viewportPixelSize.width)x\(viewportPixelSize.height), "
            + "\(elements.count) elements\n"
    }

    func commandsLine() -> String {
        "commands (\(commands.count)): " + commands.prefix(40).joined(separator: " · ") + "\n"
    }

    func sectionLine(_ section: SceneSection, count: Int) -> String {
        let b = section.bounds
        let position = String(format: "%.2f,%.2f %.2f×%.2f", b.x, b.y, b.width, b.height)
        let vertical   = section.verticalScrollNote.map { " · \($0)" } ?? ""
        let horizontal = section.horizontalScrollNote.map { " · \($0)" } ?? ""
        return "Section: \(section.name), position: \(position), \(count) elements\(vertical)\(horizontal)\n"
    }

    /// `## name @x,y wxh`, with the position and size in whole percent of the window.
    func compactSectionLine(_ section: SceneSection) -> String {
        let b = section.bounds
        let vertical   = section.verticalScrollNote.map { " · \($0)" } ?? ""
        let horizontal = section.horizontalScrollNote.map { " · \($0)" } ?? ""
        return "## \(section.name) @\(Self.percent(b.x)),\(Self.percent(b.y)) "
            + "\(Self.percent(b.width))x\(Self.percent(b.height))\(vertical)\(horizontal)\n"
    }

    /// A value in 0...1 as the whole percent its two-decimal print used to show, so nothing rounds
    /// differently than before.
    static func percent(_ value: Double) -> Int {
        guard value.isFinite, let hundredths = Double(String(format: "%.2f", value)) else { return 0 }
        return Int((hundredths * 100).rounded())
    }

    /// `@x,y`: where an element is, in whole percent of the window.
    static func place(_ bounds: NormalizedRect) -> String {
        "@\(percent(bounds.x)),\(percent(bounds.y))"
    }

    /// The one line of an element: its tag unless it is plain text, label, the id when a target needs
    /// it, state, live details, learned effect and place. `ownerNote` is the `{container}` text to
    /// print, or nil to print the element's own, which is what a line read on its own needs.
    static func elementLine(_ element: SceneElement, ownerNote: String? = nil) -> String {
        let field = AccessibilityAugmentation.textEntryRoles.contains(element.role ?? "")
        // A text line that could read as a tag or as another line keeps its tag.
        let plainText = element.kind == .text && !element.isUnlabeled && !field && !element.label.isEmpty
            && !["[", "#", "icons:", "commands"].contains { element.label.hasPrefix($0) }
        let tag = plainText ? "" : field ? "[field]"
            : element.isUnlabeled ? "[\(element.kind.rawValue)?]" : "[\(element.kind.rawValue)]"
        let label = element.isUnlabeled && element.label == unlabeledLabel ? "" : element.label
        let head = [tag, label].filter { !$0.isEmpty }.joined(separator: " ")
        let identity = element.isUnlabeled || field ? " id:'\(element.id)'" : ""
        let state    = element.state.map { " [\($0.rawValue)]" } ?? ""
        let owner    = ownerNote ?? element.container.map { " {\($0)}" } ?? ""
        let recalled = element.isRecalled ? " ~recalled" : ""
        let does     = element.does.map { ": \($0)" } ?? ""
        return "\(head)\(identity)\(state)\(compactDetails(element))\(owner)\(recalled)\(does) \(place(element.bounds))\n"
    }

    /// The label an element without a name carries; the line leaves it out, the `[icon?]` tag says it.
    static let unlabeledLabel = "(unlabeled)"

    /// True for an unlabeled icon that has nothing to print but its id and place, so it can share
    /// the `icons:` line. An id with a space could not be told apart there.
    private static func isPlainIcon(_ element: SceneElement) -> Bool {
        element.kind == .icon && element.isUnlabeled && element.label == unlabeledLabel
            && element.state == nil && element.value == nil && element.does == nil
            && element.isEnabled != false && element.container == nil && !element.isRecalled
            && !AccessibilityAugmentation.textEntryRoles.contains(element.role ?? "")
            && !element.id.isEmpty && !element.id.contains { $0.isWhitespace }
    }

    /// `icons: id@x,y id×n`: an icon whose id is its own keeps the id and the place, icons that
    /// share an id collapse to the id and how many, since the id alone cannot target any of them.
    private static func iconsLine(_ icons: [SceneElement]) -> String {
        let counts = Dictionary(icons.map { ($0.id, 1) }, uniquingKeysWith: +)
        var seen = Set<String>()
        var items: [String] = []
        for icon in icons where seen.insert(icon.id).inserted {
            items.append(counts[icon.id] == 1 ? icon.id + place(icon.bounds) : "\(icon.id)×\(counts[icon.id] ?? 0)")
        }
        return "icons: " + items.joined(separator: " ") + "\n"
    }

    /// Value, selection and availability of an element, the compact way: `[sel a..b/n]`.
    private static func compactDetails(_ element: SceneElement) -> String {
        let value = element.value.flatMap { $0 == element.label ? nil : " = \(visibleValue($0))" } ?? ""
        let selection: String
        if let text = element.value, let range = SceneElement.validRange(element.selectedRange, value: text) {
            selection = " [sel \(range.location)..\(range.location + range.length)/\(text.utf16.count)]"
        } else {
            selection = ""
        }
        return value + selection + (element.isEnabled == false ? " [disabled]" : "")
    }

    private static func liveDetails(_ element: SceneElement) -> String {
        let value = element.value.flatMap { $0 == element.label ? nil : " = \(visibleValue($0))" } ?? ""
        let selection: String
        if let text = element.value, let range = SceneElement.validRange(element.selectedRange, value: text) {
            selection = " [selection UTF-16: \(range.location)..\(range.location + range.length) of \(text.utf16.count)]"
        } else {
            selection = ""
        }
        let availability = element.isEnabled == false ? " [disabled]" : ""
        let owner = element.container.map { " {\($0)}" } ?? ""
        return value + selection + availability + owner
    }

    /// Escapes whitespace without turning one native value into additional scene rows.
    private static func visibleValue(_ value: String) -> String {
        if value.isEmpty || value != value.trimmingCharacters(in: .whitespacesAndNewlines)
            || value.contains("\n") || value.contains("\r") || value.contains("\t") {
            return String(reflecting: value)
        }
        return value
    }

    /// Map order: stateful first, learned affordance second, any labeled control or icon third.
    private static func mapRank(_ element: SceneElement) -> Int {
        if element.state != nil { return 0 }
        if element.does != nil { return 1 }
        if (element.kind == .control || element.kind == .icon), !element.isUnlabeled { return 2 }
        return 3
    }
}
