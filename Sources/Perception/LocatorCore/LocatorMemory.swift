import Foundation
import CoreGraphics

/// The LIVING MEMORY (`~/Library/Application Support/Locator/locator.db`) — the third cache layer.
/// Frames are cached in SceneCache; parsed scenes feed SIGHTINGS here passively (where named things
/// live, per app); agent turns feed EXPERIENCE (which verb satisfied which phrasing). Consulted before
/// expensive work: reach orders its scroll candidates by remembered section, the chat frontend answers
/// remembered phrasings without a model round ("imitated cache hit"), near-matches inject as hints
/// (the lite RAG). Retrieval is lexical + indexed — no embeddings, no network.
public final class LocatorMemory: @unchecked Sendable {
    public static let shared: LocatorMemory = {
        let m = LocatorMemory()
        m.registerExitFlush()
        return m
    }()
    private let store: SQLiteStore?
    /// READ-HIT ACCOUNTING (env-gated, `LOCATOR_READ_HITS`). See ``ReadHitLedger``.
    private let readLedger: ReadHitLedger
    /// The directory this instance's `locator.db` sits in — `nil` only when no location could be resolved
    /// at all. A non-nil directory is where the store was MEANT to go, not proof that it opened: an
    /// unwritable path leaves every read empty and every write dropped, which ``init`` says out loud
    /// rather than leaving to be discovered as "memory learned nothing".
    public let directory: URL?

    /// - `countReads`: read-hit accounting on/off. `nil` (production) asks the environment; a test says
    ///   what it means, exactly as `directory` does.
    public init(directory: URL? = nil, countReads: Bool? = nil) {
        readLedger = ReadHitLedger(on: Self.readHitsGateOn(
            env: ProcessInfo.processInfo.environment, injected: countReads))
        let dir = directory ?? Self.defaultDirectory()
        self.directory = dir
        guard let dir else { store = nil; return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = SQLiteStore(path: dir.appendingPathComponent("locator.db").path)
        if store == nil {
            // A DEAD STORE IS NOT ALLOWED TO BE QUIET. The reachable cause is a pinned
            // `LOCATOR_MEMORY_DIR` that cannot be opened (a typo, a read-only volume): every read then
            // returns empty and every write is dropped, so a session pointed at a scratch store would
            // look exactly like an engine that learns nothing. One line on stderr (the engine's log —
            // stdout is the MCP channel) is the difference between a diagnosis and a hunt.
            FileHandle.standardError.write(Data("[memory] could not open \(dir.path)/locator.db — memory is DISABLED for this process\n".utf8))
        }
        store?.exec("""
            CREATE TABLE IF NOT EXISTS sighting(
                app TEXT NOT NULL, core TEXT NOT NULL, label TEXT NOT NULL, section TEXT, detail TEXT,
                x REAL NOT NULL, y REAL NOT NULL, seen INTEGER NOT NULL, last REAL NOT NULL,
                PRIMARY KEY(app, core));
            CREATE TABLE IF NOT EXISTS scroll_pane(
                app TEXT NOT NULL, role TEXT NOT NULL, axis TEXT NOT NULL,
                scrollable INTEGER NOT NULL, px_per_tick REAL, updated REAL NOT NULL,
                noop_dir TEXT, noop_at REAL,
                PRIMARY KEY(app, role, axis));
            CREATE TABLE IF NOT EXISTS wheel_polarity(
                app TEXT NOT NULL, axis TEXT NOT NULL, up_sign INTEGER NOT NULL, updated REAL NOT NULL,
                PRIMARY KEY(app, axis));
            CREATE TABLE IF NOT EXISTS experience(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                app TEXT, phrase TEXT NOT NULL, tokens TEXT NOT NULL,
                tool TEXT NOT NULL, args TEXT NOT NULL,
                ok INTEGER NOT NULL DEFAULT 0, fail INTEGER NOT NULL DEFAULT 0, last REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS experience_last ON experience(last DESC);
            DELETE FROM experience WHERE id NOT IN (SELECT MAX(id) FROM experience GROUP BY tokens);
            CREATE UNIQUE INDEX IF NOT EXISTS experience_key ON experience(tokens);
            CREATE TABLE IF NOT EXISTS section_member(
                app TEXT NOT NULL, family TEXT NOT NULL, core TEXT NOT NULL, label TEXT NOT NULL,
                rank REAL NOT NULL, seen INTEGER NOT NULL, last REAL NOT NULL,
                PRIMARY KEY(app, family, core));
            CREATE TABLE IF NOT EXISTS section_list(
                app TEXT NOT NULL, family TEXT NOT NULL, row_pitch REAL, updated REAL NOT NULL,
                PRIMARY KEY(app, family));
            CREATE TABLE IF NOT EXISTS interaction(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL, app TEXT NOT NULL, kind TEXT NOT NULL, section TEXT, detail TEXT);
            CREATE INDEX IF NOT EXISTS interaction_app_ts ON interaction(app, ts DESC);
            -- Created even with the accounting gate OFF: the memory VIEW is a separate process whose own
            -- gate is off, and it must still be able to read what the engine counted.
            CREATE TABLE IF NOT EXISTS read_hit(
                store TEXT NOT NULL, app TEXT NOT NULL,
                consulted INTEGER NOT NULL DEFAULT 0, useful INTEGER NOT NULL DEFAULT 0,
                last REAL NOT NULL,
                PRIMARY KEY(store, app));
            -- The TRANSCRIPT LEDGER (2026-09-06): one row per agent turn — the phrase, the tool calls it
            -- took (args redacted of typed text) with their outcome words, and the answer. "We did this
            -- together last time" becomes replayable and measurable; gemini sessions used to leave nothing.
            CREATE TABLE IF NOT EXISTS turn(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL, session TEXT NOT NULL, app TEXT,
                phrase TEXT NOT NULL, tools TEXT NOT NULL, answer TEXT, ok INTEGER NOT NULL,
                rounds INTEGER, imitated INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX IF NOT EXISTS turn_ts ON turn(ts DESC);
            """)
        migrate()
    }

    // MARK: where the store lives

    /// WHERE THE PROCESS-WIDE STORE LIVES, decided in one place — because a write nobody named still
    /// lands somewhere. It landed here: 1,175 of the 4,221 rows in the live interaction ledger were unit
    /// test fixtures (`com.x` / `btn4` / `ts = 0`), 235 identical runs of one test whose ndjson honoured
    /// its temp directory while its SQLite half went to ``shared``. 28% of the table, so every number
    /// measured on this machine was measured through fixture noise.
    ///
    /// Resolution order:
    ///   1. `LOCATOR_MEMORY_DIR` — points a DEPLOYED binary at a scratch store, so a manual session or a
    ///      live acceptance run need not write into the real memory either.
    ///   2. Under XCTest, a per-process temp directory. Constructor injection already exists and most
    ///      tests use it; this is the backstop for the write a test does not know it is making.
    ///   3. `~/Library/Application Support/Locator` — the live store, unchanged.
    public static func defaultDirectory() -> URL? {
        resolveDirectory(
            env: ProcessInfo.processInfo.environment,
            underTest: NSClassFromString("XCTestCase") != nil,
            appSupport: try? FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask, appropriateFor: nil, create: true))
    }

