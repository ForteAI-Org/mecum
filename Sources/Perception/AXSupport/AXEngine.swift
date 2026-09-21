import Foundation
import CoreGraphics
import ApplicationServices
import LocatorCore

/// The `@MainActor` public surface for Accessibility: hit-test, read/walk the tree, capture & replay
/// a path, perform actions.
///
/// AX is kept **synchronous and main-actor-isolated** (rather than wrapped in an actor) so the tight
/// per-element walk doesn't pay an `await` per attribute read. `AXUIElement` is non-`Sendable`; because
/// every value produced/consumed here stays on the main actor, that is safe and needs no `@unchecked`.
@MainActor
public struct AXEngine {
    public let reader: LiveAXReader
    /// Per-AX-IPC timeout applied at the app level (Pro Tools trees can hang otherwise).
    public var messagingTimeout: Float

    public init(messagingTimeout: Float = 2.0) {
        self.reader = LiveAXReader()
        self.messagingTimeout = messagingTimeout
    }

    // MARK: Accessibility trust (TCC)

    /// Whether this process is trusted for Accessibility. Pass `promptIfNeeded: true` to surface the
    /// system prompt. NB: for a CLI the grant attaches to the *launching* terminal/binary.
    public static func isAccessibilityTrusted(promptIfNeeded: Bool = false) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": promptIfNeeded] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Hit-test & reads

    public func hitTest(globalPoint p: CGPoint) -> AXUIElement? {
        guard let e = reader.hitTest(globalPoint: p) else { return nil }
        applyTimeout(to: e)   // cap ALL subsequent reads on this app (reads/walk happen before capture)
        return e
    }

