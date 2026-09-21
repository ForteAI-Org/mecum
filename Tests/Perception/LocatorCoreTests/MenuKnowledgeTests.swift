import XCTest
import Foundation
@testable import LocatorCore

final class MenuKnowledgeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let t1 = Date(timeIntervalSince1970: 1_700_000_100)

    private func cmd(_ path: [String], id: String? = nil, submenu: Bool = false, now: Date) -> MenuCommand {
        MenuCommand(path: path, topLevelTitle: path.first ?? "", identifier: id, hasSubmenu: submenu,
                    firstSeen: now, lastSeen: now)
    }

    func testMatchScoreDigitAndPhraseSensitive() {
        let quantize = cmd(["Edit", "Quantize"], now: t0)
        XCTAssertEqual(quantize.matchScore(query: "Quantize"), 3)              // exact
        XCTAssertEqual(cmd(["Edit", "Quantize to Grid…"], now: t0).matchScore(query: "Quantize"), 2)  // token subset
        XCTAssertEqual(quantize.matchScore(query: "Quantize to Grid…"), 2)     // subset the other way
        XCTAssertEqual(cmd(["Setup", "Playback Engine…"], now: t0).matchScore(query: "Quantize"), 0)  // disjoint
    }

    func testObserveMenusMergesByKeyAndPreservesFirstSeen() {
        var app = AppKnowledge(bundleID: "com.x")
        app.observeMenus([cmd(["Setup", "Playback Engine…"], id: "pe", now: t0), cmd(["File", "Open…"], now: t0)], now: t0)
        XCTAssertEqual(app.menuCommands.count, 2)
        // Re-enumerate: the identified command refreshes (lastSeen) without duplicating; a new one appends.
        app.observeMenus([cmd(["Setup", "Playback Engine…"], id: "pe", now: t1), cmd(["Edit", "Undo"], now: t1)], now: t1)
        XCTAssertEqual(app.menuCommands.count, 3)
        let pe = app.menuCommands.first { $0.identifier == "pe" }!
        XCTAssertEqual(pe.firstSeen, t0)   // preserved
        XCTAssertEqual(pe.lastSeen, t1)    // refreshed
    }

    func testObserveMenusKeysOnPathNotSharedIdentifier() {
        // Pro Tools reuses one AX identifier across many items; distinct commands must NOT collapse.
        var app = AppKnowledge(bundleID: "com.x")
        app.observeMenus([
            cmd(["Setup", "Playback Engine…"], id: "shared", now: t0),
            cmd(["Track", "New…"], id: "shared", now: t0),
            cmd(["Event", "Quantize"], id: "shared", now: t0),
        ], now: t0)
        XCTAssertEqual(app.menuCommands.count, 3)   // keyed on path, not the recycled identifier
    }

    func testBestMenuCommandIsUniqueAccept() {
        var app = AppKnowledge(bundleID: "com.x")
        app.observeMenus([
            cmd(["Setup", "Playback Engine…"], now: t0),
            cmd(["File", "Open…"], now: t0),
        ], now: t0)
        XCTAssertEqual(app.bestMenuCommand(for: "Playback Engine")?.path, ["Setup", "Playback Engine…"])
        XCTAssertNil(app.bestMenuCommand(for: "nonexistent command"))  // below minScore → nil
        // Two EXACT-name commands in different menus are genuinely ambiguous — refuse to guess
        // (the old shallower-path tiebreak silently picked one; guessing is how Premiere broke).
        app.observeMenus([cmd(["Window", "Playback Engine Status", "Playback Engine"], now: t0)], now: t0)
        XCTAssertNil(app.bestMenuCommand(for: "Playback Engine"))
    }

    func testBestMenuCommandSkipsSubmenuParentsAndSiblingSwarms() {
        // The Premiere "export" incident: the KB held "File > Export" as a SUBMENU PARENT (exact-leaf
        // score 3 — outranked everything) plus eight children tying at 2. Pressing the parent just
        // flashed the File menu open while reporting success. Parents must never be returned, and a
        // swarm of same-score children must refuse (nil) rather than auto-pick "AAF…".
        var app = AppKnowledge(bundleID: "com.x")
        app.observeMenus([
            cmd(["File", "Export"], submenu: true, now: t0),
            cmd(["File", "Export", "AAF..."], now: t0),
            cmd(["File", "Export", "Media..."], now: t0),
            cmd(["File", "Export", "Markers..."], now: t0),
        ], now: t0)
        XCTAssertNil(app.bestMenuCommand(for: "export"))
        // A query that singles out ONE child still resolves — the gate kills guesses, not matches.
        XCTAssertEqual(app.bestMenuCommand(for: "export media")?.path, ["File", "Export", "Media..."])
    }

    func testDestructiveIsMultilingual() {
        // English-only let "Elimina"/"Invia" bypass the gate in an Italian UI (measured on Slack).
        XCTAssertTrue(ActionPolicy.isDestructive(label: "Delete message"))
        XCTAssertTrue(ActionPolicy.isDestructive(label: "Elimina messaggio…"))   // IT: delete
        XCTAssertTrue(ActionPolicy.isDestructive(label: "Elimina"))
        XCTAssertTrue(ActionPolicy.isDestructive(label: "Invia"))                 // IT: send
        XCTAssertTrue(ActionPolicy.isDestructive(label: "Rimuovi"))               // IT: remove
        XCTAssertTrue(ActionPolicy.isDestructive(label: "Esci"))                  // IT: quit
        XCTAssertFalse(ActionPolicy.isDestructive(label: "Rispondi nella conversazione"))  // reply — benign
        XCTAssertFalse(ActionPolicy.isDestructive(label: "Simone"))
    }

    func testAllowDestructiveDefaultsOff() {
        XCTAssertFalse(Allowlist().allowDestructive)                 // safe default even under allowAll
        XCTAssertTrue(Allowlist(allowDestructive: true).allowDestructive)
    }

    func testDestructiveDenylistIsWordBoundary() {
        XCTAssertTrue(DestructiveDenylist.matches("Bounce to Disk…"))
        XCTAssertTrue(DestructiveDenylist.matches("Save As…"))
        XCTAssertTrue(DestructiveDenylist.matches("AudioSuite"))
        XCTAssertTrue(DestructiveDenylist.matches("Delete Track"))
        XCTAssertFalse(DestructiveDenylist.matches("Saved Searches"))  // "saved" != "save" (word-boundary)
        XCTAssertFalse(DestructiveDenylist.matches("Playback Engine…"))
        XCTAssertFalse(DestructiveDenylist.matches("Zoom Toggle"))
    }

    func testAllowlistDefaultsToAllowAll() {
        // The frictionless default the user asked for: a fresh allowlist permits every app, observe + act.
        let a = Allowlist()
        XCTAssertTrue(a.allowAll)
        XCTAssertTrue(a.allows("com.anything.at.all"))
        XCTAssertTrue(a.allowsActive("com.anything.at.all"))
    }

    func testRestrictedModeIsPerAppOptIn() {
        // With allowAll off, observe and active are separate per-app opt-ins (observe ≠ act).
        var a = Allowlist(bundleIDs: ["com.avid.ProTools"], allowAll: false)
        XCTAssertTrue(a.allows("com.avid.ProTools"))
        XCTAssertFalse(a.allowsActive("com.avid.ProTools"))   // observe-allow does NOT grant active
        XCTAssertFalse(a.allows("com.other.app"))
        a.activeBundleIDs.insert("com.avid.ProTools")
        XCTAssertTrue(a.allowsActive("com.avid.ProTools"))
    }

    func testAllowlistDecodesOldJSONAsAllowAll() throws {
        let enc = DescriptorStore.makeEncoder(); let dec = DescriptorStore.makeDecoder()
        let a = Allowlist(bundleIDs: ["com.avid.ProTools"], activeBundleIDs: ["com.avid.ProTools"], allowAll: false)
        XCTAssertEqual(try dec.decode(Allowlist.self, from: try enc.encode(a)), a)   // round-trip incl. allowAll
        // Old JSON (no allowAll / no activeBundleIDs key) → adopts the allow-all default automatically.
        let old = try dec.decode(Allowlist.self, from: Data(#"{"bundleIDs":["com.x"]}"#.utf8))
        XCTAssertEqual(old.bundleIDs, ["com.x"]); XCTAssertTrue(old.activeBundleIDs.isEmpty)
        XCTAssertTrue(old.allowAll)
    }

    func testAppKnowledgeDecodesPreP3JSON() throws {
        // A pre-P3 per-app store (no menuCommands) must still decode.
        let json = #"{"bundleID":"com.x","windows":[]}"#
        let app = try DescriptorStore.makeDecoder().decode(AppKnowledge.self, from: Data(json.utf8))
        XCTAssertEqual(app.bundleID, "com.x")
        XCTAssertTrue(app.menuCommands.isEmpty)
    }
}
