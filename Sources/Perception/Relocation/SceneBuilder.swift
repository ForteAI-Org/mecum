import Foundation
import AppKit
import CoreGraphics
import CryptoKit
import CaptureSupport
import OCRSupport
import CVBackend
import LocatorCore

/// Builds a TEXT scene of an app window for an LLM — the image-free perception layer. CV-FIRST: captures the
/// frontmost (or named) app's main window and fuses the three local sources we already have — OCR text,
/// labeled ICONS (icon-DB hash match), and the app's menu commands (KB) — into a `SceneSnapshot`. No pixels
/// or hashes cross out; only labels + normalized positions. Nonisolated: capture/OCR run off the main actor.
public struct SceneBuilder: Sendable {
    let capture: WindowCaptureService
    let ocr: OCREngine
    let segmenter: ConnectedComponentSegmenter
    let hasher: SobelPerceptualHasher
    let icons: IconStore
    let knowledge: KnowledgeStore
    /// Whether a scene build TEACHES the brain (the engine and the watcher) or only reads it (peek, eval,
    /// `locator scene`, `debug-*`): a diagnostic persists nothing.
    let learns: Bool

    public init(capture: WindowCaptureService = .init(), ocr: OCREngine = .init(),
                segmenter: ConnectedComponentSegmenter = .init(params: .init(minAreaPx: 80)),
                hasher: SobelPerceptualHasher = .init(), icons: IconStore, knowledge: KnowledgeStore, learns: Bool = true) {
        self.capture = capture; self.ocr = ocr; self.segmenter = segmenter; self.hasher = hasher
        self.icons = icons; self.knowledge = knowledge; self.learns = learns
    }

    private struct AppInfo: Sendable { let bundle: String; let name: String; let pid: pid_t }

    /// Parsed-scene cache keyed by app, captured window title, dimensions and a full RGBA digest.
    /// A thumbnail average loses small movements and colors; it cannot prove a frame is unchanged.
    /// The 3s TTL also bounds reuse of nonvisual enrichment, which pixels alone cannot invalidate.
    final class SceneCache: @unchecked Sendable {
        static let shared = SceneCache()
        private let lock = NSLock()
        private var entries: [String: (fingerprint: [UInt8], scene: SceneSnapshot, at: Date, ocrFrame: OCRFrame?)] = [:]

        static func fingerprint(_ img: CGImage) -> [UInt8]? {
            let w = img.width, h = img.height
            guard w > 0, h > 0, let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            var rgba = [UInt8](repeating: 0, count: w * h * 4)
            return rgba.withUnsafeMutableBytes { bytes in
                guard let ctx = CGContext(data: bytes.baseAddress, width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                var hash = SHA256()
                hash.update(data: Data("\(w)x\(h):".utf8))
                hash.update(bufferPointer: UnsafeRawBufferPointer(bytes))
                return Array(hash.finalize())
            }
        }

        func lookup(bundle: String, windowTitle: String, fingerprint: [UInt8]?, now: Date) -> (scene: SceneSnapshot, at: Date)? {
            lock.lock(); defer { lock.unlock() }
            guard let fingerprint, let e = entries[bundle], e.fingerprint == fingerprint,
                  e.scene.windowTitle == windowTitle,
                  (0..<3).contains(now.timeIntervalSince(e.at)) else { return nil }
            return (e.scene, e.at)
        }

        func store(bundle: String, fingerprint: [UInt8]?, scene: SceneSnapshot, now: Date, ocrFrame: OCRFrame? = nil) {
            lock.lock(); defer { lock.unlock() }
            guard let fingerprint else { entries.removeValue(forKey: bundle); return }
            entries[bundle] = (fingerprint, scene, now, ocrFrame)
        }

        /// What OCR knew about the last frame of this window — the seed for an INCREMENTAL read of the
        /// next one (`IncrementalOCR`): only tiles whose pixels changed are recognized again. Correct by
        /// construction regardless of age (unchanged pixels are unchanged), so no time limit; the title
        /// check only avoids diffing against a different window.
        func previousOCR(bundle: String, windowTitle: String) -> OCRFrame? {
            lock.lock(); defer { lock.unlock() }
            guard let e = entries[bundle], e.scene.windowTitle == windowTitle else { return nil }
            return e.ocrFrame
        }

        /// The newest entry for a bundle with its PIXELS UNCHECKED — the pre-step scene. See
        /// `SceneBuilder.lastScene`, which is the only sanctioned way in.
        func latest(bundle: String, now: Date, maxAge: TimeInterval) -> (scene: SceneSnapshot, at: Date)? {
            lock.lock(); defer { lock.unlock() }
            guard let e = entries[bundle], now.timeIntervalSince(e.at) <= maxAge else { return nil }
            return (e.scene, e.at)
        }
    }

    /// THE PRE-STEP SCENE — the last scene this process parsed for `bundleID`, handed back with NO
    /// capture and NO check that the pixels still match.
    ///
    /// Every other entry point answers "what is on screen NOW". This one answers "what did the agent
    /// last SEE", which is what the *before* side of a comparison loop actually is. It exists because
    /// the frame-hash cache above — deliberately exact — cannot serve that side on real windows:
    /// measured on three surfaces, EVERY consecutive scroll step missed it and paid a 0.4–0.7s re-parse
    /// to learn what it already knew, because something tiny and irrelevant had moved (Pro Tools' meters,
    /// TextEdit's blinking caret, Finder's overlay scrollbar fading out). A scroll step cannot fit two
    /// parses inside its 1.5s budget, and the second parse buys nothing: the pane's geometry and the
    /// labels the agent has already read are exactly what did not change.
    ///
    /// The caller must earn it, and both rules are load-bearing:
    ///  • BEFORE SIDE ONLY. The scene handed back to the agent is always freshly built — a stale scene
    ///    presented as "current" is the one lie this engine must never tell.
    ///  • CHECK THE WINDOW. The cache is keyed by bundle, so the memo may describe a window that is no
    ///    longer in front (a dialog opened since). Confirm identity — title and shape — before trusting
    ///    its geometry; everything in a scene is window-normalized, so a proportional resize is harmless
    ///    but a different window is not.
    public func lastScene(bundleID: String, now: Date, notOlderThan: TimeInterval = 30) -> SceneSnapshot? {
        SceneCache.shared.latest(bundle: bundleID, now: now, maxAge: notOlderThan)?.scene
    }

