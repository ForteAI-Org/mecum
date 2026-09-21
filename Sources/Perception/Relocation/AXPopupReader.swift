import Foundation
import CoreGraphics
import ApplicationServices
import AXSupport
import LocatorCore

/// THE OPEN MENU, READ WHOLE — accessibility's one clean win over pixels on a pop-up.
///
/// A native macOS menu (a dropdown's list, a context menu, a submenu) is a POPUP-LAYER WINDOW whose
/// pixels vision can read (`PopupVision`) but only ONE PAGE deep: a long menu paints its first page
/// and hides the rest behind scroll arrows. AX reports the menu's `AXMenuItem` children ALL AT ONCE,
/// scrolled-out ones included — measured on TextEdit's font popup, where the scene carried 20 visible
/// families and `act(target: "Helvetica")` honestly missed because Helvetica was two pages down.
///
/// This is the AX HALF of popup enumeration (ticket 06); per-item row segmentation of the native-scale
/// capture is the zero-AX half (ticket 07) and this reader returning `[]` is exactly its cue.
///
/// Two rules the rest of the engine leans on:
/// - **Menu items bypass the off-view suppression BY DESIGN.** `AXSceneAugmentor` drops AX elements
///   whose frame falls outside their clipping container, because a Qt carousel reports scrolled-out
///   tiles at virtual coordinates that are phantom click targets. A menu is different in kind: its
///   off-view items are legitimately *in* the menu, and the engine can select them without a
///   coordinate (`press`). So they stay in the scene, marked `offView`, and the act path presses
///   them semantically instead of clicking a lie.
/// - **`AXUIElement` never crosses an actor.** Reads return Sendable value snapshots; `press` re-walks
///   the live tree and matches by (order, title) — the same value-snapshot discipline as the rest of
///   the AX layer.
public enum AXPopupReader {
    /// One item of an open menu, as values (no live AX handle).
    public struct MenuItem: Sendable, Equatable {
        public var title: String
        /// The item's own AX frame (global TOP-LEFT points), or nil when AX reports nothing usable —
        /// scrolled-out items in a long menu report a zero/offscreen frame.
        public var frameGlobalPt: CGRect?
        public var enabled: Bool
        /// Whether the item carries a state glyph (✓ / -) — a checked menu item.
        public var checked: Bool
        /// The item owns an `AXMenu` child: selecting it opens a SUBMENU, it is not a command.
        public var hasSubmenu: Bool
        /// Position in the menu, 0-based — the identity that survives scrolling, and the handle
        /// `press` matches on.
        public var order: Int

        public init(title: String, frameGlobalPt: CGRect?, enabled: Bool, checked: Bool,
                    hasSubmenu: Bool, order: Int) {
            self.title = title; self.frameGlobalPt = frameGlobalPt; self.enabled = enabled
            self.checked = checked; self.hasSubmenu = hasSubmenu; self.order = order
        }
    }

    /// What the frontmost open menu holds, read in one pass.
    public struct Snapshot: Sendable, Equatable {
        /// The menu's own AX frame when it has one (global top-left points).
        public var menuFrameGlobalPt: CGRect?
        public var items: [MenuItem]
        public init(menuFrameGlobalPt: CGRect?, items: [MenuItem]) {
            self.menuFrameGlobalPt = menuFrameGlobalPt; self.items = items
        }
        public var isEmpty: Bool { items.isEmpty }
    }

    // MARK: - Live read

