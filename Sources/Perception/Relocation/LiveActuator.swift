import Foundation
import CoreGraphics
import AppKit
import AXSupport
import LocatorCore

/// Live relocation for flow playback — runs the recall cascade.
public struct LiveStepRelocator: StepRelocating {
    let crops: CropStore
    let ax: AXEngine
    let debug: RelocationDebugDumper?

    public init(crops: CropStore, ax: AXEngine, debug: RelocationDebugDumper? = nil) {
        self.crops = crops
        self.ax = ax
        self.debug = debug
    }

    public func relocate(_ descriptor: Descriptor) async -> RelocationResult {
        await Relocator(probes: LiveRelocationProbes(crops: crops, ax: ax, debugDump: debug)).relocate(descriptor)
    }
}

/// Live actuation — focus the app, then press the element (AX) or synthetic-click its resolved point.
public struct LiveActuator: StepActuating {
    let ax: AXEngine

    public init(ax: AXEngine) { self.ax = ax }

    public func focus(bundleID: String) async {
        await MainActor.run { () -> Void in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate()
        }
    }

    public func actuate(descriptor: Descriptor, result: RelocationResult) async -> Bool {
        // STATE-AWARE idempotent actuation for a stateful control (toggle/checkbox/radio): read the LIVE
        // state and act only to REACH the recorded desired end-state — click on mismatch, no-op if already
        // there, SKIP if the state can't be read (never blindly re-click a stateful control; a wrong flip
        // is undoable). control == nil → the plain path below (every legacy / button flow unchanged).
        if let control = descriptor.control, control.isStateful {
            let current = await liveToggleState(descriptor: descriptor, result: result)
            switch control.action(givenCurrent: current) {
            case .noop:
                return true                                  // already in the desired state — idempotent success
            case .skip:
                return false                                 // unreadable → don't guess-click (honest skip → stopOnMiss halts)
            case .click:
                guard await plainActuate(descriptor: descriptor, result: result) else { return false }
                try? await Task.sleep(for: .milliseconds(250))   // settle, then verify it actually flipped
                let after = await liveToggleState(descriptor: descriptor, result: result)
                return after.map { $0 == .unknown || $0 == control.desiredState } ?? true
            }
        }
        return await plainActuate(descriptor: descriptor, result: result)
    }