    public func build(bundleID: String?, now: Date) async -> SceneSnapshot? {
        await buildScene(bundleID: bundleID, now: now)?.scene
    }

    /// Like `build`, but ALSO returns the exact window frame the scene was perceived from — so a caller
    /// that CLICKS (act/type/run_menu) computes screen points against the SAME window it perceived, never
    /// a second independent frontmostWindowFrame lookup that could resolve a DIFFERENT window (measured:
    /// with a dialog up, the scene came from the dialog but the click was computed against the main window
    /// behind it → the click missed and dismissed the panel).
    public func buildScene(bundleID: String?, now: Date) async -> (scene: SceneSnapshot, window: WindowCaptureService.WindowProbe)? {
        let t = StageTimer("buildScene \(bundleID ?? "frontmost")")
        let appOpt: AppInfo? = await MainActor.run {
            let running = bundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
                ?? NSWorkspace.shared.frontmostApplication
            guard let r = running, let bundle = r.bundleIdentifier else { return nil }
            return AppInfo(bundle: bundle, name: r.localizedName ?? bundle, pid: r.processIdentifier)
        }
        t.stamp("app-resolve (MainActor hop)")
        return await buildSceneResolved(app: appOpt, now: now)
    }

    /// Hop-free entry for callers that already resolved the app ON the main thread. Peek's timer runs
    /// under NSApp.run, where main-actor JOBS starve (the run loop pumps timers but the async executor
    /// is occupied by app.run's own job) — the default entry's MainActor hop never executes there and
    /// the build hangs forever (measured twice: semaphore deadlock, then silent no-draw).
    public func buildScene(bundle: String, name: String, pid: pid_t, now: Date) async -> (scene: SceneSnapshot, window: WindowCaptureService.WindowProbe)? {
        await buildSceneResolved(app: AppInfo(bundle: bundle, name: name, pid: pid), now: now)
    }