    /// Read the app's FRONTMOST open menu. `popupFrames` comes from
    /// `WindowCaptureService.openPopupFrames(pid:)` (front-to-back) and is how the right AXMenu is
    /// picked when several exist in the tree: a menu bar holds an `AXMenu` per top-level title whether
    /// or not anything is open, so "which AXMenu is the one ON SCREEN" is answered by geometry, not by
    /// hope. Returns an empty snapshot for apps whose menus expose no AX (Premiere, Pro Tools popups).
    ///
    /// `requireFramedMenu` is for a pop-up that AX does not know is a pop-up: a dropdown drawn as an
    /// ORDINARY window by a toolkit that paints its own widgets (ticket 12 — DaVinci Resolve's Qt
    /// lists). There, no `AXMenu` can match the pop-up's frame because there is no AXMenu for it at
    /// all — and the frameless last resort in `bestMenu` would then hand back a DIFFERENT menu's items
    /// (any single populated `AXMenu` still parked on a popup button). Those phantom items are worse
    /// than none twice over: they name rows that are not on screen, and their presence tells
    /// `SceneBuilder` that accessibility answered, so the row cut that CAN read those pixels is skipped.
    @MainActor
    public static func read(pid: pid_t, popupFrames: [CGRect], engine: AXEngine = AXEngine(),
                            budgetSeconds: TimeInterval = 1.5,
                            requireFramedMenu: Bool = false) -> Snapshot {
        guard let front = popupFrames.first else { return Snapshot(menuFrameGlobalPt: nil, items: []) }
        let appEl = engine.reader.applicationElement(pid: pid)
        engine.reader.setMessagingTimeout(appEl, seconds: 2)
        let deadline = Date().addingTimeInterval(budgetSeconds)
        guard let best = bestMenu(appEl: appEl, popup: front, engine: engine, deadline: deadline,
                                  allowFramelessFallback: !requireFramedMenu) else {
            return Snapshot(menuFrameGlobalPt: nil, items: [])
        }
        return Snapshot(menuFrameGlobalPt: engine.reader.frame(best),
                        items: items(of: best, engine: engine, deadline: deadline))
    }

