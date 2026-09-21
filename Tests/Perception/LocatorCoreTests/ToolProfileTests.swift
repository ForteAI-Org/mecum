import XCTest

/// The lean profile's one safety property: it may only withhold a tool whose capability is still
/// reachable. This test is the coupling between ToolProfile.reachableViaCatalog and the catalog itself —
/// nothing in the type system enforces it, so a verb leaving the catalog has to fail HERE, loudly,
/// rather than becoming a silently unreachable tool in every lean session.
///
/// It reads the two sources as text because the engine target is an executable (not importable from
/// tests). Crude, deliberately: the alternative is no check at all.
final class ToolProfileTests: XCTestCase {
    private func read(_ rel: String) throws -> String {
        // This check reads the locator executable's source. LocatorCore is its
        // reusable library, while the executable remains in the sibling
        // forte_locator checkout.
        let mecumRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let locatorRoot = mecumRoot.deletingLastPathComponent().appendingPathComponent("forte_locator")
        return try String(contentsOf: locatorRoot.appendingPathComponent(rel), encoding: .utf8)
    }

    func testEveryWithheldAppVerbIsInTheCatalog() throws {
        let profile = try read("Sources/locator-mcp/ToolProfile.swift")
        let catalog = try read("Sources/locator-mcp/CapabilityCatalog.swift")
        // The declared list, sliced out of the source between the `reachableViaCatalog` braces.
        guard let start = profile.range(of: "reachableViaCatalog: Set<String> = ["),
              let end = profile.range(of: "]", range: start.upperBound..<profile.endIndex) else {
            return XCTFail("reachableViaCatalog literal not found — did the declaration change shape?")
        }
        let declared = profile[start.upperBound..<end.lowerBound]
            .split(whereSeparator: { ",\n \"".contains($0) })
            .map(String.init).filter { $0.contains("_") }
        XCTAssertFalse(declared.isEmpty, "parsed no verbs — the test's own slicing is broken")
        for verb in declared {
            XCTAssertTrue(catalog.contains("verb: \"\(verb)\""),
                          "'\(verb)' is withheld by the lean profile but is NOT in CapabilityCatalog — "
                          + "app_call cannot run it, so lean would silently remove the capability")
        }
    }

    /// The inverse trap: a tool the catalog does NOT carry must never appear in the withheld list. Named
    /// explicitly because these four (plus resolve_*/web_*) were the ones that looked droppable and are not.
    func testNonCatalogToolsAreNotWithheld() throws {
        let profile = try read("Sources/locator-mcp/ToolProfile.swift")
        guard let head = profile.range(of: "static var withheld") else { return XCTFail("no withheld") }
        let decls = String(profile[profile.startIndex..<head.lowerBound])
        for verb in ["premiere_status", "premiere_effects", "premiere_params", "ptsl_status",
                     "resolve_page", "resolve_render", "resolve_status", "web_click", "web_snapshot"] {
            XCTAssertFalse(decls.contains("\"\(verb)\""),
                           "'\(verb)' has no catalog entry — withholding it removes the capability")
        }
    }
}