    private func buildSceneResolved(app appOpt: AppInfo?, now: Date) async -> (scene: SceneSnapshot, window: WindowCaptureService.WindowProbe)? {
        // PERMANENT per-stage telemetry, env-gated (LOCATOR_TIMING=1), zero-cost when off. Ad-hoc versions
        // of this were rebuilt for three separate hunts (Finder AXaugment 18.8s, the Premiere scene hang);
        // the START line matters as much as the stamps — a hang BEFORE the first stamp indicts the stage
        // in front of it, and a missing START indicts the caller.
        let t = StageTimer("buildSceneResolved \(appOpt?.bundle ?? "nil")")
        // Capture the WINDOW desktop-independently, never the screen region: a region composite returns
        // whatever is drawn ON TOP — measured: with Chrome covering Premiere, "Premiere's scene" was
        // Chrome's tab bar, and every element (and click target) would have belonged to the occluder.
        guard let app = appOpt else { return nil }
        guard let win = capture.frontmostWindowFrame(pid: app.pid) else { t.stamp("frontmostWindowFrame → nil"); return nil }
        t.stamp("frontmostWindowFrame")
        guard let shot = (try? await capture.captureMatchingWindow(
                  bundleID: app.bundle, title: win.title, axWindowFrameGlobalPt: win.frameGlobalPt)) ?? nil
        else { t.stamp("captureMatchingWindow → nil"); return nil }
        t.stamp("captureMatchingWindow")
        let img = shot.image
        let pixelSize = CGSize(width: img.width, height: img.height)
        // COORDINATES MUST MATCH THE CAPTURE: scene positions are normalized to shot.image, so the
        // window frame handed to callers must be the frame of what was ACTUALLY captured — not the
        // pre-capture probe. With a pop-up open the probe says "the popup" (it wins the window choice)
        // while capture-matching can fall back to the MAIN window: acting on that mismatch is the
        // measured popup misclick (clicked 'Routing Folder', selected nothing; supervised live).
        let capturedWin = WindowCaptureService.WindowProbe(title: shot.title ?? win.title,
                                                           frameGlobalPt: shot.frameGlobalPt)

        // Reuse a parse only for the same captured window and full-resolution visual fingerprint.
        let fingerprint = SceneCache.fingerprint(img)
        if let hit = SceneCache.shared.lookup(bundle: app.bundle, windowTitle: capturedWin.title ?? "",
                                              fingerprint: fingerprint, now: now) {
            SuperviseDump.markCacheHit(scene: hit.scene, now: now)
            t.stamp("cache-hit")
            return (hit.scene, capturedWin)   // the frame the (identical) capture came from
        }
        t.stamp("fingerprint+cacheLookup")

        // The BRAIN (persistent world model): classifies live detections at known slots + enriches the
        // scene with anchored names and group tags. It describes, never aims — positions stay live.
        let brain = ((try? knowledge.load(bundleID: app.bundle)) ?? nil)?.brain
        t.stamp("brainLoad")
        // AX AUGMENT (CV-first, augment-only — see AXSceneAugmentor): authoritative labels for the
        // structured lists AX exposes and OCR mangles. DEFAULT ON — proven on Pro Tools, where it turned
        // reach("Audio 13") from a 14.5s scroll-hunt failure into an instant hit. Purely additive
        // (never removes CV, returns [] for no-AX apps like Premiere → zero change), bounded walk.
        // LOCATOR_NO_AX_AUGMENT is the kill switch for A/B or if an untested app misbehaves.
        //
        // STARTED HERE, JOINED BELOW: the walk needs nothing the CV pass produces — just the pid and the
        // window frame — so it runs CONCURRENTLY with detection instead of queueing behind it. Measured
        // on Finder: AXaugment 0.09-0.12s next to detect's 0.28-0.38s, i.e. ~0.1s off every accurate
        // scene the app has AX for, twice per act round trip. It also reads the AX tree CLOSER to the
        // capture it augments rather than a third of a second later. (MainActor work overlapping
        // nonisolated CPU work — the detection never touches the main actor.)
        //
        // NORMALIZED TO `capturedWin`, NOT to the pre-capture probe: every position in a scene is
        // relative to the frame the caller CLICKS against (see capturedWin above), and with a pop-up
        // open the two genuinely differ — the probe says "the popup", capture-matching can answer with
        // the main window. Normalizing AX against the probe there would put every AX element in the
        // wrong coordinate space.
        let axWanted = ProcessInfo.processInfo.environment["LOCATOR_NO_AX_AUGMENT"] == nil
        // Its own kill switch, so the blast radius of the zero-AX popup read stays auditable (and so a
        // live A/B can turn it off without touching AX augmentation, which owns native menus).
        let popupRowsWanted = ProcessInfo.processInfo.environment["LOCATOR_NO_POPUP_ROWS"] == nil
        // AN OPEN POP-UP IS THE INTERACTION SURFACE, and its items are the one structure where AX beats
        // pixels outright: a long menu paints ONE PAGE and AX reports ALL its children (measured on
        // TextEdit's font popup — the scene stopped at the first page and act("Helvetica") honestly
        // missed). Read here, next to the capture, under the same kill switch as the rest of AX augment.
        // ONE classification of the app's windows (ticket 12): the frames, and WHAT KIND of pop-up the
        // front one is. The kind matters here because a pop-up AX has no idea exists must not be
        // answered by some other menu in the tree — see `requireFramedMenu` below.
        let popupSurfaces = capture.surfaces(pid: app.pid)
        let popupFrames = popupSurfaces.popups
        let frontPopupIsFloatingList = popupSurfaces.verdicts
            .first { $0.kind == .popupLayer || $0.kind == .floatingList }?.kind == .floatingList
        // Two lists, because they earn their place differently: `mergeable` elements dedupe against CV by
        // POSITION (the merge upgrades a CV element in place), while an OFF-VIEW menu row carries the
        // whole menu's rect and must only ever be APPENDED — position-matching it swallows every painted
        // row inside the menu (measured: TextEdit's off-view "Helvetica" ate the painted one's ✓ state).
        async let axPack: (mergeable: [SceneElement], menuRows: [SceneElement]) = axWanted
            ? await MainActor.run {
                let win = capturedWin.frameGlobalPt
                guard let popup = popupFrames.first else {
                    if ProcessInfo.processInfo.environment["LOCATOR_DEBUG"] != nil {
                        FileHandle.standardError.write(Data("[popup] no open popup window for pid \(app.pid)\n".utf8))
                    }
                    return (AXSceneAugmentor.tableElements(pid: app.pid, windowFrame: win), [])
                }
                // THE MENU GETS THE BUDGET FIRST, and the window's tables get a SHORTER one. While a menu
                // is tracking, the app's main thread is busy running it and every AX read queues behind
                // that; reading the window's tables first spent the wall clock and left the popup — the
                // surface the user is actually looking at — unread (measured: the scene came back with 0
                // menu items while `debug-popup` read all 88 a second later). The window's controls are
                // behind the menu anyway, so they are the half that can afford to be cut short.
                let snap = AXPopupReader.read(pid: app.pid, popupFrames: popupFrames,
                                              requireFramedMenu: frontPopupIsFloatingList)
                var mergeable = AXSceneAugmentor.tableElements(pid: app.pid, windowFrame: win, budgetSeconds: 0.6)
                // A control the OPEN MENU COVERS is not a click target — the click would land on the menu.
                // Dropping it also keeps the window's own "Helvetica" popup BUTTON from colliding with the
                // menu row of the same name (one ambiguous resolve where the agent needs one clear pick).
                mergeable = mergeable.filter { e in
                    guard e.pos.count == 4 else { return true }
                    let c = CGPoint(x: win.minX + (e.pos[0] + e.pos[2] / 2) * win.width,
                                    y: win.minY + (e.pos[1] + e.pos[3] / 2) * win.height)
                    return !popup.contains(c)
                }
                let menu = AXPopupReader.elements(from: snap.items, popup: popup, windowFrame: win)
                if ProcessInfo.processInfo.environment["LOCATOR_DEBUG"] != nil {
                    FileHandle.standardError.write(Data("[popup] \(popupFrames.count) popup window(s), AX read \(snap.items.count) items → \(menu.painted.count) painted + \(menu.offView.count) off-view\n".utf8))
                }
                return (mergeable, menu.painted + menu.offView)
            }
            : ([], [])
        let layers = detectLayers(in: img, appIcons: icons.load(bundleID: app.bundle), brain: brain,
                                  previousOCR: SceneCache.shared.previousOCR(bundle: app.bundle, windowTitle: capturedWin.title ?? ""))
        let grouped = layers.elements
        t.stamp("detect(OCR+seg+content)")
        var elements = Self.makeElements(grouped, pixelSize: pixelSize)
        if let brain { elements = brain.enrich(elements, app: app.bundle) }
        t.stamp("makeElements+enrich")
        let axEls = await axPack
        if !axEls.mergeable.isEmpty { elements = AXSceneAugmentor.merge(cv: elements, ax: axEls.mergeable) }
        // The open pop-up as a box in the frame the scene is normalized to — what every popup decision
        // below is expressed in (drop the window's read of those pixels, name the section).
        func popupBox(_ popup: CGRect) -> [Double] {
            let w = capturedWin.frameGlobalPt
            guard w.width > 0, w.height > 0 else { return [0, 0, 1, 1] }
            return [(popup.minX - w.minX) / w.width, (popup.minY - w.minY) / w.height,
                    popup.width / w.width, popup.height / w.height].map(Double.init)
        }
        // MENU ROWS ARE APPENDED, NEVER POSITION-MERGED. Inside an open menu AX read every row, so its
        // geometry is the app's own and CV's copy of the same text is a duplicate — one that made the
        // pick ambiguous ("2 elements labeled 'Helvetica'": the row, and the row's OCR). An off-view row
        // could not be position-merged anyway: its rect is the whole menu, which contains every painted
        // row (measured: it ate the painted "Helvetica" row's label and its ✓ state).
        if !axEls.menuRows.isEmpty, let popup = popupFrames.first {
            elements = AXPopupReader.dropCVDuplicates(cv: elements, menuRows: axEls.menuRows,
                                                      popupNormalized: popupBox(popup))
            elements += axEls.menuRows
        }
        t.stamp("AXaugment (joined)")
        // ZERO-AX POP-UP (ticket 07). Accessibility answered with nothing, so this list is custom-drawn —
        // Premiere's export format popup, DaVinci's resolution list: Qt/GPU widgets with no AX children —
        // and the window capture reads it as one run-on blob of garble ("Dport", "MWPLE"), an open list
        // the agent can see and cannot name an option in. Capture the POP-UP ITSELF at native scale and
        // cut its OCR lines into item rows, shaped exactly like the AX rows above so the map, the "open
        // menu" section and the act path cannot tell the two halves apart.
        //
        // SEQUENCED AFTER AX, not concurrent with it, and deliberately: this costs a second capture +
        // OCR, and a menu accessibility already answered must never pay it — that is every native menu
        // on the machine. Only a list with no AX at all reaches here, where the alternative is no items.
        //
        // AND IT REPORTS EVERY OUTCOME, including the ones that change nothing. Ticket 07's live
        // acceptance was run against a deploy 34 minutes older than this branch: the scene showed the
        // pre-ticket garble, the timing log was silent about pop-up rows (that binary had no such code),
        // and the silence read as "the row cut ran and produced fragments" — a live cycle spent chasing
        // a segmentation bug that did not exist. A stamp only inside the success path cannot be told
        // apart from a stamp that is not in the binary, so a pop-up being open is what triggers the line.
        if let popup = popupFrames.first {
            let outcome: PopupRowVision.Outcome
            if !popupRowsWanted {
                outcome = .off
            } else if !axEls.menuRows.isEmpty {
                outcome = .axAnswered(rows: axEls.menuRows.count)
            } else if let rows = await PopupRowVision.rows(pid: app.pid, popup: popup) {
                // ITS OWN CAPTURE, ALWAYS — never the scene's `img`, even when that capture's frame IS
                // the pop-up's. A pop-up's CGWindow can be a GPU proxy whose WINDOW capture returns the
                // parent's content: measured in ticket 06 on TextEdit, where `captureMatchingWindow` on
                // the open font menu came back as the MAIN WINDOW squeezed into the menu's 442×1640
                // frame ("VHVerica"). `capturePopupWindow` takes the screen REGION, which is compositor
                // truth about what is on top — reusing the cheaper pixels would segment the wrong ones.
                let rowEls = PopupRowVision.elements(from: rows, popup: popup,
                                                     windowFrame: capturedWin.frameGlobalPt)
                // TWO ROWS OR NOTHING. One row is not an enumeration — it is the same blob wearing a new
                // shape — and trading the window's own read of those pixels for it would lose more than
                // it adds. Below that bar the scene stays exactly as it was.
                if rowEls.count >= 2 {
                    // The adopted BANDS go with the drop: inside a row the agent can now name, the
                    // window capture's unlabeled word-boxes are that same word read worse (the live
                    // report's "~30 unlabeled icon fragments on a grid"). Outside them, they stay.
                    elements = PopupRowVision.dropCVInsidePopup(cv: elements, popupNormalized: popupBox(popup),
                                                                rowBands: rowEls.map(\.pos))
                    elements += rowEls
                    outcome = .adopted(rows: rowEls.count)
                } else {
                    // Reported as READ, not as adopted: what a live run needs to know here is how many
                    // rows the cut actually found under the bar (one, usually — a run-on blob).
                    outcome = .belowTheBar(rows: rows.count)
                }
            } else {
                // The pixels never arrived (region capture failed, timed out, or the capture circuit is
                // open). Distinct from reading zero rows: this indicts the capture, not the segmentation.
                outcome = .notCaptured
            }
            if ProcessInfo.processInfo.environment["LOCATOR_DEBUG"] != nil {
                FileHandle.standardError.write(Data("[popup] zero-AX row read: \(outcome.summary)\n".utf8))
            }
            t.stamp("popup rows (zero-AX) — \(outcome.summary)")
        }
        // SECTIONS: cut the window into named panels and file every element under its panel — the scene
        // becomes a MAP ("the S/M cells inside @DRUM BUSS"), not a flat soup of boxes.
        // The accepted IMAGE SURFACES are handed to the cut so a photo's interior can never propose a
        // seam (measured live on Premiere's Edit workspace: pink lines through the program monitor).
        let sectionRects = SectionDetector.detect(in: img, excluding: layers.contentRegions).map { Self.norm($0, pixelSize) }
        var (sectioned, sections) = SceneComposer.compose(elements: elements, sectionRects: sectionRects)
        Self.annotateScrollability(sections: &sections, elements: sectioned, app: app.bundle)
        elements = SceneComposer.coalesceParagraphs(sectioned)
        // THE OPEN MENU IS ITS OWN PANEL. Section rects come from the WINDOW's pixels, and a menu's rows
        // are not part of that geography — worse, an off-view row's rect is the whole menu, so geometry
        // files it under whatever tile happens to hold the middle of the screen. One named section makes
        // the map read like what the agent is actually looking at ("▣ open menu — 88 elements"), and the
        // map tier lists its rows generously instead of hiding them behind a drill-down.
        if let popup = popupFrames.first, elements.contains(where: { $0.role == "AXMenuItem" }) {
            for i in elements.indices where elements[i].role == "AXMenuItem" { elements[i].section = "open menu" }
            sections.insert(SceneSection(name: "open menu", pos: popupBox(popup)), at: 0)
        }
        // ACCORDION affordance: mark collapsed/expanded disclosure rows so the model knows a "> VIDEO"
        // must be CLICKED to reveal its options (a live agent couldn't "show me the GENERAL section"
        // because the chevron meaning was invisible). Clean label + does; brain affordances win if set.
        elements = elements.map { e in
            guard e.does == nil else { return e }
            return DisclosureRow.annotate([e])[0]
        }
        t.stamp("sections+compose+disclosure")
        // MENU commands (from the KB, if the app was explored).
        let known = (try? knowledge.load(bundleID: app.bundle)) ?? nil   // flatten AppKnowledge?? → AppKnowledge?
        let commands = known?.menuCommands.prefix(60).map { $0.path.joined(separator: " > ") } ?? []

        let snapshot = SceneSnapshot(bundleID: app.bundle, app: app.name, windowTitle: capturedWin.title ?? "",
                                     viewportPx: [img.width, img.height], elements: elements,
                                     sections: sections, commands: Array(commands))
        SceneCache.shared.store(bundle: app.bundle, fingerprint: fingerprint, scene: snapshot, now: now, ocrFrame: layers.ocrFrame)
        SuperviseDump.dump(frame: img, scene: snapshot, now: now)
        t.stamp("menuCommands+cacheStore+dump")
        // THE BRAIN LEARNS FROM EVERY PARSE. Until 2026-09-06 only the watcher ingested, so the agent's
        // ~1,200 scenes a month in the pro apps taught the brain nothing while the wall-clock decay aged
        // those very apps out of it (Pro Tools/DaVinci/Premiere came back with 3/3/1 anchors and every
        // taught name gone). Anchors, sibling groups and states now accrue from what the agent actually
        // sees — scoped to the captured WINDOW (its title family), so parses of the Edit page are never
        // evidence that a dialog's controls are gone. Menu rows and image surfaces are not places. Only
        // for allow-listed apps (the same gate the watcher honours), only when this builder `learns`
        // (diagnostics persist nothing). Off the main actor (the 21× lesson); `KnowledgeStore.mutate` is
        // write-behind, so a scroll burst costs one file write, not fifty.
        if learns, AllowlistStore(directory: knowledge.directoryURL).load().allows(app.bundle) {
            let brainDets = elements.compactMap { e -> BrainDetection? in
                guard e.role != "AXMenuItem", e.kind != "image", e.pos.count == 4 else { return nil }
                return BrainDetection(kind: e.kind, label: (e.unlabeled == true) ? "" : e.label, pos: e.pos, state: e.state)
            }
            if !brainDets.isEmpty {
                let store = knowledge, bundle = app.bundle
                let family = KnowledgeText.letters(capturedWin.title ?? "")
                let window: String? = family.isEmpty ? nil : family
                Task.detached(priority: .utility) {
                    try? store.mutate(bundleID: bundle) { _ = BrainUpdater.ingest(brainDets, into: &$0.brain, now: now, window: window) }
                }
            }
        }
        // PASSIVE SPATIAL MEMORY: every parse teaches the living memory where named things live —
        // "fritz → sidebar, y≈0.7" — so reach/navigation can consult instead of blind-searching.
        // Stable, human-scale labels only; one indexed transaction (~1ms).
        let sightables = elements.compactMap { e -> (label: String, section: String?, x: Double, y: Double)? in
            // A MENU ITEM IS NOT A PLACE. Popup rows are painted for a second at wherever the menu
            // happened to open; remembering "Helvetica lives at 0.42,0.31" would aim a later reach at a
            // spot that holds nothing. Spatial memory is for the window's furniture.
            guard e.role != "AXMenuItem", e.kind != "image" else { return nil }   // a picture is not a named place either
            guard e.unlabeled != true, e.pos.count == 4, e.label.count >= 3, e.label.count <= 40,
                  SceneDiff.isStableLabel(e.label) else { return nil }
            return (e.label, e.section, e.pos[0] + e.pos[2] / 2, e.pos[1] + e.pos[3] / 2)
        }
        LocatorMemory.shared.recordSightings(app: app.bundle, items: Array(sightables.prefix(120)))
        t.stamp("sightings")
        // SIBLING LEDGER: list-like navigation sections record their MEMBER ORDER — the thing that
        // survives scrolling (y does not). Family = the role word ("sidebar", "nav rail"), so frames
        // at different scroll offsets stitch into ONE remembered list per app. "content" joins ONLY
        // when a tall content section carries scroll evidence/truth — a content pane that IS a list
        // (bins, message lists) deserves the same order memory, but prose and canvases must never
        // pollute the ledger ("region N" stays out entirely: canonicalization would merge different
        // lists into one family).
        let contentIsListy = sections.contains { $0.name.hasPrefix("content") && $0.scrolls != nil }
        for family in ["sidebar", "nav rail"] + (contentIsListy ? ["content"] : []) {
            let rows = elements
                .filter { e in e.section?.hasPrefix(family) == true && e.unlabeled != true && e.kind != "image"
                    && e.pos.count == 4 && e.label.count >= 3 && e.label.count <= 40
                    && SceneDiff.isStableLabel(e.label) }
                .sorted { $0.pos[1] < $1.pos[1] }
            guard rows.count >= 4 else { continue }
            let xs = rows.map { $0.pos[0] }.sorted()
            let xMed = xs[xs.count / 2]
            let aligned = rows.filter { abs($0.pos[0] - xMed) <= 0.03 }
            guard aligned.count >= 4 else { continue }
            let dys = zip(aligned.dropFirst(), aligned).map { $0.0.pos[1] - $0.1.pos[1] }.filter { $0 > 0 }.sorted()
            let pitch = dys.isEmpty ? nil : dys[dys.count / 2]
            LocatorMemory.shared.recordMembers(
                app: app.bundle, family: family,
                members: aligned.map { (LocatorMemory.core($0.label), $0.label) }, rowPitch: pitch)
        }
        t.stamp("siblingLedger — done")
        return (snapshot, capturedWin)
    }

