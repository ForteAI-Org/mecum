import Foundation
import CoreGraphics
import ApplicationServices
import AXSupport
import LocatorCore

/// CV-FIRST, AX-AUGMENT — the one place accessibility feeds the SCENE. The invariant is unchanged:
/// CV/OCR builds the whole scene and the engine works with zero AX (Premiere). This adds AUTHORITATIVE
/// labels for the structures AX exposes cleanly and OCR mangles — proven live on Pro Tools, where
/// `reach("Audio 13")` scroll-hunted 14.5s and FAILED because OCR rendered the 30-track list as mush
/// ("• * Audio 5", "Q"), while `AXTable "Track List"` held all 30 names exactly.
///
/// It only ever ADDS labeled elements (never deletes CV, never gates perception). A row already
/// carried by a CV element at the same spot with the same core label is skipped, so no duplicate
/// resolve targets. Positions come from AX frames normalized to the SAME window frame the capture
/// used — both top-left global points — so an AX-sourced element is a live click target like any other.
public enum AXSceneAugmentor {
    /// Rows harvested from an app's AX tables/lists, as scene elements normalized to `windowFrame`.
    /// MainActor: AX reads are main-actor isolated. Bounded walk; returns [] for AX-less apps.
    @MainActor
    public static func tableElements(pid: pid_t, windowFrame: CGRect,
                                     engine: AXEngine = AXEngine(),
                                     budgetSeconds: TimeInterval = 1.5) -> [SceneElement] {
        guard windowFrame.width > 0, windowFrame.height > 0 else { return [] }
        let appEl = engine.reader.applicationElement(pid: pid)
        // Cap any single AX message so a hung app can't block for seconds — matches every other AX
        // call site in the engine (scroll, menu, reach all set this).
        engine.reader.setMessagingTimeout(appEl, seconds: 2)
        guard let win = engine.reader.attributeElement(appEl, kAXFocusedWindowAttribute as String)
            ?? engine.reader.children(appEl).first(where: { engine.reader.role($0) == "AXWindow" })
        else { return [] }

        // WALL-CLOCK BUDGET — the generic guard against an AX-pathological tree. Finder's file browser
        // exposes hundreds of AXRows, each needing a deepestNamed sub-walk (value/title/desc/frame per
        // node) — an unbounded walk MEASURED 9s PER WINDOW (18.8s for two), wrecking describe_scene's
        // "vision must be fast" moat. AX augmentation is ADDITIVE, so bailing early with the rows read so
        // far degrades gracefully (CV/OCR still carry the rest) — never wrong, only less AX-enriched. Fast
        // apps (a Premiere dialog reads in 0.04s) never come near the budget.
        let deadline = Date().addingTimeInterval(budgetSeconds)

        var out: [SceneElement] = []
        var tables = 0
        func walk(_ e: AXUIElement, _ depth: Int, _ clip: CGRect) {
            guard depth < 10, tables < 24, out.count < 400, Date() < deadline else { return }
            let role = engine.reader.role(e) ?? ""
            // ANCESTOR CLIP — the phantom-control guard. A scrolling container (Qt especially) reports its
            // scrolled-OUT children at their VIRTUAL coordinates, which can land anywhere in the window:
            // measured on DaVinci's Deliver preset carousel, the off-view "Vimeo 1080p"/"TikTok 1080p"
            // tiles carried frames floating OVER THE VIEWER (x 0.41-0.63) — phantom click targets an agent
            // clicked at nothing (the recorded YouTube mis-render). A control is only real where its
            // clipping container actually shows it, so the walk intersects the clip with each container's
            // frame on the way down and every emitted element must have its midpoint inside. A container
            // with a degenerate frame leaves the clip unchanged (apps with unreliable container frames keep
            // today's behaviour); a container entirely outside the clip prunes its whole subtree (its
            // children are all invisible — also a walk-cost win).
            var childClip = clip
            if ["AXScrollArea", "AXList", "AXOutline", "AXTable", "AXGrid"].contains(role),
               let cf = engine.reader.frame(e), cf.width >= 8, cf.height >= 8 {
                let inter = clip.intersection(cf)
                guard !inter.isNull, inter.width >= 8, inter.height >= 8 else { return }
                childClip = inter
            } else if role == "AXGroup", let cf = engine.reader.frame(e), cf.width >= 8, cf.height >= 8 {
                // Qt exposes scrolling panels as PLAIN AXGroups (measured: DaVinci's preset carousel sits
                // under AXWindow>AXGroup>AXGroup(449×754 = the visible panel) — no AXScrollArea anywhere),
                // so groups must clip too or the virtual-frame phantoms sail through. Groups are less
                // trustworthy than scroll areas, so a group whose sane frame doesn't overlap the clip is
                // IGNORED (descend with the clip unchanged) rather than pruning its whole subtree.
                let inter = clip.intersection(cf)
                if !inter.isNull, inter.width >= 8, inter.height >= 8 { childClip = inter }
            }
            if ["AXTable", "AXOutline", "AXList", "AXGrid"].contains(role) {
                tables += 1
                for row in engine.reader.children(e) where engine.reader.role(row) == "AXRow" {
                    if Date() >= deadline { break }   // stop mid-table on a 500-row list
                    // Cheap pre-check BEFORE the expensive deepestNamed sub-walk: skip rows whose own frame
                    // sits entirely outside the visible clip. Finder scrolls a long list past HUNDREDS of
                    // virtualized off-screen rows — walking each burned the whole budget for rows with no
                    // click target anyway. This can't drop a kept row: the keep below requires the named
                    // midpoint inside the clip, and the row frame contains that midpoint, so any kept
                    // row also intersects. A nil/zero-height frame falls through (apps with unreliable row
                    // frames keep today's behaviour).
                    if let rf = engine.reader.frame(row), rf.height > 0, !childClip.intersects(rf) { continue }
                    guard let named = deepestNamed(row, engine: engine, deadline: deadline) else { continue }
                    let clean = cleanLabel(named.name)
                    guard clean.count >= 2, clean.count <= 48 else { continue }
                    let r = named.frame
                    // Row must sit inside the visible clip (AX sometimes reports off-screen virtualized
                    // rows at 0,0 or negative — those have no live click target).
                    guard r.width > 0, r.height > 0, childClip.contains(CGPoint(x: r.midX, y: r.midY)) else { continue }
                    let pos: [Double] = [Double((r.minX - windowFrame.minX) / windowFrame.width),
                                         Double((r.minY - windowFrame.minY) / windowFrame.height),
                                         Double(r.width / windowFrame.width),
                                         Double(r.height / windowFrame.height)]
                    let id = ObservedObject.makeIdentityKey(role: role, identifier: nil, text: clean, boundsNormalized: pos)
                    out.append(SceneElement(id: id, kind: "control", label: clean, pos: pos,
                                            role: "AXRow"))
                }
                return   // rows read; never recurse into a table's cells (the walk's hot cost)
            }
            // TEXT FIELDS & POPUP BUTTONS: dialog controls OCR mangles or merges into a "Label: value"
            // blob (measured on New Tracks — the count field "1" wasn't in the scene at all, and the
            // name "Audio" fused into "Name: Audio", so neither was a focusable target). AX has each as
            // a precise, focusable element. Label it by description/title when present, else its
            // current value (a field showing "1" IS "1"), so `type target:"Name"` and popup selection
            // get a clean handle.
            if role == "AXTextField" || role == "AXPopUpButton", let f = engine.reader.frame(e),
               f.width > 0, f.height > 0, clip.contains(CGPoint(x: f.midX, y: f.midY)) {
                let description = engine.reader.descriptionText(e)
                let title = engine.reader.title(e)
                let rawValue = engine.reader.value(e)
                let handle = [description, title, rawValue]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty && $0 != "missing value" }
                if let handle, handle.count <= 48 {
                    let pos: [Double] = [Double((f.minX - windowFrame.minX) / windowFrame.width),
                                         Double((f.minY - windowFrame.minY) / windowFrame.height),
                                         Double(f.width / windowFrame.width),
                                         Double(f.height / windowFrame.height)]
                    // A field's value changes because the agent typed. Never
                    // derive its identity from that value: AXIdentifier wins,
                    // otherwise a descriptive label or a fixed role token is
                    // stable across the transition we later verify.
                    let stableText = [description, title]
                        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .first { !$0.isEmpty && $0 != "missing value" } ?? "field"
                    let id = ObservedObject.makeIdentityKey(
                        role: role,
                        identifier: engine.reader.identifier(e),
                        text: stableText,
                        boundsNormalized: pos
                    )
                    // Values are evidence, not presentation. Whitespace and
                    // newlines can be typed content, so preserve them exactly.
                    let value = rawValue == "missing value" ? nil : rawValue
                    out.append(SceneElement(
                        id: id,
                        kind: "control",
                        label: handle,
                        pos: pos,
                        role: role,
                        value: value
                    ))
                }
            }
            // STATEFUL / NAMED CONTROLS the segmenter can't read: an EMPTY checkbox has no filled pixels to
            // segment, a SELECTED radio's dot gets misread (measured on DaVinci — CV called the selected
            // "Square" and "Dual link" radios [off]), a COMBOBOX fragments into value-text + a chevron icon.
            // AX carries each as a named element with an AUTHORITATIVE state (AXValue 0/1/2) or current value.
            // Emit them with the true state — these ARE the controls a settings panel is made of. Merge lets
            // this state correct CV's guess (see merge).
            if ["AXCheckBox", "AXRadioButton", "AXComboBox", "AXButton", "AXMenuButton"].contains(role),
               let f = engine.reader.frame(e), f.width > 0, f.height > 0,
               clip.contains(CGPoint(x: f.midX, y: f.midY)) {
                let title = [engine.reader.title(e), engine.reader.descriptionText(e)]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty && $0 != "missing value" }
                let value = engine.reader.value(e)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanValue = (value?.isEmpty == false && value != "missing value") ? value : nil
                // checkbox/radio carry on/off/mixed in AXValue; a combobox/button has no on-off — its
                // current selection IS its handle (the descriptive title is usually a sibling static text).
                var state: String? = nil
                if role == "AXCheckBox" || role == "AXRadioButton" {
                    switch engine.reader.numericValue(e) { case 1: state = "on"; case 0: state = "off"; case 2: state = "mixed"; default: break }
                }
                if let label = title ?? cleanValue, !label.isEmpty, label.count <= 48 {
                    let pos: [Double] = [Double((f.minX - windowFrame.minX) / windowFrame.width),
                                         Double((f.minY - windowFrame.minY) / windowFrame.height),
                                         Double(f.width / windowFrame.width),
                                         Double(f.height / windowFrame.height)]
                    let id = ObservedObject.makeIdentityKey(role: role, identifier: nil, text: label, boundsNormalized: pos)
                    out.append(SceneElement(id: id, kind: "control", label: label, pos: pos, role: role, state: state))
                }
            }
            for c in engine.reader.children(e) { walk(c, depth + 1, childClip) }
        }
        walk(win, 0, windowFrame)
        // Duplicate handles (a dialog with two rows has two "Track Name" fields) become ordinal —
        // "Track Name", "Track Name #2" — so resolve stays unique-accept instead of ambiguous.
        var seen: [String: Int] = [:]
        for i in out.indices {
            let n = (seen[out[i].label] ?? 0) + 1
            seen[out[i].label] = n
            if n > 1 { out[i].label += " #\(n)" }
        }
        return out
    }

    /// Merge AX-authoritative elements into a CV element list. Additive: an AX row is dropped only when
    /// a CV element ALREADY carries the same core label near the same spot (no duplicate resolve
    /// targets); everything else is added. CV is never removed — if OCR read "Audi 13" mush next to the
    /// clean AX "Audio 13", both remain and the exact one wins the resolve.
    /// Interactive AX roles that are AUTHORITATIVE over CV — right state, right role, a real click target.
    static let axInteractiveRoles: Set<String> =
        ["AXCheckBox", "AXRadioButton", "AXComboBox", "AXButton", "AXMenuButton", "AXTextField", "AXPopUpButton"]
    // NB: an open menu's rows (AXPopupReader) deliberately do NOT come through this merge. Inside a
    // popup AX read every row, so its own geometry is exact and CV's copy of the same text is
    // redundant — `AXPopupReader.dropCVDuplicates` removes the duplicate and the rows are appended.

    /// An element ACCESSIBILITY knows about that is scrolled OUT of its container's visible box — the
    /// same virtual-frame reports the scene suppresses as phantoms, used as a MAP instead: the frame says
    /// where the element virtually sits, the container says which pane to scroll, and their relation says
    /// WHICH WAY. (Measured on DaVinci's Deliver carousel: off-view "YouTube 1080p" at x=481pt, container
    /// 32-481pt → scroll that container RIGHT.)
    public struct OffViewHit: Sendable {
        public let label: String
        public let frame: CGRect       // the element's VIRTUAL frame (global top-left pt) — unclipped
        public let container: CGRect   // the clipping container's VISIBLE box (global top-left pt)
    }

    /// CONTENT roles — the nodes a LIST is made of, as opposed to the chrome every toolkit exposes for
    /// free. The distinction is what makes an AX map's silence usable: measured on the running apps,
    /// DaVinci Resolve exposes 232 content labels out of 278, while Premiere's 144 labels are 91 buttons,
    /// 26 combo boxes and 16 tabs with FIVE static texts between them — a map that knows nothing about
    /// what is in the app's panels, and so can never rule a label out. See `HuntPolicy`.
    ///
    /// AXTextArea is deliberately absent: its value is a document body, not a label, and copying one
    /// across the AX boundary to count it would be the most expensive read in the walk.
    static let axContentRoles: Set<String> =
        ["AXStaticText", "AXRow", "AXCell", "AXMenuItem", "AXCheckBox", "AXLink", "AXImage"]

    /// One AX walk's whole yield: WHERE the target hides (if anywhere) and HOW MUCH THIS MAP KNOWS —
    /// the census that lets `reach` decide whether a 20-second pixel hunt can still teach it anything.
    /// Both answers come from a single walk because they cost the same walk (measured: 0.02–0.04s on
    /// Resolve and Premiere, the two apps that matter here; Finder is the one that hits its budget).
    public struct OffViewProbe: Sendable {
        public let hit: OffViewHit?
        public let labelsRead: Int
        public let contentLabels: Int
        public let knowsLabel: Bool
        public let complete: Bool

        /// No AX window at all — an app whose accessibility is off. `complete: false` on purpose: this
        /// is the "we learned nothing" answer, and `HuntPolicy` must read it as such.
        public static let noWindow = OffViewProbe(hit: nil, labelsRead: 0, contentLabels: 0,
                                                  knowsLabel: false, complete: false)

        /// The census as the policy seam reads it — including the AXIS of a placement, since a target
        /// sideways of its container is one the vertical vision hunt can never reach.
        public var verdict: HuntPolicy.AXVerdict {
            HuntPolicy.AXVerdict(
                labelsRead: labelsRead, contentLabels: contentLabels, complete: complete,
                knowsLabel: knowsLabel,
                placed: hit.map { MissGuide.way(target: $0.frame, container: $0.container).horizontal ? .sideways : .vertical })
        }
    }

    /// Find an off-view interactive control matching `query` — reach's AX guide. Walks with the SAME
    /// ancestor-clip rules as `tableElements` (its twin above: scroll-ish roles tighten+prune, sane
    /// AXGroups tighten), but instead of DROPPING an element whose midpoint falls outside the clip, a
    /// query match there is exactly the answer: target found, container identified, direction implied.
    /// Returns nil when the match is VISIBLE (reach's check-first owns that case) or absent.
    @MainActor
    public static func findOffView(pid: pid_t, windowFrame: CGRect, query: String,
                                   engine: AXEngine = AXEngine(),
                                   budgetSeconds: TimeInterval = 1.5) -> OffViewHit? {
        probe(pid: pid, windowFrame: windowFrame, query: query, engine: engine,
              budgetSeconds: budgetSeconds).hit
    }

    /// `findOffView` plus the CENSUS of the map it walked — see `OffViewProbe`. The hit half is
    /// unchanged, down to stopping at the first off-view match; the census half is what that same walk
    /// saw on the way, so a caller can tell "accessibility says no" apart from "accessibility has no
    /// opinion", which is the difference between a 2-second miss and an 18-second one.
    @MainActor
    public static func probe(pid: pid_t, windowFrame: CGRect, query: String,
                            engine: AXEngine = AXEngine(),
                            budgetSeconds: TimeInterval = 1.5) -> OffViewProbe {
        func empty(_ complete: Bool) -> OffViewProbe {
            OffViewProbe(hit: nil, labelsRead: 0, contentLabels: 0, knowsLabel: false, complete: complete)
        }
        guard windowFrame.width > 0, windowFrame.height > 0 else { return empty(false) }
        let appEl = engine.reader.applicationElement(pid: pid)
        engine.reader.setMessagingTimeout(appEl, seconds: 2)
        guard let win = engine.reader.attributeElement(appEl, kAXFocusedWindowAttribute as String)
            ?? engine.reader.children(appEl).first(where: { engine.reader.role($0) == "AXWindow" })
        // NO AX WINDOW is a real, complete answer — an app with accessibility off (measured: Electron
        // with it disabled, 0 labels) has an empty map, not an unfinished one. The policy seam reads
        // "complete + zero content" as "cannot rule anything out" either way.
        else { return empty(true) }
        let deadline = Date().addingTimeInterval(budgetSeconds)
        var best: OffViewHit?
        // CENSUS state. `truncated` covers both ways the walk can fall short of the tree — the wall
        // budget and the depth cap — because a caller about to end a search on this map's silence needs
        // to know the map was actually finished. (Measured: Finder's file list burns the whole budget;
        // Chrome truncates at depth. Neither one's silence means anything.)
        var labelsRead = 0, contentLabels = 0, knowsLabel = false, truncated = false
        func walk(_ e: AXUIElement, _ depth: Int, _ clip: CGRect) {
            guard best == nil else { return }
            if Date() >= deadline { truncated = true; return }
            guard depth < 12 else { truncated = true; return }
            let role = engine.reader.role(e) ?? ""
            var childClip = clip
            if ["AXScrollArea", "AXList", "AXOutline", "AXTable", "AXGrid"].contains(role),
               let cf = engine.reader.frame(e), cf.width >= 8, cf.height >= 8 {
                let inter = clip.intersection(cf)
                guard !inter.isNull, inter.width >= 8, inter.height >= 8 else { return }
                childClip = inter
            } else if role == "AXGroup", let cf = engine.reader.frame(e), cf.width >= 8, cf.height >= 8 {
                let inter = clip.intersection(cf)
                if !inter.isNull, inter.width >= 8, inter.height >= 8 { childClip = inter }
            }
            let isContent = axContentRoles.contains(role)
            if isContent || axInteractiveRoles.contains(role) {
                // The label is read for EVERY label-bearing node now, not only for the off-view ones the
                // hit needs: "does this map know the label anywhere" is the question that decides whether
                // hunting can still teach us something, and an on-view or static-text match answers it.
                let t1 = engine.reader.title(e)
                let t2 = engine.reader.descriptionText(e)
                let v = engine.reader.value(e)
                let label: String = { if let t1, !t1.isEmpty { return t1 }
                                      if let t2, !t2.isEmpty { return t2 }
                                      if let v, !v.isEmpty { return v }; return "" }()
                if !label.isEmpty {
                    labelsRead += 1
                    if isContent { contentLabels += 1 }
                    if KnowledgeText.matchScore(query: query, against: label) >= 2 {
                        knowsLabel = true
                        // OFF-VIEW is what makes it a HIT: a match whose midpoint sits inside its
                        // clipping container is simply visible, and reach's check-first owns that case.
                        if let f = engine.reader.frame(e), f.width > 0, f.height > 0,
                           axInteractiveRoles.contains(role),
                           !clip.contains(CGPoint(x: f.midX, y: f.midY)) {
                            best = OffViewHit(label: label, frame: f, container: clip)
                            return
                        }
                    }
                }
            }
            for c in engine.reader.children(e) { walk(c, depth + 1, childClip) }
        }
        walk(win, 0, windowFrame)
        // A walk that STOPPED AT A HIT never saw the rest of the tree, so its census is partial by
        // construction. Saying so costs nothing: with a placement in hand the policy decides on that.
        return OffViewProbe(hit: best, labelsRead: labelsRead, contentLabels: contentLabels,
                            knowsLabel: knowsLabel, complete: !truncated && best == nil)
    }

    /// Drop a trailing " #N" disambiguation suffix so a CV label and its AX twin still core-match.
    static func stripOrdinal(_ s: String) -> String {
        if let r = s.range(of: #" #\d+$"#, options: .regularExpression) { return String(s[..<r.lowerBound]) }
        return s
    }

    public static func merge(cv: [SceneElement], ax: [SceneElement]) -> [SceneElement] {
        guard !ax.isEmpty else { return cv }
        var result = cv
        for a in ax {
            let acore = LocatorMemory.core(stripOrdinal(a.label))
            let interactive = axInteractiveRoles.contains(a.role ?? "")
            // AX checkbox/radio frames span the WHOLE ROW, so the CV label sits INSIDE the AX frame (not
            // near its centre). Match on containment (or closeness for compact frames), gated by an exact
            // core match so an adjacent DIFFERENT-labelled control can't be captured.
            let matchIdx = a.pos.count == 4 && !acore.isEmpty ? result.firstIndex { e in
                guard e.pos.count == 4, LocatorMemory.core(stripOrdinal(e.label)) == acore else { return false }
                let ecx = e.pos[0] + e.pos[2] / 2, ecy = e.pos[1] + e.pos[3] / 2
                let inside = ecx >= a.pos[0] - 0.01 && ecx <= a.pos[0] + a.pos[2] + 0.01
                          && ecy >= a.pos[1] - 0.01 && ecy <= a.pos[1] + a.pos[3] + 0.01
                let close = abs(ecx - (a.pos[0] + a.pos[2] / 2)) < 0.08 && abs(ecy - (a.pos[1] + a.pos[3] / 2)) < 0.04
                return inside || close
            } : nil
            if let i = matchIdx {
                if interactive {
                    // UPGRADE the CV element in place: keep its PRECISE position (a full-width AX row frame
                    // would put the click mid-row, missing the dot), but take AX's authoritative role, true
                    // state, and clean name. This turns a checkbox LABEL that CV had as plain text into a
                    // real [control], and corrects a radio CV mis-stated [off].
                    result[i].kind = "control"
                    result[i].role = a.role
                    result[i].state = a.state
                    result[i].label = a.label
                    result[i].unlabeled = nil
                    // The AX note (a menu item's "opens a submenu" / "off-view") survives the upgrade —
                    // it is knowledge CV cannot have. A learned affordance already on the CV element wins.
                    if result[i].does == nil { result[i].does = a.does }
                }
                // non-interactive (AXRow): CV wins on a dup — OCR may read the row name better; drop AX.
            } else {
                result.append(a)
            }
        }
        return result
    }

    /// The most specific human name inside a row subtree (Pro Tools buries the track name in a
    /// grandchild AXButton whose value is "Audio 13 - Audio Track "), plus that element's frame.
    @MainActor
    static func deepestNamed(_ row: AXUIElement, engine: AXEngine,
                             deadline: Date = .distantFuture) -> (name: String, frame: CGRect)? {
        let rowFrame = engine.reader.frame(row)   // hoisted: the fallback frame, read once
        var best: (name: String, frame: CGRect)?
        func rec(_ e: AXUIElement, _ d: Int) {
            if Date() >= deadline { return }   // a single pathological row can't blow the budget
            for a in [engine.reader.value(e), engine.reader.title(e), engine.reader.descriptionText(e)] {
                guard let s = a?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !s.isEmpty, s != "missing value" else { continue }
                let low = s.lowercased()
                guard low != "cell", low != "button", low != "row" else { continue }
                if s.count > (best?.name.count ?? 0), let f = engine.reader.frame(e) ?? rowFrame {
                    best = (s, f)
                }
            }
            if d < 4 { for c in engine.reader.children(e) { rec(c, d + 1) } }
        }
        rec(row, 0)
        return best
    }

    /// Trim the AX role suffix Pro Tools appends ("Audio 13 - Audio Track ", "Shown. Audio 13") down to
    /// the name a human (and the LLM) would say.
    static func cleanLabel(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let dash = s.range(of: " - ") { s = String(s[..<dash.lowerBound]) }     // "… - Audio Track"
        for prefix in ["Shown. ", "Hidden. "] where s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        return s.trimmingCharacters(in: .whitespaces)
    }
}