    /// The decision as a pure function, so both the live branch and the under-test branch are testable
    /// from inside a test process (where `underTest` is otherwise permanently true).
    static func resolveDirectory(env: [String: String], underTest: Bool, appSupport: URL?) -> URL? {
        if let pinned = env["LOCATOR_MEMORY_DIR"], !pinned.isEmpty, !pinned.contains("${") {
            return URL(fileURLWithPath: (pinned as NSString).expandingTildeInPath, isDirectory: true)
        }
        if underTest {
            return FileManager.default.temporaryDirectory.appendingPathComponent(
                "locator-test-store-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        return appSupport?.appendingPathComponent("Locator", isDirectory: true)
    }

    // MARK: read-hit accounting (what any of this memory is actually WORTH)

    /// Is read-hit accounting on for this process? `LOCATOR_READ_HITS` in production, the constructor
    /// argument in a test — and the argument wins, so a test never depends on the shell it ran from.
    /// ON by default since 2026-09-06 (`LOCATOR_READ_HITS=0` switches it off): measured zero-cost
    /// (0.984 s off / 0.979 s on), and two weeks of it being off left six rows from August — every
    /// keep-or-prune argument about memory was taste again.
    static func readHitsGateOn(env: [String: String], injected: Bool?) -> Bool {
        injected ?? (env["LOCATOR_READ_HITS"] != "0")
    }

    /// Whether a CALLER should bother computing whether its read mattered. The counterfactual checks at
    /// the mark sites ("would the guide have said the same with no memory?") are cheap but not free, and
    /// with the gate off they must not run at all.
    public var readHitsEnabled: Bool { readLedger.on }

    /// ONE CONSULTATION of `store`. Called by the read methods themselves — accounting a caller can
    /// forget is accounting that lies, so the question is counted where it is asked, not where it is
    /// used. `snapshotJSON` and ``readHits()`` deliberately do NOT count: they are the memory VIEW
    /// reading the ledger, and an instrument must not report its own weight.
    /// Public because ONE memory does not live in this file: the UI brain is a per-app JSON store whose
    /// read path cannot count itself through here. Every SQLite read path below counts its own
    /// consultation — a caller must not add a second one for those.
    public func noteConsultedRead(_ store: MemoryStore, app: String?) { noteRead(store, app: app) }

    private func noteRead(_ store: MemoryStore, app: String?) {
        guard readLedger.on, let batch = readLedger.note(store: store, app: app, useful: false) else { return }
        writeReadHits(batch)
    }

    /// THIS CONSULTATION CHANGED WHAT THE ENGINE DID — claimed by the consumer, because only the
    /// consumer knows. The bar every call site holds itself to: the engine's behaviour would have
    /// DIFFERED had the memory answered nothing.
    ///
    /// An ABSENCE that changed an outcome is deliberately not claimable here (reach caps its probe when
    /// nothing is remembered about a target, and that is not the sighting store being useful). Crediting
    /// it would let a store earn "useful" for holding no rows — exactly backwards for the prune-or-keep
    /// question this ledger exists to answer.
    public func noteUsefulRead(_ store: MemoryStore, app: String?) {
        guard readLedger.on, let batch = readLedger.note(store: store, app: app, useful: true) else { return }
        writeReadHits(batch)
    }

    /// Write out everything buffered. The cadence handles a live process; this is for a process that is
    /// about to end (see ``registerExitFlush()``) and for tests.
    public func flushReadHits() {
        guard readLedger.on else { return }
        writeReadHits(readLedger.drain())
    }

    /// The ledger, for the memory view. Not counted as a read (see ``noteRead``).
    public func readHits() -> [ReadHit] {
        guard let store else { return [] }
        return store.query("SELECT store, app, consulted, useful, last FROM read_hit ORDER BY consulted DESC")
            .compactMap { r in
                guard let s = r["store"] as? String, let a = r["app"] as? String,
                      let c = r["consulted"] as? Int, let u = r["useful"] as? Int,
                      let l = r["last"] as? Double else { return nil }
                return ReadHit(store: s, app: a, consulted: c, useful: u, last: Date(timeIntervalSince1970: l))
            }
    }

    /// The tail of a short-lived process would otherwise be lost: an `mcp --embedded` run that answers
    /// three tool calls and exits buffers its last reads and dies with them, which is precisely the shape
    /// of a live acceptance exercise. Registered only for ``shared`` (the process-wide store) and only
    /// with the gate on.
    private func registerExitFlush() {
        guard readLedger.on else { return }
        atexit { LocatorMemory.shared.flushReadHits() }
    }

    private func writeReadHits(_ deltas: [ReadHitLedger.Delta]) {
        guard let store, !deltas.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        store.transaction { run in
            for d in deltas {
                _ = run("""
                    INSERT INTO read_hit(store, app, consulted, useful, last) VALUES(?,?,?,?,?)
                    ON CONFLICT(store, app) DO UPDATE SET
                        consulted = consulted + excluded.consulted,
                        useful    = useful    + excluded.useful,
                        last      = excluded.last
                    """, [d.store, d.app, d.consulted, d.useful, now])
            }
        }
    }

    /// Canonical SECTION identity for memory: the ROLE, with the volatile parenthetical header and the
    /// "#N" ordinal stripped — both churn every capture ("content (Oggi)", "content (Sabato 4 luglio)",
    /// "content #2" are all ONE pane). The unification the graph made visible: ~17 "content (…)" variants
    /// collapse to "content", ~8 "sidebar (…)" to "sidebar", "region N" to "region".
    public static func canonicalSection(_ section: String?) -> String? {
        guard var t = section?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        if let paren = t.range(of: " (") { t = String(t[..<paren.lowerBound]) }
        if let hash = t.range(of: " #") { t = String(t[..<hash.lowerBound]) }
        t = t.trimmingCharacters(in: .whitespaces)
        for role in ["nav rail", "sidebar", "top bar", "bottom bar", "content"] where t == role || t.hasPrefix(role + " ") { return role }
        if t == "region" || t.hasPrefix("region ") { return "region" }
        return nil   // not a recognized role → UNKNOWN (was volatile-header cruft: "Q Cerca…", "Oggi v", a date)
    }

    /// One-time data unification (gated by PRAGMA user_version → runs once per DB, not per process; every
    /// step is idempotent, so a rare cross-process double-run is harmless). Collapses the churny section
    /// strings that fragmented the memory, merges the duplicated scroll panes, and dedupes the experience
    /// ledger to one verb per phrasing (keeping the most recent).
    private func migrate() {
        guard let store else { return }
        migrateToV4()
        // v5: interaction.actor — the event spine records WHO acted (user watch events vs agent tool
        // acts, queryable together but distinguishable; NULL = legacy rows = user). Runs in the SAME
        // init as v4 so a fresh DB is fully current before its first write.
        let v5 = store.query("PRAGMA user_version").first?["user_version"] as? Int ?? 0
        if v5 >= 4, v5 < 5 {
            let hasActor = store.query("PRAGMA table_info(interaction)").contains { ($0["name"] as? String) == "actor" }
            store.transactionChecked { run in
                var ok = true
                if !hasActor { ok = ok && run("ALTER TABLE interaction ADD COLUMN actor TEXT", []) }
                ok = ok && run("PRAGMA user_version=5", [])
                return ok
            }
        }
        // v6: scroll_pane.noop_dir / .noop_at — the LAST GESTURE THIS PANE IGNORED, kept SEPARATE from
        // `scrollable`. A sideways no-op may not be written as `scrollable = 0` (that would erase a
        // truth an earlier real scroll proved, and no visual heuristic can re-infer it), yet a guide
        // that recommends a call already answered `acted_noop` costs the agent a round — ticket 15. Two
        // columns keep both facts: what the pane CAN do, and what it just refused to do.
        let v6 = store.query("PRAGMA user_version").first?["user_version"] as? Int ?? 0
        if v6 >= 5, v6 < 6 {
            let cols = store.query("PRAGMA table_info(scroll_pane)").compactMap { $0["name"] as? String }
            store.transactionChecked { run in
                var ok = true
                if !cols.contains("noop_dir") { ok = ok && run("ALTER TABLE scroll_pane ADD COLUMN noop_dir TEXT", []) }
                if !cols.contains("noop_at") { ok = ok && run("ALTER TABLE scroll_pane ADD COLUMN noop_at REAL", []) }
                ok = ok && run("PRAGMA user_version=6", [])
                return ok
            }
        }
        // v7: turn.rounds / turn.imitated — the MODEL ROUND COUNT of a turn, and whether it was served
        // from memory with no model round at all (⚡). Rounds-per-task is the harness headline and it
        // CANNOT BE RECOVERED RETROACTIVELY: every session driven before this column existed is a session
        // that can never contribute to it (harness ticket 01). NULL means UNKNOWN — an MCP-driven turn
        // (Claude Code / Desktop) has no user phrase and no loop of ours to count — and `unknown` and `0`
        // mean opposite things to the headline, so legacy rows stay NULL rather than being read as free.
        let v7 = store.query("PRAGMA user_version").first?["user_version"] as? Int ?? 0
        if v7 >= 6, v7 < 7 {
            let cols = store.query("PRAGMA table_info(turn)").compactMap { $0["name"] as? String }
            store.transactionChecked { run in
                var ok = true
                if !cols.contains("rounds") { ok = ok && run("ALTER TABLE turn ADD COLUMN rounds INTEGER", []) }
                if !cols.contains("imitated") { ok = ok && run("ALTER TABLE turn ADD COLUMN imitated INTEGER NOT NULL DEFAULT 0", []) }
                ok = ok && run("PRAGMA user_version=7", [])
                return ok
            }
        }
    }

    private func migrateToV4() {
        guard let store else { return }
        let v = store.query("PRAGMA user_version").first?["user_version"] as? Int ?? 0
        guard v < 4 else { return }
        // v4: sighting.detail — the FULL section string kept alongside the canonical role, so the
        // unification loses no context ("sidebar (Connessioni esterne)" survives as detail).
        let hasDetail = store.query("PRAGMA table_info(sighting)").contains { ($0["name"] as? String) == "detail" }
        // Pre-read what needs rewriting (queries can't run inside the write transaction body); the
        // statements themselves execute in ONE checked all-or-nothing transaction below — either every
        // step lands and the version bumps, or everything (version included) rolls back and the
        // migration simply re-runs on the next init. Adversarial review: the previous 4 auto-commit
        // statements with ignored returns + an unconditional bump could permanently brick the
        // experience upsert (a BUSY dedup left tokens-dups, the unique index failed, version said done).
        let sections = store.query("SELECT DISTINCT section FROM sighting WHERE section IS NOT NULL")
        let panes = store.query("SELECT app, role, axis, scrollable, px_per_tick FROM scroll_pane")
        let now = Date().timeIntervalSince1970
        store.transactionChecked { run in
            var ok = true
            if !hasDetail { ok = ok && run("ALTER TABLE sighting ADD COLUMN detail TEXT", []) }
            for r in sections {
                guard let sec = r["section"] as? String else { continue }
                let canon = Self.canonicalSection(sec)   // nil ⇒ unrecognized cruft → NULL (relearned later)
                if canon != sec { ok = ok && run("UPDATE sighting SET section=? WHERE section=?", [canon, sec]) }
            }
            for r in panes {
                guard let app = r["app"] as? String, let role = r["role"] as? String, let axis = r["axis"] as? String,
                      let canon = Self.canonicalSection(role), canon != role else { continue }
                ok = ok && run("""
                    INSERT INTO scroll_pane(app, role, axis, scrollable, px_per_tick, updated) VALUES(?,?,?,?,?,?)
                    ON CONFLICT(app, role, axis) DO UPDATE SET
                        scrollable=MAX(scrollable, excluded.scrollable),
                        px_per_tick=COALESCE(px_per_tick, excluded.px_per_tick), updated=excluded.updated
                    """, [app, canon, axis, r["scrollable"] as? Int ?? 1, r["px_per_tick"], now])
                ok = ok && run("DELETE FROM scroll_pane WHERE app=? AND role=? AND axis=?", [app, role, axis])
            }
            // experience: one verb per phrasing — dedupe to the most recent row per token-set, reindex.
            ok = ok && run("DROP INDEX IF EXISTS experience_key", [])
            ok = ok && run("DELETE FROM experience WHERE id NOT IN (SELECT MAX(id) FROM experience GROUP BY tokens)", [])
            ok = ok && run("CREATE UNIQUE INDEX IF NOT EXISTS experience_key ON experience(tokens)", [])
            ok = ok && run("PRAGMA user_version=4", [])
            return ok
        }
    }

    // MARK: tokens (shared tokenizer — goal-content words, filler stripped)

    public static func tokens(_ s: String) -> [String] {
        let raw = s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return raw.filter { $0.count >= 2 && !Route.stopwords.contains($0) }
    }

    /// Core of an element LABEL for sighting identity: leading ≤2-char OCR junk stripped, alnum only —
    /// "z Simone" ≡ "Ze Simone" ≡ "simone" (mirrors the resolver's core-label tier).
    public static func core(_ label: String) -> String {
        var toks = label.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        while let f = toks.first, f.count <= 2, toks.count > 1 { toks.removeFirst() }
        return toks.joined()
    }

    // MARK: sightings (passive spatial memory — fed by every scene build)

    public func recordSightings(app: String, items: [(label: String, section: String?, x: Double, y: Double)]) {
        guard let store, !items.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        store.transaction { run in
            for it in items {
                let core = Self.core(it.label)
                guard core.count >= 3, core.count <= 40 else { continue }
                _ = run("""
                    INSERT INTO sighting(app, core, label, section, detail, x, y, seen, last)
                    VALUES(?,?,?,?,?,?,?,1,?)
                    ON CONFLICT(app, core) DO UPDATE SET
                        label=excluded.label, section=excluded.section, detail=excluded.detail,
                        x=excluded.x, y=excluded.y, seen=seen+1, last=excluded.last
                    """, [app, core, it.label, Self.canonicalSection(it.section), it.section, it.x, it.y, now])
            }
        }
    }

    public struct Sighting: Sendable {
        public let label: String
        public let section: String?
        public let detail: String?     // the full section string at last sighting (context, not identity)
        public let x: Double
        public let y: Double
        public let seen: Int
        public let last: Date
    }

    public func sighting(app: String, target: String) -> Sighting? {
        guard let store else { return nil }
        noteRead(.sighting, app: app)
        let core = Self.core(target)
        guard core.count >= 3 else { return nil }
        let rows = store.query("SELECT label, section, detail, x, y, seen, last FROM sighting WHERE app=? AND core=?", [app, core])
        guard let r = rows.first, let label = r["label"] as? String,
              let x = r["x"] as? Double, let y = r["y"] as? Double,
              let seen = r["seen"] as? Int, let last = r["last"] as? Double else { return nil }
        return Sighting(label: label, section: r["section"] as? String, detail: r["detail"] as? String,
                        x: x, y: y, seen: seen, last: Date(timeIntervalSince1970: last))
    }

    // MARK: scroll panes (probed once, remembered)

    public func recordPane(app: String, role: String, axis: String, scrollable: Bool, pxPerTick: Double?) {
        let role = Self.canonicalSection(role) ?? role
        store?.run("""
            INSERT INTO scroll_pane(app, role, axis, scrollable, px_per_tick, updated)
            VALUES(?,?,?,?,?,?)
            ON CONFLICT(app, role, axis) DO UPDATE SET
                scrollable=excluded.scrollable,
                px_per_tick=COALESCE(excluded.px_per_tick, px_per_tick),
                updated=excluded.updated
            """, [app, role, axis, scrollable ? 1 : 0, pxPerTick, Date().timeIntervalSince1970])
    }

    /// A GESTURE THIS PANE IGNORED — remembered so the next miss does not recommend it. Deliberately not
    /// `scrollable = 0`: a sideways no-op is ambiguous between "does not scroll" and "is at its end",
    /// and since nothing can re-infer a horizontal affordance, a recorded denial could only erase a
    /// truth a real scroll proved. What IS unambiguous is that this exact call moved nothing, which is
    /// all the guide needs to stop naming it (ticket 15).
    ///
    /// The directions ACCUMULATE, and that is load-bearing. Remembering only the latest one makes the
    /// guide alternate — measured live on Resolve's Deliver strip, where the section-level wheel no-ops
    /// BOTH ways (it never reaches the carousel sub-container, ticket 14): a single-slot memory answers
    /// the right no-op with "scroll left", the left no-op with "scroll right", and the agent ping-pongs
    /// between two dead calls. With both remembered the guide can say the axis is spent and stop.
    ///
    /// `scrollable` is never touched on an EXISTING row — a real scroll's truth outlives any later
    /// no-op. A pane whose first-ever record is a no-op inserts `scrollable = 0`, and that value is
    /// load-bearing, not a formality: `SceneBuilder` turns `paneScrollable(axis: "h") == true` straight
    /// into the map's `scrolls → (sideways) · learned` claim, whose only legitimate source is a
    /// horizontal scroll that MOVED. Seeding a fresh row with 1 would make one no-op advertise an
    /// affordance the pane has never shown — a lie in the very place this project refuses to guess. On
    /// the insert path there is no prior truth to erase, so 0 is simply what just happened.
    public func recordPaneNoop(app: String, role: String, axis: String, direction: String) {
        let role = Self.canonicalSection(role) ?? role
        let now = Date().timeIntervalSince1970
        // One idempotent upsert: append the direction unless the set already holds it (the LIKE runs on
        // the comma-fenced list, so "right" can never match inside another word).
        store?.run("""
            INSERT INTO scroll_pane(app, role, axis, scrollable, px_per_tick, updated, noop_dir, noop_at)
            VALUES(?,?,?,0,NULL,?,?,?)
            ON CONFLICT(app, role, axis) DO UPDATE SET
                noop_dir=CASE
                    WHEN noop_dir IS NULL OR noop_dir='' THEN excluded.noop_dir
                    WHEN ','||noop_dir||',' LIKE '%,'||excluded.noop_dir||',%' THEN noop_dir
                    ELSE noop_dir||','||excluded.noop_dir END,
                noop_at=excluded.noop_at, updated=excluded.updated
            """, [app, role, axis, now, direction, now])
    }

    /// The remembered no-op is retired only by the SAME verb succeeding — which is why nothing clears it
    /// implicitly. A pane can slide for one gesture and not another: the Deliver carousel is a
    /// sub-container, so the AX-aimed wheel moves it while `scroll(section:)` wheels the settings form
    /// behind it and no-ops (ticket 14). Letting the AX success clear the section-level no-op would
    /// re-enable exactly the recommendation ticket 15 measured as false.
    public func clearPaneNoop(app: String, role: String, axis: String) {
        let role = Self.canonicalSection(role) ?? role
        store?.run("UPDATE scroll_pane SET noop_dir=NULL, noop_at=NULL WHERE app=? AND role=? AND axis=?",
                   [app, role, axis])
    }

    /// Every direction a scroll of this pane has already been PROVEN not to move. Canonicalizes the role
    /// exactly as the write does, so a caller holding the map's volatile name ("content (Render
    /// Settings)") finds the row written under "content".
    public func paneNoopDirections(app: String, role: String, axis: String) -> [String] {
        guard let store else { return [] }
        noteRead(.scrollPane, app: app)
        let role = Self.canonicalSection(role) ?? role
        let rows = store.query("SELECT noop_dir FROM scroll_pane WHERE app=? AND role=? AND axis=?", [app, role, axis])
        guard let d = rows.first?["noop_dir"] as? String, !d.isEmpty else { return [] }
        return d.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    /// A px-per-tick HINT from a user gesture — noisier than the engine's NCC-measured calibration
    /// (trackpads quantize the line-delta field coarsely), so it only fills a MISSING value and never
    /// overwrites one: the existing value wins the COALESCE, the exact opposite of `recordPane`. Its
    /// job is the cold start — a pane the engine never scrolled gets a usable first-jump estimate from
    /// the user having scrolled it, and the consumer's 0.8× undershoot + [1,6] clamp absorb the noise.
    public func recordPaneTickHint(app: String, role: String, axis: String = "v", pxPerTick: Double) {
        let role = Self.canonicalSection(role) ?? role
        store?.run("""
            INSERT INTO scroll_pane(app, role, axis, scrollable, px_per_tick, updated)
            VALUES(?,?,?,1,?,?)
            ON CONFLICT(app, role, axis) DO UPDATE SET
                scrollable=1,
                px_per_tick=COALESCE(px_per_tick, excluded.px_per_tick),
                updated=excluded.updated
            """, [app, role, axis, pxPerTick, Date().timeIntervalSince1970])
    }

    public func panePxPerTick(app: String, role: String, axis: String = "v") -> Double? {
        guard let store else { return nil }
        noteRead(.scrollPane, app: app)
        let rows = store.query("SELECT px_per_tick FROM scroll_pane WHERE app=? AND role=? AND axis=?", [app, role, axis])
        return rows.first?["px_per_tick"] as? Double
    }

    public func rowPitch(app: String, family: String) -> Double? {
        guard let store else { return nil }
        noteRead(.sectionList, app: app)
        let rows = store.query("SELECT row_pitch FROM section_list WHERE app=? AND family=?", [app, family])
        return rows.first?["row_pitch"] as? Double
    }

    public func paneScrollable(app: String, role: String, axis: String = "v") -> Bool? {
        guard let store else { return nil }
        noteRead(.scrollPane, app: app)
        let rows = store.query("SELECT scrollable FROM scroll_pane WHERE app=? AND role=? AND axis=?", [app, role, axis])
        return (rows.first?["scrollable"] as? Int).map { $0 == 1 }
    }

    // MARK: wheel polarity (which sign scrolls a view UP — measured, never assumed; see WheelPolarity)

    /// Remember the measured wheel sign for one app AND for the machine (`app = "*"`): natural
    /// scrolling is a system setting, so the first app to measure it spares every other app the
    /// wrong-way burst. An app that inverts the wheel internally keeps its own row, which WINS over
    /// the machine's on read — that is why both rows exist.
    ///
    /// The machine row is therefore a HINT for apps nothing has measured yet, not a verdict: an app that
    /// inverts internally overwrites it on the way past. That costs the next never-measured app one
    /// wrong-way burst, which it then measures and corrects — the same self-healing every other case
    /// relies on, and the reason no measurement is ever trusted over the pixels.
    public func recordWheelPolarity(app: String, axis: String, upSign: Int) {
        let now = Date().timeIntervalSince1970
        for key in [app, Self.anyApp] {
            store?.run("""
                INSERT INTO wheel_polarity(app, axis, up_sign, updated) VALUES(?,?,?,?)
                ON CONFLICT(app, axis) DO UPDATE SET up_sign=excluded.up_sign, updated=excluded.updated
                """, [key, axis, upSign, now])
        }
    }

    /// Remember that this app's direction could NOT be read, so the one-time calibration is not paid
    /// again here (`up_sign = 0` — asked, unanswerable). It is an APP row only: the question is about the
    /// machine, and another app may still answer it, at which point the machine row starts answering for
    /// everyone. Without this marker an unreadable pane pays a nudge and a scene build on every scroll,
    /// forever, for an answer it will never give.
    public func recordWheelPolarityUnreadable(app: String, axis: String) {
        store?.run("""
            INSERT INTO wheel_polarity(app, axis, up_sign, updated) VALUES(?,?,0,?)
            ON CONFLICT(app, axis) DO NOTHING
            """, [app, axis, Date().timeIntervalSince1970])
    }

    /// The app's own measured sign, else the machine's, else nil (nothing measured yet). A zero is the
    /// "asked, unanswerable" marker, never a sign — it must not shadow the machine's real answer.
    public func wheelPolarity(app: String, axis: String, includingFallback: Bool = true) -> Int? {
        guard let store else { return nil }
        noteRead(.wheelPolarity, app: app)
        let rows = store.query(
            "SELECT app, up_sign FROM wheel_polarity WHERE axis=? AND app IN (?,?)", [axis, app, Self.anyApp])
        func sign(_ key: String) -> Int? {
            guard let v = rows.first(where: { ($0["app"] as? String) == key })?["up_sign"] as? Int,
                  v != 0 else { return nil }
            return v
        }
        return sign(app) ?? (includingFallback ? sign(Self.anyApp) : nil)
    }

    /// Has the wheel's direction been ASKED here — answered, or answered "unanswerable"? What stops the
    /// calibration from repeating; `wheelPolarity` is what decides which way to push.
    public func wheelPolarityAsked(app: String, axis: String) -> Bool {
        guard let store else { return false }
        noteRead(.wheelPolarity, app: app)
        // Another app's sign is a starting hint, not proof that this app honors it. Live TextEdit
        // inherited Resolve's +1 and skipped calibration, making a sweep run bottom→top.
        return !store.query("SELECT 1 FROM wheel_polarity WHERE axis=? AND app=?",
                            [axis, app]).isEmpty
    }

    /// The `app` key standing for "this machine, whatever the app".
    static let anyApp = "*"

    // MARK: sibling lists (ORDER is what survives scrolling; y does not)

    /// Merge one frame's visible member sequence into the remembered global order. Pure midpoint
    /// stitching: known members keep their ranks unless the CURRENT frame contradicts them (live order
    /// wins — Slack DM lists reorder by activity); unknown members interpolate between their ranked
    /// neighbors. Frames overlap while scrolling, so sub-sequences stitch into one order without ever
    /// seeing the whole list at once.
    public static func stitch(existing: [String: Double], visible: [String]) -> [String: Double] {
        var out = existing
        var prev: Double = out.values.isEmpty ? 0 : 0   // running lower bound for the walk
        // Establish the increasing anchor chain: a known rank that would INVERT the frame's order is
        // reassigned (treated as unknown), because the frame is the truth of the moment.
        var pending: [String] = []
        func flushPending(upTo next: Double?) {
            guard !pending.isEmpty else { return }
            let hi = next ?? (prev + Double(pending.count) + 1)
            let step = (hi - prev) / Double(pending.count + 1)
            for (i, core) in pending.enumerated() { out[core] = prev + step * Double(i + 1) }
            pending.removeAll()
        }
        for core in visible {
            if let r = out[core], r > prev {
                flushPending(upTo: r)
                prev = r
            } else {
                pending.append(core)
            }
        }
        flushPending(upTo: nil)
        // Strict monotonicity across THIS frame's members: tied ranks undercount rows-away in
        // memberSeed's ordinal counting (adversarial review) — nudge ties apart in frame order.
        var floor = -Double.infinity
        for core in visible {
            if let r = out[core] {
                if r <= floor { out[core] = floor + 0.0001 }
                floor = out[core]!
            }
        }
        return out
    }

    public func recordMembers(app: String, family: String, members: [(core: String, label: String)], rowPitch: Double?) {
        guard let store, members.count >= 2 else { return }
        let now = Date().timeIntervalSince1970
        let rows = store.query("SELECT core, rank FROM section_member WHERE app=? AND family=?", [app, family])
        var existing: [String: Double] = [:]
        for r in rows { if let c = r["core"] as? String, let k = r["rank"] as? Double { existing[c] = k } }
        let ranks = Self.stitch(existing: existing, visible: members.map(\.core))
        store.transaction { run in
            for m in members {
                guard let rank = ranks[m.core] else { continue }
                _ = run("""
                    INSERT INTO section_member(app, family, core, label, rank, seen, last)
                    VALUES(?,?,?,?,?,1,?)
                    ON CONFLICT(app, family, core) DO UPDATE SET
                        label=excluded.label, rank=excluded.rank, seen=seen+1, last=excluded.last
                    """, [app, family, m.core, m.label, rank, now])
            }
            if let rowPitch {
                _ = run("""
                    INSERT INTO section_list(app, family, row_pitch, updated) VALUES(?,?,?,?)
                    ON CONFLICT(app, family) DO UPDATE SET row_pitch=excluded.row_pitch, updated=excluded.updated
                    """, [app, family, rowPitch, now])
            }
        }
    }

    public struct MemberSeed: Sendable {
        public let direction: Int      // +1 target is BELOW the visible anchor, −1 above
        public let rowsAway: Int
        public let anchorLabel: String
        public let family: String
    }

    /// Scroll seed from the sibling ledger: where does `target` sit relative to what is VISIBLE now?
    public func memberSeed(app: String, target: String, visibleCores: Set<String>) -> MemberSeed? {
        guard let store else { return nil }
        noteRead(.sectionMember, app: app)
        let core = Self.core(target)
        guard core.count >= 3 else { return nil }
        let rows = store.query("SELECT family, rank FROM section_member WHERE app=? AND core=?", [app, core])
        guard let r = rows.first, let family = r["family"] as? String, let targetRank = r["rank"] as? Double else { return nil }
        let members = store.query("SELECT core, label, rank FROM section_member WHERE app=? AND family=?", [app, family])
        var best: (dist: Double, rank: Double, label: String)?
        var rankedBelow = 0.0
        for m in members {
            guard let c = m["core"] as? String, let k = m["rank"] as? Double, let l = m["label"] as? String else { continue }
            if visibleCores.contains(c) {
                let d = abs(k - targetRank)
                if best == nil || d < best!.dist { best = (d, k, l) }
            }
            if (k - targetRank).magnitude > 0 { rankedBelow += 0 }   // (placeholder no-op for clarity)
        }
        guard let b = best, b.dist > 0 else { return nil }
        // rowsAway from RANK ORDINALS, not float distance: count members strictly between them.
        let between = members.compactMap { $0["rank"] as? Double }
            .filter { (min(b.rank, targetRank) < $0) && ($0 < max(b.rank, targetRank)) }.count
        return MemberSeed(direction: targetRank > b.rank ? 1 : -1, rowsAway: between + 1,
                          anchorLabel: b.label, family: family)
    }

    // MARK: interactions (the ambient ledger — user scrolls etc.)

    public func recordInteraction(app: String, kind: String, section: String?, detail: String?) {
        store?.run("INSERT INTO interaction(ts, app, kind, section, detail) VALUES(?,?,?,?,?)",
                   [Date().timeIntervalSince1970, app, kind, section, detail])
        // keep it a ledger, not a landfill (20k rows ≈ days of heavy use, well under 2MB — enough
        // that the activity timeline can look back meaningfully)
        store?.run("DELETE FROM interaction WHERE id NOT IN (SELECT id FROM interaction ORDER BY ts DESC LIMIT 20000)")
    }

    /// The AGENT's successful tool acts, into the SAME ledger the watcher writes — one event spine,
    /// two actors (the symbolic-seeing design's requirement: user and agent episodes distinguishable
    /// but queryable together). Only labels/verbs are stored — never message content, never typed text.
    public func recordAgentAction(app: String, tool: String, target: String?, verb: String?) {
        var detail: [String: String] = [:]
        if let target, !target.isEmpty { detail["label"] = target }
        if let verb, !verb.isEmpty { detail["verb"] = verb }
        let json = (try? JSONSerialization.data(withJSONObject: detail)).flatMap { String(data: $0, encoding: .utf8) }
        store?.run("INSERT INTO interaction(ts, app, kind, section, detail, actor) VALUES(?,?,?,?,?,?)",
                   [Date().timeIntervalSince1970, app, tool, nil, json, "agent"])
    }

    /// Typed read of the spine for the timeline (oldest first). `sinceHours` bounds the scan.
    public func activityEvents(sinceHours: Double) -> [ActivityEvent] {
        guard let store else { return [] }
        noteRead(.interaction, app: nil)
        let cutoff = Date().timeIntervalSince1970 - sinceHours * 3600
        let rows = store.query(
            "SELECT ts, app, kind, section, detail, actor FROM interaction WHERE ts >= ? ORDER BY ts ASC",
            [cutoff])
        return rows.compactMap { r in
            guard let ts = r["ts"] as? Double, let app = r["app"] as? String, let kind = r["kind"] as? String
            else { return nil }
            var label: String?, appName: String?, verb: String?
            if let d = r["detail"] as? String, let data = d.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] {
                label = obj["label"]; appName = obj["app"]; verb = obj["verb"]
            }
            return ActivityEvent(ts: Date(timeIntervalSince1970: ts),
                                 actor: (r["actor"] as? String) ?? "user",
                                 app: app,
                                 appName: appName ?? app.split(separator: ".").last.map(String.init) ?? app,
                                 kind: kind, section: r["section"] as? String, label: label, verb: verb)
        }
    }

    /// Phase 2: the behavior timeline lives HERE (kind click/rightclick/focus/hover join the scroll
    /// interactions in one queryable ledger). BehaviorStore keeps dual-writing its ndjson as the
    /// shareable/backup copy; reads go SQLite-first.
    public func recordBehavior(_ ev: BehaviorEvent) {
        var detail: [String: String] = ["app": ev.app]
        if let l = ev.label { detail["label"] = l }
        if let p = ev.pos, p.count == 2 { detail["pos"] = "\(p[0]),\(p[1])" }
        let json = (try? JSONSerialization.data(withJSONObject: detail)).flatMap { String(data: $0, encoding: .utf8) }
        store?.run("INSERT INTO interaction(ts, app, kind, section, detail) VALUES(?,?,?,?,?)",
                   [ev.ts.timeIntervalSince1970, ev.bundleID, ev.kind, nil, json])
    }

    /// The recent interaction timeline as LLM-ready lines (newest last). Includes scrolls.
    public func recentTimeline(limit: Int) -> [String] {
        guard let store else { return [] }
        noteRead(.interaction, app: nil)
        let rows = store.query("SELECT ts, app, kind, section, detail FROM interaction ORDER BY ts DESC LIMIT ?", [limit])
        let fmt = ISO8601DateFormatter()
        return rows.reversed().compactMap { r in
            guard let ts = r["ts"] as? Double, let app = r["app"] as? String, let kind = r["kind"] as? String else { return nil }
            let t = fmt.string(from: Date(timeIntervalSince1970: ts))
            var name = app, label: String?
            if let d = r["detail"] as? String, let data = d.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] {
                name = obj["app"] ?? app
                label = obj["label"]
            }
            switch kind {
            case "focus": return "\(t)  ▸ focus \(name)"
            case "scroll":
                return "\(t)  ↕ scroll \((r["section"] as? String).map { "in \($0) " } ?? "")(\(name))"
            default: return "\(t)  • \(kind) \u{201C}\(label ?? "?")\u{201D} in \(name)"
            }
        }
    }

    /// Everything the memory holds, as one JSON blob for the `locator memory` visualizer (bounded).
    public func snapshotJSON() -> String {
        guard let store else { return "{}" }
        let out: [String: Any] = [
            "experience": store.query("SELECT phrase, tool, args, ok, fail, last FROM experience ORDER BY last DESC LIMIT 300"),
            "sightings": store.query("SELECT app, label, section, detail, x, y, seen, last FROM sighting ORDER BY seen DESC LIMIT 1500"),
            "members": store.query("SELECT app, family, label, rank, seen FROM section_member ORDER BY app, family, rank LIMIT 1000"),
            "lists": store.query("SELECT app, family, row_pitch FROM section_list"),
            "panes": store.query("SELECT app, role, axis, scrollable, px_per_tick FROM scroll_pane"),
            "interactions": store.query("SELECT ts, app, kind, section, detail FROM interaction ORDER BY ts DESC LIMIT 40"),
            // What each memory is WORTH: consultations, and the subset that changed an outcome. Reading
            // this is not itself counted (see `noteRead`).
            "readHits": store.query("SELECT store, app, consulted, useful, last FROM read_hit ORDER BY consulted DESC LIMIT 200"),
        ]
        return (try? JSONSerialization.data(withJSONObject: out)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    // MARK: experience (intent → verb; the learned dispatch + hint source)

    /// Verbs that are never an EXPERIENCE: planning and status reads describe the task, they do not do it,
    /// and replaying `plan_task("apply a filter, then export…")` from memory does nothing for the user.
    public static let nonExperienceTools: Set<String> = ["plan_task", "check_goal", "task_status", "describe_scene",
                                                         "describe_section", "list_apps", "recent_behavior"]

    public func recordExperience(app: String?, phrase: String, tool: String, argsJSON: String, success: Bool) {
        guard let store else { return }
        let tokenList = Self.tokens(phrase)
        let toks = tokenList.joined(separator: " ")
        // HYGIENE (2026-09-06): the ledger held "i i fucking said focus it not execute" as a PROVEN
        // run_menu experience. A phrase must carry at least two content tokens (one word is not an
        // intent the gate can judge) and the verb must be one that does something.
        guard tokenList.count >= 2, !Self.nonExperienceTools.contains(tool) else { return }
        let now = Date().timeIntervalSince1970
        // ONE verb per phrasing (unique on tokens): same verb recurs → accumulate ok/fail; a DIFFERENT
        // verb now satisfies the phrasing → replace it and reset the counts. SQLite evaluates every SET
        // right-hand side against the PRE-update row, so reading `tool` before overwriting it is safe.
        store.run("""
            INSERT INTO experience(app, phrase, tokens, tool, args, ok, fail, last) VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(tokens) DO UPDATE SET
                ok   = CASE WHEN tool=excluded.tool THEN ok+excluded.ok     ELSE excluded.ok   END,
                fail = CASE WHEN tool=excluded.tool THEN fail+excluded.fail ELSE excluded.fail END,
                phrase=excluded.phrase, tool=excluded.tool, args=excluded.args, last=excluded.last
            """, [app, phrase, toks, tool, argsJSON, success ? 1 : 0, success ? 0 : 1, now])
        // LRU cap — memories, not a log.
        store.run("DELETE FROM experience WHERE id NOT IN (SELECT id FROM experience ORDER BY last DESC LIMIT 300)")
    }

    // MARK: the transcript ledger (one row per agent turn)

    public struct TurnTool: Codable, Sendable, Equatable {
        public let tool: String
        public let args: [String: String]      // redacted: typed text and message bodies never land here
        public let outcome: String             // first line of the tool result, ≤ 80 chars
        public init(tool: String, args: [String: Any], outcome: String) {
            self.tool = tool
            self.args = TurnTool.redact(args)
            self.outcome = String(outcome.split(separator: "\n").first.map(String.init) ?? outcome).prefix(80).description
        }
        /// What must never be remembered: the text the user typed into an app, a message body, a query.
        static let redactedKeys: Set<String> = ["text", "message", "body", "query", "password", "token"]
        static func redact(_ args: [String: Any]) -> [String: String] {
            var out: [String: String] = [:]
            for (k, v) in args {
                if redactedKeys.contains(k.lowercased()) { out[k] = "«redacted»"; continue }
                out[k] = String(describing: v).prefix(80).description
            }
            return out
        }
    }

    public struct Turn: Sendable, Equatable {
        public let ts: Date
        public let session: String
        public let app: String?
        public let phrase: String
        public let tools: [TurnTool]
        public let answer: String?
        public let ok: Bool
        /// Model rounds this turn cost. `nil` = UNKNOWN (no loop of ours counted it — an MCP-driven
        /// turn, or a row written before the column existed); `0` = the model was never asked.
        public let rounds: Int?
        /// Served from memory with no model round (⚡) — the no-model share's numerator.
        public let imitated: Bool
    }

    /// Record one finished agent turn. `ok` is the frontend's verdict (no refusal, no miss on the way);
    /// the answer is kept to 300 chars — orientation for "last time", not a transcript of prose.
    ///
    /// `rounds` is the MODEL ROUND COUNT — how many times the model was asked inside this turn — and it
    /// is the harness headline (rounds per task, and the no-model share). It defaults to `nil` =
    /// UNKNOWN on purpose: a caller with no loop to count must never book a turn as `0`, because `0`
    /// means "the model was never asked" and is the no-model numerator. An MCP-driven turn (Claude
    /// Code / Claude Desktop) has no user phrase and no round count of ours, so it records `unknown`.
    /// `imitated` marks the ⚡ zero-model replay, whose round count is a real 0.
    public func recordTurn(session: String, app: String?, phrase: String, tools: [TurnTool], answer: String?, ok: Bool,
                           rounds: Int? = nil, imitated: Bool = false) {
        guard let store else { return }
        let toolsJSON = (try? JSONEncoder().encode(tools)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        store.run("INSERT INTO turn(ts, session, app, phrase, tools, answer, ok, rounds, imitated) VALUES(?,?,?,?,?,?,?,?,?)",
                  [Date().timeIntervalSince1970, session, app, String(phrase.prefix(300)), toolsJSON,
                   answer.map { String($0.prefix(300)) }, ok ? 1 : 0, rounds, imitated ? 1 : 0])
        store.run("DELETE FROM turn WHERE id NOT IN (SELECT id FROM turn ORDER BY ts DESC LIMIT 3000)")
    }

    /// The most recent turns, newest first — for the same app when `app` is given (bundle id or name,
    /// matched loosely), else across apps. Counted as a consultation of the experience store.
    public func recentTurns(app: String? = nil, limit: Int = 10, okOnly: Bool = false) -> [Turn] {
        guard let store else { return [] }
        noteRead(.experience, app: app)
        var sql = "SELECT ts, session, app, phrase, tools, answer, ok, rounds, imitated FROM turn"
        var args: [Any?] = []
        var conds: [String] = []
        if let app, !app.isEmpty { conds.append("lower(app) LIKE ?"); args.append("%" + app.lowercased() + "%") }
        if okOnly { conds.append("ok = 1") }
        if !conds.isEmpty { sql += " WHERE " + conds.joined(separator: " AND ") }
        sql += " ORDER BY ts DESC LIMIT ?"; args.append(limit)
        return store.query(sql, args).compactMap { r in
            guard let ts = r["ts"] as? Double, let session = r["session"] as? String, let phrase = r["phrase"] as? String,
                  let toolsJSON = r["tools"] as? String, let ok = r["ok"] as? Int else { return nil }
            let tools = (try? JSONDecoder().decode([TurnTool].self, from: Data(toolsJSON.utf8))) ?? []
            return Turn(ts: Date(timeIntervalSince1970: ts), session: session, app: r["app"] as? String,
                        phrase: phrase, tools: tools, answer: r["answer"] as? String, ok: ok == 1,
                        rounds: r["rounds"] as? Int, imitated: (r["imitated"] as? Int ?? 0) == 1)
        }
    }

    /// Every ACTING tool call's outcome word, into the interaction ledger (kind "outcome", section = the
    /// outcome word, detail = tool + target). Until 2026-09-06 only SUCCESSFUL steps were ledgered, so
    /// an honest_miss left no trace and "the agent can't find X in Y" was unmeasurable.
    public func recordAgentOutcome(app: String, tool: String, kind: String, target: String?) {
        var detail: [String: String] = ["tool": tool]
        if let target, !target.isEmpty { detail["target"] = String(target.prefix(80)) }
        let json = (try? JSONSerialization.data(withJSONObject: detail, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) }
        store?.run("INSERT INTO interaction(ts, app, kind, section, detail, actor) VALUES(?,?,?,?,?,?)",
                   [Date().timeIntervalSince1970, app, "outcome", kind, json, "agent"])
    }

    public struct Experience: Sendable {
        public let phrase: String
        public let tokens: [String]
        public let tool: String
        public let argsJSON: String
        public let ok: Int
        public let fail: Int
    }

    public func recentExperiences(limit: Int = 50) -> [Experience] {
        guard let store else { return [] }
        noteRead(.experience, app: nil)
        return store.query("SELECT phrase, tokens, tool, args, ok, fail FROM experience ORDER BY last DESC LIMIT ?", [limit])
            .compactMap { r in
                guard let phrase = r["phrase"] as? String, let toks = r["tokens"] as? String,
                      let tool = r["tool"] as? String, let args = r["args"] as? String,
                      let ok = r["ok"] as? Int, let fail = r["fail"] as? Int else { return nil }
                return Experience(phrase: phrase, tokens: toks.split(separator: " ").map(String.init),
                                  tool: tool, argsJSON: args, ok: ok, fail: fail)
            }
    }

    /// The IMITATED CACHE HIT lives in `Recall` (Recall.swift) — input matches a remembered successful
    /// phrasing exactly (by content tokens), or differs by exactly ONE token that was an ARG VALUE, and
    /// every value recall substitutes for itself must name a concrete known entity. send_message is
    /// excluded (its text is redacted, re-execution would send the wrong thing).
    /// Cross-graph context for imitation: which app graphs the memory holds, and which entity
    /// cores each has SIGHTED — so a fast-path learned in one app can hop to another, but only
    /// when the target graph actually contains the entity (evidence, not hope).
    public struct GraphContext: Sendable {
        public let sighted: [String: Set<String>]   // lowercased bundle id → sighted entity cores
        public init(sighted: [String: Set<String>] = [:]) { self.sighted = sighted }
        /// Bundles a spoken token names ("slack" → com.tinyspeck.slackmacgap) — component match.
        public func bundles(matching token: String) -> [String] {
            guard token.count >= 3 else { return [] }
            return sighted.keys.filter { $0.split(separator: ".").contains { $0.contains(token) } }
        }
    }

    /// The sighted-entity map for cross-graph imitation, straight from the sighting table.
    public func graphContext() -> GraphContext {
        guard let store else { return GraphContext() }
        // The whole sighting map, for cross-graph imitation: not scoped to one app, so it books to the
        // machine row. Whether the hop it enables was DECISIVE is decided inside `imitate`, which is a
        // pure matcher and reports no such thing — so this store earns its `useful` credit where a
        // sighting demonstrably steered an outcome (reach's ranking), never here.
        noteRead(.sighting, app: nil)
        var sighted: [String: Set<String>] = [:]
        for r in store.query("SELECT app, core FROM sighting") {
            guard let a = r["app"] as? String, let c = r["core"] as? String else { continue }
            sighted[a.lowercased(), default: []].insert(c)
        }
        return GraphContext(sighted: sighted)
    }

    /// The FIRE case of the recall seam, kept as the name the frontends and the older tests already
    /// speak. All the policy — matching, substitution, the entity-evidence gate — lives in `Recall`;
    /// this is the thin adapter for callers that only care whether a replay is on the table, and an
    /// abstention (with its reason) collapses back to `nil` here.
    public static func imitate(input: String, from memories: [Experience],
                               graph: GraphContext = GraphContext()) -> (tool: String, argsJSON: String, note: String)? {
        guard case .fire(let f) = Recall.decide(input: input, in: Recall.World(memories: memories, graph: graph))
        else { return nil }
        return (f.tool, f.argsJSON, f.note)
    }

    /// The LITE-RAG hint: the best partial match worth whispering to the model.
    public static func hint(input: String, from memories: [Experience]) -> String? {
        let inToks = Set(tokens(input))
        guard !inToks.isEmpty else { return nil }
        var best: (score: Double, m: Experience)?
        for m in memories where m.ok > 0 && !m.tokens.isEmpty {
            // COVERAGE of the remembered phrase (not of the input): a chatty phrasing ("can you make a
            // huddle happen with simone please") still fully covers the memory {huddle, simone}.
            let hits = Set(m.tokens).intersection(inToks).count
            let coverage = Double(hits) / Double(m.tokens.count)
            if hits >= 2, coverage >= 0.75, coverage > (best?.score ?? 0) { best = (coverage, m) }
        }
        guard let b = best else { return nil }
        return "[memory: \"\(b.m.phrase)\" was solved by \(b.m.tool)(\(b.m.argsJSON)) — worked \(b.m.ok)×]"
    }
}