    /// SCROLLABILITY per section: ledger truth (someone really scrolled it) fused with ScrollScout's
    /// visual evidence (a list whose last row runs into the edge). Only TALL panels are annotated —
    /// the X-Y cut is a mosaic, and a small slice's edges are cuts through content, so "flush with
    /// the edge" is meaningless there (measured on the benchmark set). Call with the PRE-coalesce
    /// elements: paragraph coalescing merges the very rows listness is made of. Shared by the live
    /// build() and the offline debug pipeline so the two can't drift.
    /// `consultMemory: false` drops the ledger lookup and reports PURE VISUAL EVIDENCE — what the
    /// offline fixture gate must judge, since a learned verdict is machine-local state that would let a
    /// perception regression hide behind it (measured: DaVinci's learned "sidebar doesn't scroll"
    /// silenced the very false affordance the fixture exists to catch).
    /// The SIDEWAYS axis (`scrollsX`) is annotated from the ledger ALONE, and without the tall-pane
    /// gate: a horizontal strip is wide and short by nature (DaVinci's Deliver preset carousel), so the
    /// gate that protects vertical evidence would silence exactly the panes this axis is about — and
    /// proven truth needs no geometric protection.
    /// `memory` is the ledger seam (tests inject a temp-dir one; production is the shared singleton).
    public static func annotateScrollability(sections: inout [SceneSection], elements: [SceneElement],
                                             app: String, consultMemory: Bool = true,
                                             memory: LocatorMemory = .shared) {
        // Every section as a PANE first — the run walker needs the NEIGHBOURS, including the short ones
        // the annotation loop itself skips, and the family (canonical role) that says two stacked
        // panes are tiles of one list rather than a real boundary.
        let panes: [ScrollScout.Pane] = sections.map { s in
            guard s.pos.count == 4 else { return ScrollScout.Pane(rect: .zero, members: [], family: nil) }
            return ScrollScout.Pane(rect: CGRect(x: s.pos[0], y: s.pos[1], width: s.pos[2], height: s.pos[3]),
                                    members: elements
                                        .filter { $0.section == s.name && $0.pos.count == 4 }
                                        .map { CGRect(x: $0.pos[0], y: $0.pos[1], width: $0.pos[2], height: $0.pos[3]) },
                                    family: LocatorMemory.canonicalSection(s.name))
        }
        // The sideways lookup runs for EVERY section (see below), so it is memoized PER ROLE — a window
        // is ~15 sections but only ~4 distinct roles, and this is on the describe_scene path.
        var sidewaysByRole: [String: String?] = [:]
        for i in sections.indices {
            let s = sections[i]
            guard s.pos.count == 4 else { continue }
            // SIDEWAYS first, because it is the one annotation the tall-pane gate below must not reach.
            // Ledger-only and POSITIVE-only: the key is the canonical role exactly as `recordPane`
            // writes it (falling back to the raw name for a section role canonicalization doesn't
            // recognize, same as the writer), so the truth survives the volatile parenthetical churning
            // every capture.
            if consultMemory {
                let role = LocatorMemory.canonicalSection(s.name) ?? s.name
                if !sidewaysByRole.keys.contains(role) {
                    let sideways = ScrollAnnotator.annotateSideways(
                        learned: memory.paneScrollable(app: app, role: role, axis: "h"))
                    sidewaysByRole[role] = sideways
                    // A READ-HIT: the sideways axis has NO visual evidence path — this line exists in the
                    // map only because the ledger answered, so the read changed what the agent is told.
                    // Booked where the read happened (once per role, not once per section that reuses the
                    // memo), which is what keeps useful a subset of consulted.
                    if sideways != nil { memory.noteUsefulRead(.scrollPane, app: app) }
                }
                sections[i].scrollsX = sidewaysByRole[role] ?? nil
            }
            guard s.pos[3] >= 0.25 else { continue }
            // RULER VETO (caught supervising Premiere live): a NARROW strip whose labels are
            // dominantly bare numbers is a ruler/meter — the audio meter's dB ladder (0, -6 … -54)
            // has exactly the aligned-list + clipped-last-row signature ScrollScout hunts, and the
            // scene advertised "likely scrolls ↓" on a strip nothing can scroll (the probe honestly
            // no-op'd, but the advertisement invites the wasted round and skews reach's ranking).
            // Visual evidence only — LEARNED truth (a user really scrolling there) still wins below.
            // Width-gated so number-dense CONTENT (spreadsheets) keeps its evidence.
            let labeled = elements.filter { $0.section == s.name && $0.unlabeled != true }
            let numericish = labeled.filter { e in
                e.label.contains(where: \.isNumber) && e.label.filter(\.isLetter).count <= 1
            }
            let isRuler = s.pos[2] <= 0.12 && labeled.count >= 5
                && Double(numericish.count) >= 0.6 * Double(labeled.count)
            // Assessed as a RUN, not a tile (the DaVinci Project Settings false positive): the X-Y cut
            // split ONE aligned category list into two "sidebar (…)" sections and the invented boundary
            // read as edge truncation → "scrolls ↓ (more below)" on a pane nothing can scroll. Panes the
            // list runs straight through are judged together, so only real edges can truncate.
            let evidence: ScrollEvidence = isRuler ? .none : ScrollScout.assess(paneAt: i, in: panes)
            let learned = consultMemory ? LocatorMemory.canonicalSection(s.name).flatMap {
                memory.paneScrollable(app: app, role: $0)
            } : nil
            sections[i].scrolls = ScrollAnnotator.annotate(learned: learned, evidence: evidence)
            // A READ-HIT only where the ledger CHANGED the claim: the vertical axis has its own visual
            // evidence, so a remembered truth that says what the pixels already said changed nothing.
            // The counterfactual is a pure comparison and runs only under the accounting gate.
            if learned != nil, memory.readHitsEnabled,
               sections[i].scrolls != ScrollAnnotator.annotate(learned: nil, evidence: evidence) {
                memory.noteUsefulRead(.scrollPane, app: app)
            }
        }
    }