    /// Every `AXMenu` in the app's tree that could be the open popup, ranked by overlap with the popup
    /// window's frame. Menus live in three places depending on how the app opened one: as a child of
    /// the APPLICATION element (context menus, `NSMenu.popUp`), under the MENU BAR (a menu-bar menu
    /// pulled down), and under a window's `AXPopUpButton`/`AXMenuButton` (a dropdown's list). All three
    /// are searched — the winner is the one whose frame actually matches what is on screen.
    @MainActor
    public static func bestMenu(appEl: AXUIElement, popup: CGRect, engine: AXEngine, deadline: Date,
                                allowFramelessFallback: Bool = true) -> AXUIElement? {
        var candidates: [(el: AXUIElement, score: Double)] = []
        var frameless: [AXUIElement] = []
        var settled = false     // an unambiguous match — stop walking
        func consider(_ e: AXUIElement) {
            // FRAME FIRST (two attribute reads), CHILDREN ONLY IF IT MATCHES. Fetching children is the
            // expensive read, and an app's menu bar holds one CLOSED AXMenu per title — measured on
            // TextEdit: 8 of them, all reporting frame (0,982 0x0). While a menu is TRACKING, the app's
            // main thread is busy running the menu and every AX request queues behind it, so a walk that
            // fetched children for all of those could spend the whole budget and return nothing. That is
            // exactly how the scene intermittently came back with ZERO menu items while `debug-popup`
            // read all 88 of them a second later.
            guard let f = engine.reader.frame(e), f.width > 1, f.height > 1 else { frameless.append(e); return }
            let s = overlap(f, popup)
            guard s > 0.3, !engine.reader.children(e).isEmpty else { return }   // an empty menu isn't on screen
            candidates.append((e, s))
            if s > 0.9 { settled = true }   // the menu whose frame IS the popup window — nothing can beat it
        }
        // Bounded walk: menus sit shallow under the app (app > AXMenu), under the menu bar
        // (app > AXMenuBar > AXMenuBarItem > AXMenu) and under a window's popup button
        // (app > AXWindow > … > AXPopUpButton > AXMenu). Depth 8 covers all three; menu ITEMS are read
        // separately, so the walk never descends INTO a menu it already found.
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard depth < 8, !settled, Date() < deadline, candidates.count < 8 else { return }
            for c in engine.reader.children(e) {
                guard !settled, Date() < deadline else { return }
                let role = engine.reader.role(c) ?? ""
                if role == "AXMenu" { consider(c); continue }   // never descend into a menu here
                walk(c, depth + 1)
            }
        }
        // The FOCUSED WINDOW first: a dropdown's list hangs off its popup button, which is the common
        // case and the cheapest place to find it (the app-level walk has the menu bar in it).
        if let win = engine.reader.attributeElement(appEl, kAXFocusedWindowAttribute as String) { walk(win, 1) }
        if !settled { walk(appEl, 0) }
        if let hit = candidates.max(by: { $0.score < $1.score })?.el { return hit }
        // No framed candidate at all (some apps' menus report no position): a single POPULATED menu is
        // unambiguous; several are not, so take none rather than the wrong one.
        guard allowFramelessFallback else { return nil }
        let populated = frameless.filter { !engine.reader.children($0).isEmpty }
        return populated.count == 1 ? populated[0] : nil
    }

    /// Fraction of the SMALLER rect covered by the intersection — a menu's AX frame and its CGWindow
    /// frame differ by the window's shadow/padding, so IoU is needlessly strict here.
    public static func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let smaller = min(a.width * a.height, b.width * b.height)
        return smaller > 0 ? Double((inter.width * inter.height) / smaller) : 0
    }

    /// The menu's items as value snapshots, in menu order. Separators and titleless decoration are
    /// dropped; a submenu parent is KEPT (it is a real thing to act on — it opens the next menu).
    @MainActor
    static func items(of menu: AXUIElement, engine: AXEngine, deadline: Date) -> [MenuItem] {
        var out: [MenuItem] = []
        var order = 0
        for child in engine.reader.children(menu) {
            guard Date() < deadline, out.count < 400 else { break }
            guard engine.reader.role(child) == "AXMenuItem" else { continue }
            let raw = (engine.reader.title(child) ?? engine.reader.descriptionText(child) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            defer { order += 1 }
            guard isSelectable(title: raw) else { continue }
            let f = engine.reader.frame(child)
            let hasSubmenu = engine.reader.children(child).contains { engine.reader.role($0) == "AXMenu" }
            out.append(MenuItem(title: raw,
                                frameGlobalPt: (f?.width ?? 0) > 1 && (f?.height ?? 0) > 1 ? f : nil,
                                enabled: engine.reader.enabled(child) ?? true,
                                checked: (engine.reader.menuItemMarkChar(child)?.isEmpty == false),
                                hasSubmenu: hasSubmenu, order: order))
        }
        return out
    }

    /// PRESS one item of the open menu — how a scrolled-OUT item gets selected without a coordinate
    /// (the whole reason off-view menu items are allowed into the scene). Re-walks live and matches by
    /// (order, title) so nothing stale is ever pressed: if the menu changed under us, the titles no
    /// longer line up and we refuse.
    @MainActor
    public static func press(pid: pid_t, popupFrames: [CGRect], order: Int, title: String,
                            engine: AXEngine = AXEngine(), budgetSeconds: TimeInterval = 1.0) -> Bool {
        guard let front = popupFrames.first else { return false }
        let appEl = engine.reader.applicationElement(pid: pid)
        engine.reader.setMessagingTimeout(appEl, seconds: 2)
        let deadline = Date().addingTimeInterval(budgetSeconds)
        guard let menu = bestMenu(appEl: appEl, popup: front, engine: engine, deadline: deadline) else { return false }
        var idx = 0
        for child in engine.reader.children(menu) {
            guard engine.reader.role(child) == "AXMenuItem" else { continue }
            let raw = (engine.reader.title(child) ?? engine.reader.descriptionText(child) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            defer { idx += 1 }
            guard idx == order, isSelectable(title: raw), matches(raw, title) else { continue }
            guard engine.reader.enabled(child) != false else { return false }
            return engine.reader.performPress(child)
        }
        return false
    }

    // MARK: - Pure rules (unit-tested; no AX, no screen)

    /// A menu row a human could pick. An NSMenu separator has an empty title (and AX gives it no
    /// description either), and apps pad menus with titleless decoration rows.
    public static func isSelectable(title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 1, t.count <= 64 else { return false }
        return t.contains { $0.isLetter || $0.isNumber }
    }

    /// Same title, allowing for the trailing "…"/ordinal noise a scene label picks up. Deliberately
    /// STRICTER than resolve: this guards a PRESS, so "8 kHz" must never satisfy "48 kHz".
    static func matches(_ a: String, _ b: String) -> Bool { norm(a) == norm(b) }

    /// Alphanumerics only, lowercased — the number-preserving comparison key the popup path has always
    /// used. Inlined from the deleted `PopupVision`/`KnowledgeBase` (`VisionText` and `PerceptionCore`
    /// cover what those files were for); T5 picks the Perception layer's normalizer when it ports this.
    static func norm(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// A label's junk-tolerant core: lowercase alphanumeric tokens, leading tokens of ≤2 characters
    /// dropped (avatar-glyph OCR junk), joined. Was `LocatorMemory.core`.
    static func core(_ label: String) -> String {
        var toks = label.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        while let f = toks.first, f.count <= 2, toks.count > 1 { toks.removeFirst() }
        return toks.joined()
    }

    /// Peel the " #2" ordinal `elements` appends to a duplicate row. Was `AXSceneAugmentor.stripOrdinal`.
    static func stripOrdinal(_ s: String) -> String {
        if let r = s.range(of: #" #\d+$"#, options: .regularExpression) { return String(s[..<r.lowerBound]) }
        return s
    }

    /// The scene element's stable identity key. Was `ObservedObject.makeIdentityKey`; a menu row always
    /// has text, so only the text branch is reachable here.
    static func identityKey(role: String, text: String) -> String {
        let t = String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        return t.isEmpty ? "\(role)|@0,0" : "\(role)|\(t)"
    }

    /// Is this item painted on screen right now? An item whose frame AX withheld, or whose frame sits
    /// outside the menu's visible window, is a real item the engine must NOT click at coordinates.
    public static func isOnView(_ item: MenuItem, popup: CGRect) -> Bool {
        guard let f = item.frameGlobalPt, f.width > 1, f.height > 1 else { return false }
        return popup.insetBy(dx: -2, dy: -2).contains(CGPoint(x: f.midX, y: f.midY))
    }

    /// The open menu, split by whether each row is PAINTED — the two halves must be treated
    /// differently downstream, and conflating them cost a measured bug (see `offView`).
    public struct MenuScene: Sendable, Equatable {
        /// Rows painted on screen. Ordinary click targets carrying their own rect, so they dedupe
        /// against CV by position like any other AX element.
        public var painted: [SceneElement]
        /// Rows scrolled OUT of the painted list: real and selectable BY NAME, but carrying the MENU's
        /// rect because they have no honest spot of their own. NEVER position-dedupe these: their rect
        /// covers the whole menu, so a containment match swallows every row inside it — measured live on
        /// TextEdit's font popup, where the off-view "Helvetica" (row 45) ate the painted "Helvetica"
        /// row's label AND its ✓ state, leaving a scene with a "Helvetica #2" and no "Helvetica".
        public var offView: [SceneElement]
        public init(painted: [SceneElement], offView: [SceneElement]) {
            self.painted = painted; self.offView = offView
        }
        public var all: [SceneElement] { painted + offView }
        public var isEmpty: Bool { painted.isEmpty && offView.isEmpty }
    }

    /// The open menu as SCENE ELEMENTS, normalized to the frame the scene was perceived from (the same
    /// frame `act` computes its click points against — see `SceneBuilder.buildSceneResolved`).
    ///
    /// On-view rows carry their real rect and are ordinary click targets. OFF-VIEW rows are the point of
    /// this whole path: they are emitted with the MENU's rect and a `does` note saying so, so the map
    /// never promises a landing spot that isn't painted, while `act` still selects them by name.
    /// Duplicate titles are numbered ONCE across both halves ("Helvetica", "Helvetica #2") so resolve
    /// stays unique-accept.
    public static func elements(from items: [MenuItem], popup: CGRect, windowFrame: CGRect) -> MenuScene {
        guard windowFrame.width > 0, windowFrame.height > 0 else { return MenuScene(painted: [], offView: []) }
        func norm(_ r: CGRect) -> [Double] {
            [Double((r.minX - windowFrame.minX) / windowFrame.width),
             Double((r.minY - windowFrame.minY) / windowFrame.height),
             Double(r.width / windowFrame.width),
             Double(r.height / windowFrame.height)]
        }
        var built: [(el: SceneElement, onView: Bool)] = []
        for item in items {
            let onView = isOnView(item, popup: popup)
            let pos = norm(onView ? (item.frameGlobalPt ?? popup) : popup)
            let id = identityKey(role: "AXMenuItem", text: "\(item.title)#\(item.order)")
            var does = "menu item"
            if item.hasSubmenu { does += " — opens a submenu" }
            if !onView { does += " (off-view: the engine selects it by name, no scrolling needed)" }
            if !item.enabled { does += " — disabled" }
            built.append((SceneElement(id: id, kind: "control", label: item.title, pos: pos,
                                       role: "AXMenuItem", state: item.checked ? "on" : nil,
                                       does: does, section: nil), onView))
        }
        // Ordinal disambiguation, same rule as the AX table augmentor: a menu that lists Helvetica both
        // under "Recently Used" and in the alphabet becomes "Helvetica", "Helvetica #2".
        var seen: [String: Int] = [:]
        for i in built.indices {
            let n = (seen[built[i].el.label] ?? 0) + 1
            seen[built[i].el.label] = n
            if n > 1 { built[i].el.label += " #\(n)" }
        }
        return MenuScene(painted: built.filter(\.onView).map(\.el),
                         offView: built.filter { !$0.onView }.map(\.el))
    }

    /// Drop the CV copies of rows AX already named INSIDE the open menu, and return the CV elements
    /// that survive. Inside a popup AX is COMPLETE BY CONSTRUCTION — it read every row, painted or not —
    /// so a CV element carrying a menu row's name is that row's own OCR wherever the glyphs happen to
    /// sit in the box. Left in the scene it makes the pick ambiguous: measured live on TextEdit's font
    /// menu, `act(target: "Helvetica")` came back "2 elements labeled 'Helvetica'" — the row, and the
    /// row's picture. Everything AX did NOT name stays (a header, a scroll arrow, an unnamed glyph):
    /// this drops duplicates, it does not hand the menu to AX.
    public static func dropCVDuplicates(cv: [SceneElement], menuRows: [SceneElement],
                                        popupNormalized: [Double]) -> [SceneElement] {
        guard popupNormalized.count == 4, !menuRows.isEmpty else { return cv }
        let box = CGRect(x: popupNormalized[0], y: popupNormalized[1],
                         width: popupNormalized[2], height: popupNormalized[3])
        let named = Set(menuRows.map { core(stripOrdinal($0.label)) }
                                .filter { !$0.isEmpty })
        return cv.filter { e in
            guard e.pos.count == 4, e.unlabeled != true else { return true }
            let c = CGPoint(x: e.pos[0] + e.pos[2] / 2, y: e.pos[1] + e.pos[3] / 2)
            guard box.insetBy(dx: -0.01, dy: -0.01).contains(c) else { return true }
            return !named.contains(core(e.label))
        }
    }

    /// Did the screen come back READING what we selected? The verification for a semantic press: after
    /// choosing "Helvetica" from a font popup, something in the window says "Helvetica" (the popup
    /// button's own value). Exact match, or a suffix at a real word boundary ("Font: Helvetica") — never
    /// a bare suffix, or "48 kHz" would read back as a successful "8 kHz".
    public static func readsBack(_ title: String, in labels: [String]) -> Bool {
        let want = norm(title)
        guard !want.isEmpty else { return false }
        let t = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for raw in labels {
            if norm(raw) == want { return true }
            let low = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard low.count > t.count, low.hasSuffix(t) else { continue }
            let boundary = low[low.index(low.endIndex, offsetBy: -t.count - 1)]
            if !boundary.isLetter && !boundary.isNumber { return true }
        }
        return false
    }

    /// Find the item a target names, for the act path. Exact normalized title first, then the same
    /// guarded prefix rules `PopupVision` uses on OCR'd items (number-preserving — "8" must never win
    /// "48"), then the scene's ordinal suffix stripped.
    public static func match(_ target: String, in items: [MenuItem]) -> MenuItem? {
        let want = norm(stripOrdinal(target))
        guard !want.isEmpty else { return nil }
        if let e = items.first(where: { norm($0.title) == want }) { return e }
        if let p = items.first(where: { let n = norm($0.title)
                                        return n.hasPrefix(want) && n.count <= want.count + 12 }) { return p }
        if let p = items.first(where: { let n = norm($0.title)
                                        return !n.isEmpty && want.hasPrefix(n) && n.count >= max(3, want.count - 6) }) { return p }
        return nil
    }
}