    /// Find the AX text field whose description/title/value matches `label` (the AXSceneAugmentor
    /// handle) in the app's focused window. By NAME, never by point hit-test — overlapping
    /// labels/cells make points ambiguous in dense dialogs.
    public func findField(pid: pid_t, matching label: String) -> AXUIElement? {
        let appEl = reader.applicationElement(pid: pid)
        applyTimeout(to: appEl)
        guard let win = reader.attributeElement(appEl, kAXFocusedWindowAttribute as String)
            ?? reader.children(appEl).first(where: { reader.role($0) == "AXWindow" }) else { return nil }
        // The scene disambiguates duplicate handles ordinally ("Track Name #2" = the second field
        // named Track Name, in walk order) — parse that back so both forms resolve.
        var want = label.lowercased()
        var ordinal = 1
        if let r = want.range(of: #" #\d+$"#, options: .regularExpression),
           let n = Int(want[r].dropFirst(2)) { ordinal = n; want = String(want[..<r.lowerBound]) }
        var matches = 0
        var found: AXUIElement?
        func walk(_ e: AXUIElement, _ d: Int) {
            guard found == nil, d < 10 else { return }
            let role = reader.role(e) ?? ""
            if role == "AXTextField" || role == "AXComboBox" || role == "AXTextArea" {
                let names = [reader.descriptionText(e), reader.title(e), reader.value(e)]
                    .compactMap { $0?.lowercased() }
                if names.contains(want) {
                    matches += 1
                    if matches == ordinal { found = e; return }
                }
            }
            for c in reader.children(e) { walk(c, d + 1) }
        }
        walk(win, 0)
        return found
    }

    /// The INVISIBLE field write: set kAXValue and read it back. True only when the read-back matches —
    /// standard AppKit fields accept this (no clicks, no keystrokes, no focus theft); custom fields
    /// (Pro Tools dialogs) refuse and the caller falls back to click + keyboard. NEVER sets kAXFocused:
    /// focus-stealing from a background window made the whole machine feel broken (measured).
    public func setFieldValue(pid: pid_t, matching label: String, to text: String) -> Bool {
        guard let field = findField(pid: pid, matching: label) else { return false }
        guard reader.setStringAttr(field, kAXValueAttribute as String, text) else { return false }
        return reader.value(field) == text
    }

    public func role(_ e: AXUIElement) -> String? { reader.role(e) }
    public func title(_ e: AXUIElement) -> String? { reader.title(e) }
    /// On/off state of a stateful control via `kAXValueAttribute` (0 = off, 1 = on); nil if unreadable
    /// (no AX value — e.g. a CV-only toggle) and `.unknown`-mapped for a mixed/tri-state value (2).
    public func toggleState(_ e: AXUIElement) -> ToggleState? {
        guard let n = reader.numericValue(e) else { return nil }
        return n == 0 ? .off : (n == 1 ? .on : nil)
    }
    public func descriptionText(_ e: AXUIElement) -> String? { reader.descriptionText(e) }
    public func value(_ e: AXUIElement) -> String? { reader.value(e) }
    public func identifier(_ e: AXUIElement) -> String? { reader.identifier(e) }

    // MARK: Menu bar (P3 auto-explorer)
    /// The app's menu-bar element (`kAXMenuBar`) for READ-ONLY enumeration of AXMenuBarItem → AXMenu →
    /// AXMenuItem. Reading the tree never shows or fires a menu.
    public func menuBar(of app: AXUIElement) -> AXUIElement? { reader.attributeElement(app, kAXMenuBarAttribute as String) }
    public func menuItemMarkChar(_ e: AXUIElement) -> String? { reader.menuItemMarkChar(e) }
    public func menuItemCmdChar(_ e: AXUIElement) -> String? { reader.menuItemCmdChar(e) }
    /// Recovery only: dismiss a shown menu without selecting anything.
    public func performCancel(_ e: AXUIElement) -> Bool { reader.performCancel(e) }
    /// Recovery only: post an Escape keystroke (closes an open menu the AX cancel didn't).
    public func dismissViaEscape() {
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
    }
    public func enabled(_ e: AXUIElement) -> Bool? { reader.enabled(e) }
    public func actions(_ e: AXUIElement) -> [String] { reader.actions(e) }
    public func frameGlobalPt(_ e: AXUIElement) -> CGRect? { reader.frame(e) }
    public func pid(of e: AXUIElement) -> pid_t? { reader.pid(of: e) }

    public func leafAttrs(of e: AXUIElement) -> AXLeafAttrs { AXPathOps.leafAttrs(of: e, reader: reader) }
    public func sameRoleSiblingIndex(of e: AXUIElement) -> Int? { AXPathOps.sameRoleSiblingIndex(of: e, reader: reader) }

    /// Ancestor chain `[e, …, window]` via `kAXParentAttribute`, stopping at the window or `maxDepth`.
    public func walkAncestors(_ e: AXUIElement, maxDepth: Int = 64) -> [AXUIElement] {
        var chain: [AXUIElement] = [e]
        var current = e
        var depth = 0
        while depth < maxDepth, let parent = reader.parent(current) {
            chain.append(parent)
            if reader.role(parent) == AXPathOps.windowRole { break }
            current = parent
            depth += 1
        }
        return chain
    }

    public func isOpaqueGroup(_ e: AXUIElement, windowFrame: CGRect) -> Bool {
        AXPathOps.isOpaqueGroup(e, windowFrame: windowFrame, reader: reader)
    }

    /// The element's containing window via `kAXWindowAttribute` (robust against deep/floating trees).
    public func window(of e: AXUIElement) -> AXUIElement? { reader.window(of: e) }

    // MARK: Capture & replay

    public func capturePath(from leaf: AXUIElement) -> [AXPathStep] {
        applyTimeout(to: leaf)
        return AXPathOps.capturePath(from: leaf, reader: reader)
    }

    /// Replay a path inside the app with the given pid, returning the live element (or `nil`).
    public func replayPath(_ path: [AXPathStep], inApp pid: pid_t, leafAttrs: AXLeafAttrs? = nil) -> AXUIElement? {
        replayOutcome(path, inApp: pid, leafAttrs: leafAttrs).element
    }

    /// Replay, reporting which step failed. The app → window hop uses `kAXWindowsAttribute` (the app
    /// element doesn't reliably list windows under `kAXChildrenAttribute`); the rest descends via children.
    public func replayOutcome(_ path: [AXPathStep], inApp pid: pid_t, leafAttrs: AXLeafAttrs? = nil) -> AXReplayOutcome<AXUIElement> {
        guard let first = path.first else { return .emptyPath }
        let app = reader.applicationElement(pid: pid)
        reader.setMessagingTimeout(app, seconds: messagingTimeout)

        guard first.role == AXPathOps.windowRole else {
            return AXPathOps.replayPathDiagnostic(path, root: app, leafAttrs: leafAttrs, reader: reader)
        }
        let windows = reader.windows(of: app).filter { reader.role($0) == AXPathOps.windowRole }
        guard let window = AXPathOps.selectCandidate(windows, step: first, reader: reader) else {
            return .noCandidates(depth: 0, role: AXPathOps.windowRole)
        }
        // Descend the remaining steps from the window; shift depths back so they match the full path.
        return AXPathOps.replayPathDiagnostic(Array(path.dropFirst()), root: window, leafAttrs: leafAttrs, reader: reader)
            .offsettingDepth(by: 1)
    }

    @discardableResult
    public func performPress(_ e: AXUIElement) -> Bool { reader.performPress(e) }

    // MARK: Scroll (Phase 1 — native AX scroll areas)

    /// Scrollable ancestors of `e`, innermost first (each is an `AXScrollArea`).
    public func scrollableAncestors(of e: AXUIElement) -> [AXUIElement] {
        walkAncestors(e).filter { reader.role($0) == (kAXScrollAreaRole as String) }
    }

    private func scrollBarAttr(_ axis: ScrollAxis) -> String {
        (axis == .vertical ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute) as String
    }

    /// Current scroll position (0…1) of a scroll area's bar on the given axis; nil if it has no such bar.
    public func scrollFraction(of scrollArea: AXUIElement, axis: ScrollAxis) -> Double? {
        guard let bar = reader.attributeElement(scrollArea, scrollBarAttr(axis)) else { return nil }
        return reader.doubleAttr(bar, kAXValueAttribute as String)
    }

    /// Drive a scroll area's bar to an absolute fraction (0…1). Returns whether the app accepted it.
    @discardableResult
    public func setScrollFraction(of scrollArea: AXUIElement, axis: ScrollAxis, _ value: Double) -> Bool {
        guard let bar = reader.attributeElement(scrollArea, scrollBarAttr(axis)) else { return false }
        return reader.setDoubleAttr(bar, kAXValueAttribute as String, min(1, max(0, value)))
    }

    /// The viewport rect of a scroll area (its own frame) — a target outside this ⇒ off-screen.
    public func visibleContentRect(of scrollArea: AXUIElement) -> CGRect? { reader.frame(scrollArea) }

    // MARK: Internals

    private func applyTimeout(to e: AXUIElement) {
        guard let pid = reader.pid(of: e) else { return }
        reader.setMessagingTimeout(reader.applicationElement(pid: pid), seconds: messagingTimeout)
    }
}