    /// Grouped detections → scene elements (normalized positions + identity keys). Shared by the live
    /// build() and offline consumers.
    public static func makeElements(_ grouped: [ElementGrouper.Grouped], pixelSize: CGSize) -> [SceneElement] {
        grouped.map { g in
            let pos = Self.norm(g.rect, pixelSize)
            let key = ObservedObject.makeIdentityKey(role: nil, identifier: nil, text: g.unlabeled ? nil : g.label, boundsNormalized: pos)
            return SceneElement(id: key, kind: g.kind, label: g.unlabeled ? "(unlabeled)" : g.label,
                                pos: pos, state: g.state, unlabeled: g.unlabeled ? true : nil)
        }
    }

    /// The full per-frame DETECTION pipeline on one image — OCR (knob-glyph filtered) + segments +
    /// switch detection (coalesce, knob-column inference, plain-knob gate, pixel state) + grouping.
    /// Shared by the live `build()` and offline consumers (brain ingest, harnesses) so they can never
    /// diverge. Pure with respect to the screen: input is the image. When a `brain` is given, a lone
    /// LIVE square at a known switch slot is classified as that switch (knob side vs the remembered
    /// pill = geometric state) — memory classifies live pixels, it never fabricates an element.
    public func detect(in img: CGImage, appIcons: AppIcons?, brain: UIBrain? = nil) -> [ElementGrouper.Grouped] {
        detectLayers(in: img, appIcons: appIcons, brain: brain).elements
    }