    /// Plain actuation: AXPress when the AX path resolved, else synthetic-click the resolved screen point.
    private func plainActuate(descriptor: Descriptor, result: RelocationResult) async -> Bool {
        if result.method == .axPath {
            let pressed = await MainActor.run { () -> Bool in
                guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: descriptor.app.bundleID).first?.processIdentifier,
                      let element = ax.replayPath(descriptor.ax.path, inApp: pid, leafAttrs: descriptor.ax.leafAttrs) else { return false }
                return ax.performPress(element)
            }
            if pressed { return true }
        }
        // Otherwise synthetic-click the resolved screen point (top-left global coords == CGEvent coords).
        guard let rect = result.elementRectScreenPt else { return false }
        Self.click(at: CGPoint(x: rect.midX, y: rect.midY))
        return true
    }

    /// Read a stateful control's LIVE on/off state for the idempotent decision: via the resolved AX element
    /// (axPath replay, else an AX hit-test at the located point). nil when no AX value is readable — e.g. a
    /// CV-only toggle in an AX-less app (the CV-state phase reads those).
    private func liveToggleState(descriptor: Descriptor, result: RelocationResult) async -> ToggleState? {
        await MainActor.run { () -> ToggleState? in
            guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: descriptor.app.bundleID).first?.processIdentifier else { return nil }
            if result.method == .axPath, let el = ax.replayPath(descriptor.ax.path, inApp: pid, leafAttrs: descriptor.ax.leafAttrs),
               let s = ax.toggleState(el) { return s }
            if let rect = result.elementRectScreenPt, let el = ax.hitTest(globalPoint: CGPoint(x: rect.midX, y: rect.midY)) {
                return ax.toggleState(el)
            }
            return nil
        }
    }

    /// Synthetic left click at a global (top-left) screen point.
    public static func click(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// Double click — the RENAME/open gesture (Pro Tools track names, Finder items). A real double
    /// click is click-count semantics, not two clicks: the second down/up pair must carry
    /// clickState 2 or apps treat it as two selects.
    public static func doubleClick(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        for clickState in [1, 2] {
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
                e?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
                e?.post(tap: .cghidEventTap)
            }
        }
    }

    /// A real DRAG: down, interpolated dragged events, up — scrollbar thumbs, sliders, timeline
    /// items. Steps matter: apps ignore a teleporting drag (measured: Resolve's preset-strip thumb
    /// follows a 20-step drag and ignores a 2-point jump).
    public static func drag(from: CGPoint, to: CGPoint, steps: Int = 20) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: from, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(120_000)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(120_000)
        for i in 1...max(1, steps) {
            let t = CGFloat(i) / CGFloat(max(1, steps))
            let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(18_000)
        }
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(80_000)
    }

    /// Right click — opens context menus. The caller reads the resulting POPUP-layer window like any
    /// menu (same window model as dropdowns); with the popup gate its items are trusted knowledge.
    public static func rightClick(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
    }

    /// Type text into the FOCUSED field via synthetic key events carrying a unicode payload — no
    /// keycode mapping, so any character (accents, emoji) types correctly regardless of keyboard
    /// layout. One character per down/up pair with a small gap: many apps (Electron included) drop
    /// batched multi-char events. The caller owns focus + safety (secure-field refusal at the MCP gate).
    public static func typeText(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        for ch in text {
            let units = Array(String(ch).utf16)
            for keyDown in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
                // FORCE plain text: a CGEvent inherits the SYSTEM's current modifier state, so typing
                // right after a synthetic ⌘-chord turned "routing" into ⌘R… shortcuts and nothing was
                // typed (measured: the ⌘A selection stayed on screen, untouched). Empty flags always.
                e.flags = []
                units.withUnsafeBufferPointer { buf in
                    e.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                }
                e.post(tap: .cghidEventTap)
            }
            usleep(9000)
        }
    }

    /// Press a single key by VIRTUAL KEYCODE (Return = 36, Tab = 48, Escape = 53) — real key events,
    /// which apps treat as submission/navigation where a unicode payload would just insert a glyph.
    public static func pressKey(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)?.post(tap: .cghidEventTap)
    }

    /// One ⌘-letter chord (⌘A select-all, ⌘C copy) as real modifier key events with guaranteed
    /// release: keycode 55 = ⌘ down, letter down/up, ⌘ up — every event posted even if a step fails,
    /// because a stuck synthetic ⌘ turns every user click into ⌘-click and the whole Mac "feels
    /// broken" (measured — Ron felt it). Small inter-event gaps: chords land more reliably in
    /// custom fields than a zero-delay burst.
    public static func commandChord(letter keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true)
        cmdDown?.flags = .maskCommand
        cmdDown?.post(tap: .cghidEventTap)
        usleep(30_000)
        let kDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        kDown?.flags = .maskCommand
        kDown?.post(tap: .cghidEventTap)
        usleep(30_000)
        let kUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        kUp?.flags = .maskCommand
        kUp?.post(tap: .cghidEventTap)
        usleep(30_000)
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false)
        cmdUp?.post(tap: .cghidEventTap)
        releaseModifiers()
    }

    public static func selectAll() { commandChord(letter: 0) }    // ⌘A
    public static func copySelection() { commandChord(letter: 8) } // ⌘C

    /// General modifier chord (⌘⇧G = Finder/panel "Go to Folder", ⌘W close, …) — same discipline as
    /// commandChord: real modifier down/up events, gaps, and a release-all backstop so nothing sticks.
    public static func chord(_ keyCode: CGKeyCode, command: Bool = false, shift: Bool = false,
                             option: Bool = false, control: Bool = false) {
        let source = CGEventSource(stateID: .hidSystemState)
        var flags: CGEventFlags = []
        var mods: [CGKeyCode] = []
        if command { flags.insert(.maskCommand); mods.append(55) }
        if shift { flags.insert(.maskShift); mods.append(56) }
        if option { flags.insert(.maskAlternate); mods.append(58) }
        if control { flags.insert(.maskControl); mods.append(59) }
        for m in mods { CGEvent(keyboardEventSource: source, virtualKey: m, keyDown: true)?.post(tap: .cghidEventTap); usleep(20_000) }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
            usleep(30_000)
        }
        for m in mods.reversed() { CGEvent(keyboardEventSource: source, virtualKey: m, keyDown: false)?.post(tap: .cghidEventTap); usleep(15_000) }
        releaseModifiers()
    }

    /// Belt-and-braces: post UP events for every modifier so no synthetic chord can leave the system
    /// with a phantom key held (⌘ 55, ⇧ 56, ⌥ 58, ⌃ 59).
    public static func releaseModifiers() {
        let source = CGEventSource(stateID: .hidSystemState)
        for key in [55, 56, 58, 59] as [CGKeyCode] {
            CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)?.post(tap: .cghidEventTap)
        }
    }
}