    /// The same production pass with its raw layers retained for Peek and icon collection.
    /// Sharing one pass avoids a second OCR/segmentation run and a divergent diagnostic detector.
    public func detectLayers(in img: CGImage, appIcons: AppIcons?, brain: UIBrain? = nil, previousOCR: OCRFrame? = nil)
        -> (elements: [ElementGrouper.Grouped], rawSegments: [CGRect], uiSegments: [CGRect], contentRegions: [CGRect],
            texts: [ElementGrouper.TextRun], ocrFrame: OCRFrame) {
            _ = WindowCoordinateContext(axWindowOriginGlobalPt: .zero, backingScale: 1,
                                          imagePixelSize: CGSize(width: img.width, height: img.height))
        let timer = StageTimer("detectLayers \(img.width)×\(img.height)")
        let suppress = ProcessInfo.processInfo.environment["LOCATOR_NO_CONTENT_SUPPRESS"] == nil
        // OCR (Vision — ANE/GPU) ‖ segmentation (CPU) ‖ image-surface pixel analysis (CPU): the three
        // are independent until grouping, so they run CONCURRENTLY and the wall time is the longest of
        // them, not the sum. Measured before this (2026-09-06, 700² peek tile): a strictly serial
        // 0.21 s CV stack followed by 0.06 s of OCR.
        let join = LayerJoin()
        let ocrEngine = ocr, seg = segmenter
        DispatchQueue.concurrentPerform(iterations: 3) { i in
            let t0 = Date()
            switch i {
            case 0:
                // Accurate OCR, but only where the pixels changed since `previousOCR` (see IncrementalOCR).
                let o = IncrementalOCR.recognize(in: img, previous: previousOCR, ocr: ocrEngine)
                join.ocr = o.runs; join.ocrFrame = o.frame; join.ocrMode = o.mode.summary
            case 1: join.segments = seg.segment(in: img, region: nil).map(\.bboxPx)
            default: join.surface = suppress ? ImageSurfaceDetector.analyze(in: img) : .empty
            }
            join.seconds[i] = Date().timeIntervalSince(t0)
        }
        timer.stamp(String(format: "ocr %.3f [%@] ‖ segment %.3f ‖ surfaces %.3f", join.seconds[0], join.ocrMode, join.seconds[1], join.seconds[2]))
        // TEXT runs (OCR) — raw fragments; the grouper merges baselines + pairs captions below.
        let runs = join.ocr
            .filter { !ElementGrouper.isKnobGlyph($0.text) }   // knob circles misread as "O" are not text
        let textRuns = runs.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { ElementGrouper.TextRun(rect: $0.boxImagePx, text: $0.text) }
        // ICON candidates (segment → exclude text → hash → match the icon DB for a label). Switches are
        // detected on COALESCED fragments (a low-contrast toggle segments as knob+track pieces) and their
        // on/off state read from pixels — zero-AX apps have no other state source.
        let ocrBoxes = runs.map(\.boxImagePx)
        let rawSegments = join.segments
        var segBoxes = rawSegments
        // CONTENT-REGION SUPPRESSION (the moat fix): a photo/video shreds into dozens of spurious
        // segments (measured: a Messi image grid = 344 elements, mostly garbage inside photos). Detect
        // the photographic regions and drop the segments INSIDE them, keeping ONE element per image so
        // it stays targetable. Text/OCR is untouched (captions survive). Kill switch for A/B + safety.
        var contentRegions: [CGRect] = []
        if suppress {
            contentRegions = ImageSurfaceDetector.finish(join.surface, textBoxes: ocrBoxes)
            // Keep the older grid detector as a fallback, but do not replace individually resolved
            // photos with its larger photo-grid rectangle (which would also swallow the captions).
            let fallback = ContentRegionDetector.contentRegions(in: img, segments: segBoxes, textBoxes: ocrBoxes)
            contentRegions += fallback.filter { old in !contentRegions.contains { $0.intersects(old) } }
            if !contentRegions.isEmpty {
                // A segment is suppressed only if it sits MOSTLY inside a photo (≥70% of its area) — an
                // element straddling the photo edge (a caption bar, an overlaid control) is kept.
                segBoxes = segBoxes.filter {
                    !ImageSurfaceDetector.containsMost(of: $0, in: contentRegions)
                        || ImageSurfaceDetector.hasControlBacking($0, in: img, regions: contentRegions)
                }
            }
        }
        // Surviving media glyphs are uncertain overlays, not switch/checkbox evidence. Keep their
        // geometry separate so image lettering cannot become a caption or a fabricated toggle state.
        let overlaySegments = segBoxes.filter { ImageSurfaceDetector.containsMost(of: $0, in: contentRegions) }
        let controlSegments = segBoxes.filter { !ImageSurfaceDetector.containsMost(of: $0, in: contentRegions) }
        let runTuples = runs.map { (text: $0.text, box: $0.boxImagePx) }
        // CHECKBOX / RADIO controls come FIRST: their state lives inside them, and every confirmed one
        // LEAVES the switch detector's input, so a radio dot can never be re-read as a knob (measured on
        // DaVinci's dark Qt: the selected "Square" radio anchored to an unrelated pill 100px up the column
        // and its dot's left-of-centre position declared it [off]).
        let (marks, switchSegs) = ToggleStateReader.markControls(segments: controlSegments, in: img)
        var rejectedKnobs: [CGRect] = []   // colored/busy column squares — icons, not switches (kept as boxes)
        var toggles = ElementGrouper.toggleCandidates(segments: switchSegs, isToggleShaped: ToggleStateReader.isToggleShaped)
            .filter { !ElementGrouper.switchVetoedByText($0.rect, runs: runTuples) }   // real words veto; chrome glyphs ("C","CC") don't
            .filter { sw in
                guard sw.assumed else {
                    return ToggleStateReader.hasFlatEnd(leftEnd: img.cropping(to: sw.knobSquare.integral),
                                                        rightEnd: img.cropping(to: sw.rightEndSquare.integral))
                }
                // A column-inferred knob must be a plain AND ACHROMATIC disc: a knob-only-visible switch on
                // a dark panel is gray/white. Measured: every false assumed switch was a COLORED icon —
                // Finder's blue folder badges (sat 0.20) read '[on]' and Chrome's favicon (0.21) — while
                // real knobs measured sat 0.00. A rejected knob is still an ICON (its coalesced square is
                // kept below as a plain icon): measured on Keynote, dropping the union lost 5 style tiles.
                guard let knob = img.cropping(to: sw.knobSquare.integral), ToggleStateReader.isPlainKnob(knob),
                      let m = ToggleStateReader.metrics(of: knob), m.saturation <= 0.12 else {
                    rejectedKnobs.append(sw.knobSquare.integral); return false
                }
                return true
            }
        // BRAIN slot rescue: a live square at a REMEMBERED switch slot is that switch — even alone
        // (per-frame column inference needs siblings; memory doesn't). Knob side vs the remembered
        // pill bounds gives the state geometrically. No live segment at the slot → nothing is made up.
        if let brain {
            let W = Double(img.width), H = Double(img.height)
            for slot in brain.switchMemberSlots() {
                let pill = CGRect(x: slot.pos[0] * W, y: slot.pos[1] * H, width: slot.pos[2] * W, height: slot.pos[3] * H)
                guard !toggles.contains(where: { $0.rect.insetBy(dx: -4, dy: -4).intersects(pill) }) else { continue }
                guard let knob = switchSegs.first(where: { s in
                    let aspect = s.width / max(s.height, 1)
                    return aspect >= 0.8 && aspect <= 1.25
                        && abs(s.height - pill.height) <= 0.3 * pill.height
                        && abs(s.midY - pill.midY) <= 0.5 * pill.height
                        && s.minX >= pill.minX - 6 && s.maxX <= pill.maxX + 6
                }), img.cropping(to: knob.integral).map(ToggleStateReader.isPlainKnob) == true else { continue }
                toggles.append(ElementGrouper.Switch(rect: pill,
                                                     inferredState: knob.midX < pill.midX ? "off" : "on",
                                                     assumed: true))
            }
        }
        var iconRuns: [ElementGrouper.Icon] = []
        var statelessPills: [CGRect] = []
        for sw in toggles {
            let box = sw.rect.integral
            // State priority: anchored geometric (knob side, certain) > pixel read (saturation/luma) >
            // the assumed-column convention (square at the pill's LEFT edge by construction ⇒ off) —
            // pixels on a knob-only-visible switch are ambiguous by definition, geometry is not.
            let state = sw.inferredState
                ?? img.cropping(to: box).flatMap(ToggleStateReader.state(of:))
                ?? (sw.assumed ? "off" : nil)
            // A pill whose state cannot be read is NOT a switch — it is a button, a chip, a thumbnail
            // that passed the shape gate. Left as a toggle it would row-pair with a label far to its
            // left and become a false control; as a plain icon it is just an unlabeled box.
            guard let state else { statelessPills.append(box); continue }
            iconRuns.append(ElementGrouper.Icon(rect: box, isToggle: true, state: state))
        }
        for m in marks { iconRuns.append(ElementGrouper.Icon(rect: m.rect.integral, isMark: true, state: m.state)) }
        // The frame's text line height — what tells a punctuation glyph from an icon (median OCR box).
        let lineH: CGFloat = {
            let hs = ocrBoxes.map(\.height).sorted()
            return hs.count >= 3 ? hs[hs.count / 2] : 0
        }()
        // An icon is at most a modest fraction of the window: a 407×224 "icon" (measured: Notes' banner
        // card) is a panel, and it went on to swallow the note below it as a 343×171 "control".
        // Icon size cap (measured: Notes' 407×224 note preview was a false icon) — lifted for a box with
        // a centred caption beneath it, which is a THUMBNAIL (Keynote theme tiles), up to half the frame.
        let minSide = CGFloat(min(img.width, img.height))
        let iconMaxSide = 0.14 * minSide, thumbMaxSide = 0.5 * minSide
        for seg in (switchSegs + statelessPills + rejectedKnobs) where KnowledgeHarvester.isLikelyIcon(seg, ocrBoxes: ocrBoxes) {
            let box = seg.integral
            let side = max(box.width, box.height)
            guard box.width >= 10, box.height >= 10,
                  side <= iconMaxSide || (side <= thumbMaxSide && ElementGrouper.hasCaptionBelow(box, ocrBoxes: ocrBoxes)),
                  !ElementGrouper.isTextGlyph(box, ocrBoxes: ocrBoxes, lineHeight: lineH),
                  !iconRuns.contains(where: { $0.rect.insetBy(dx: -1, dy: -1).contains(box) }),   // already a switch/mark (or its knob)
                  let crop = img.cropping(to: box) else { continue }
            var label: String?
            // Nearest LABELED icon names the segment (maxDistance 10, slightly looser than peek's dedup 8:
            // labeled entries are user-taught and few, so a wider net is safe — the old first-match-any at
            // 8 let unlabeled near-duplicates absorb the match and labels never surfaced).
            if let ai = appIcons, let lbl = ai.bestLabel(edgeHash: hasher.edgeHash(of: crop), maxDistance: 10) { label = lbl }
            iconRuns.append(ElementGrouper.Icon(rect: box, label: label))
        }
        // Image surfaces do not participate in caption/control pairing: a video frame must not
        // borrow its transport timecode as a control label. Keep OCR available as ordinary text.
        var grouped = ElementGrouper.group(texts: textRuns, icons: iconRuns)
        grouped += overlaySegments.filter { KnowledgeHarvester.isLikelyIcon($0, ocrBoxes: ocrBoxes) }
            .map { ElementGrouper.Grouped(rect: $0.integral, kind: "overlay-candidate", label: "", unlabeled: true) }
        grouped += contentRegions.map { ElementGrouper.Grouped(rect: $0.integral, kind: "image", label: "image") }
        timer.stamp("suppress + states + group")
        return (grouped, rawSegments, segBoxes, contentRegions, textRuns,
                join.ocrFrame ?? OCRFrame(grid: .empty(width: img.width, height: img.height), runs: join.ocr))
    }

    /// Window-normalized [x,y,w,h], rounded to 3 decimals (positions are disambiguation hints, not precise).
    public static func norm(_ box: CGRect, _ pixelSize: CGSize) -> [Double] {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return [0, 0, 0, 0] }
        func r(_ v: CGFloat) -> Double { (Double(v) * 1000).rounded() / 1000 }
        return [r(box.minX / pixelSize.width), r(box.minY / pixelSize.height),
                r(box.width / pixelSize.width), r(box.height / pixelSize.height)]
    }
}

/// Hand-off for the three concurrent `detectLayers` front stages. Each field is written by exactly one
/// `concurrentPerform` iteration and read only after the call returns (which joins them all), so no lock
/// is needed; the class exists only because the closure cannot write captured `let`s.
private final class LayerJoin: @unchecked Sendable {
    var ocr: [OCRResult] = []
    var ocrFrame: OCRFrame?
    var ocrMode = ""
    var segments: [CGRect] = []
    var surface: ImageSurfaceDetector.Analysis = .empty
    var seconds: [TimeInterval] = [0, 0, 0]   // per-branch wall time, for LOCATOR_TIMING
}
