//
//  ProviderWebSearchTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import ChatCore
import CLIProviders
import Foundation
import Testing

/// The command lines' own web search: off unless a turn allows it, and then only search and page reading.
@Suite("Web search on the command lines")
struct ProviderWebSearchTests {

    private func turn(
        _ provider     : ChatProvider,
        allowsWebSearch: Bool? = nil,
        isCompaction   : Bool  = false
    ) -> ProviderTurn {
        if let allowsWebSearch {
            return ProviderTurn(provider: provider, model: "m", sessionID: "s", prompt: "p", instructions: "i",
                                bridgeExecutable: "/b", connectionFile: "/c", workingDirectory: "/w",
                                effort: "high", isCompaction: isCompaction, allowsWebSearch: allowsWebSearch)
        }
        return ProviderTurn(provider: provider, model: "m", sessionID: "s", prompt: "p", instructions: "i",
                            bridgeExecutable: "/b", connectionFile: "/c", workingDirectory: "/w",
                            effort: "high", isCompaction: isCompaction)
    }

    /// The restricted arguments when web search is disabled, including the context budget.
    private static let claudeToday = [
        "-p", "--output-format", "stream-json", "--verbose", "--strict-mcp-config", "--mcp-config",
        #"{"mcpServers":{"mecum":{"args":["mcp-bridge","--connection","\/c"],"command":"\/b"}}}"#,
        "--tools", "", "--allowedTools", "mcp__mecum__*", "--permission-mode", "dontAsk", "--setting-sources", "",
        "--disable-slash-commands", "--no-chrome", "--append-system-prompt", "i", "--resume", "s",
        "--model", "m", "--effort", "high",
    ]

    private static let codexToday = [
        "exec", "--ignore-user-config", "--strict-config", "--json", "--skip-git-repo-check", "-C", "/w",
        "-s", "read-only", "-c", #"approval_policy="never""#,
        "-c", "features.shell_tool=false", "-c", "features.unified_exec=false",
        "-c", "features.apps=false", "-c", "features.plugins=false",
        "-c", "features.computer_use=false", "-c", "features.browser_use=false",
        "-c", "features.view_image=false", "-c", "features.image_generation=false",
        "-c", #"web_search="disabled""#, "-c", #"developer_instructions="i""#,
        "-c", #"mcp_servers.mecum={command="/b",args=["mcp-bridge","--connection","/c"],required=true,"#
            + #"tool_timeout_sec=120,default_tools_approval_mode="approve"}"#,
        "--model", "m", "-c", #"model_reasoning_effort="high""#,
        "-c", "model_auto_compact_token_limit=64000", "resume", "s", "-",
    ]

    @Test
    func withoutWebSearchTheArgumentsAreTodaysWordForWord() throws {
        #expect(try ProviderInvocation(turn(.claude)).arguments == Self.claudeToday)
        #expect(try ProviderInvocation(turn(.codex)).arguments == Self.codexToday)
        #expect(try ProviderInvocation(turn(.claude, allowsWebSearch: false)).arguments == Self.claudeToday)
        #expect(try ProviderInvocation(turn(.codex, allowsWebSearch: false)).arguments == Self.codexToday)
    }

    /// Only the two built-in web tools are switched on and allowed, beside Mecum's MCP tools.
    @Test
    func claudeWithWebSearchAddsOnlySearchAndFetch() throws {
        let arguments = try ProviderInvocation(turn(.claude, allowsWebSearch: true)).arguments
        var expected = Self.claudeToday
        expected[try #require(expected.firstIndex(of: "--tools")) + 1] = "WebSearch,WebFetch"
        expected[try #require(expected.firstIndex(of: "--allowedTools")) + 1] = "mcp__mecum__*,WebSearch,WebFetch"
        #expect(arguments == expected)
        #expect(arguments.filter { $0 == "--tools" || $0 == "--allowedTools" }.count == 2)
    }

    @Test
    func codexWithWebSearchGoesLive() throws {
        let arguments = try ProviderInvocation(turn(.codex, allowsWebSearch: true)).arguments
        let live = try #require(arguments.firstIndex(of: #"web_search="live""#))
        #expect(arguments[live - 1] == "-c")
        #expect(!arguments.contains(#"web_search="disabled""#))
        var expected = Self.codexToday
        expected[try #require(expected.firstIndex(of: #"web_search="disabled""#))] = #"web_search="live""#
        #expect(arguments == expected)
    }

    @Test
    func aCompactionTurnNeverSearches() throws {
        for provider in ChatProvider.allCases {
            let allowed = try ProviderInvocation(turn(provider, allowsWebSearch: true, isCompaction: true))
            let plain   = try ProviderInvocation(turn(provider, isCompaction: true))
            #expect(allowed.arguments == plain.arguments)
            #expect(!allowed.arguments.contains { $0.contains("WebSearch") || $0.contains(#"web_search="live""#) })
        }
    }

    // MARK: Decoding

    private func events(_ provider: ChatProvider, _ fixture: String) throws -> [ProviderEvent] {
        let url = try #require(Bundle.module.url(forResource: fixture, withExtension: "jsonl",
                                                 subdirectory: "Fixtures"))
        var decoder = ProviderEventDecoder(provider: provider)
        return try String(decoding: Data(contentsOf: url), as: UTF8.self)
            .split(separator: "\n")
            .flatMap { try decoder.decode(Data($0.utf8)) }
    }

    private func isWeb(_ event: ProviderEvent) -> Bool {
        if case .web = event { true } else { false }
    }

    /// The recorded Claude turn fetched a page and searched, both at once; each result names its call.
    @Test
    func claudesFetchAndSearchStartAndFinishPairedById() throws {
        let events = try events(.claude, "claude-web")
        let fetch  = "toolu_01YKrxBxrCbD3AAe8c4vDbRj"
        let search = "toolu_01CKgERwoDEwc6Dam17Q8cQ8"
        let query  = "latest stable Swift version release swift.org 2026"
        #expect(events.filter(isWeb) == [
            .web(id: fetch, kind: .fetch, detail: "https://www.swift.org/install/", phase: .started),
            .web(id: search, kind: .search, detail: query, phase: .started),
            .web(id: fetch, kind: .fetch, detail: "https://www.swift.org/install/", phase: .finished(failed: false)),
            .web(id: search, kind: .search, detail: query, phase: .finished(failed: false)),
        ])

        // What the turn said and cost reads as it did before web search.
        let said = events.filter { !isWeb($0) && $0 != .session("d850a995-c5ab-458e-9ccb-bf2c3a2ccb19") }
        #expect(said.first == .assistant("I'll check the official Swift site."))
        #expect(said.count == 4)
        if case .assistant(let answer) = said[1] { #expect(answer.contains("swift.org/blog/swift-6.4-released")) }
        else { Issue.record("The answer is missing: \(said)") }
        #expect(Array(said.suffix(1)) == [.completed])
        let started = try #require(events.firstIndex(of: said[0]))
        #expect(started < (try #require(events.firstIndex(where: isWeb))), "the note comes before the calls")
    }

    /// Codex names what it searched for only as the search finishes, so only its finish counts.
    @Test
    func codexsSearchStartsWithoutAQueryAndFinishesWithIt() throws {
        let id = "exec-779ca021-2628-4ac5-a30d-7ca87ee32d65"
        #expect(try events(.codex, "codex-web-config") == [
            .session("01a0d99c-cfca-7351-a7c1-7993edacf896"),
            .assistant("I\u{2019}ll check the official Swift release page for the latest stable version."),
            // Its start names no query and says `action.type == "other"`, so it adds nothing yet.
            .web(id: id, kind: .search, detail: "site:swift.org/download latest stable Swift release September 2026",
                 phase: .finished(failed: false)),
            .assistant("The latest stable version is **Swift 6.4.0**. "
                       + "Source: https://www.swift.org/blog/swift-6.4-released/"),
            .usage(ProviderUsage(tokens: ProviderUsage.Tokens(input: 36743, cacheReads: 18816, cacheWrites: 0,
                                                              output: 115, reasoning: 7), isSessionTotal: true)),
            .completed,
        ])
    }

    /// Recorded live with every flag Mecum passes: searches carry `action.type == "search"`, an
    /// address opens a page, and the steps inside that page (an empty query, a phrase looked
    /// for) are no search and no read of their own.
    @Test
    func codexsStepsInsideAPageAreNotSearches() throws {
        let finished = try events(.codex, "codex-web-actions").compactMap { event -> String? in
            guard case .web(_, let kind, let detail, .finished) = event else { return nil }
            return "\(kind == .search ? "search" : "fetch") \(detail ?? "")"
        }
        #expect(finished == [
            "search site:swift.org download latest stable Swift release September 2026",
            "search site:swift.org/install Swift 6.4.0 release latest stable ...",
            "fetch https://www.swift.org/install/",
        ])
    }

    /// A Codex query that is an address means it opened that page.
    @Test
    func aCodexQueryThatIsAnAddressIsAPageRead() throws {
        var codex = ProviderEventDecoder(provider: .codex)
        let page = "https://www.swift.org/install/"
        let line = #"{"type":"item.completed","item":{"id":"ws_1","type":"web_search","query":""#
            + page + #""}}"#
        #expect(try codex.decode(Data(line.utf8))
                == [.web(id: "ws_1", kind: .fetch, detail: page, phase: .finished(failed: false))])
    }

    /// A failed web result is marked failed, and a result for any other tool (Mecum's own) is not web activity.
    @Test
    func aFailedClaudeResultFailsAndOtherToolsResultsAreIgnored() throws {
        var claude = ProviderEventDecoder(provider: .claude)
        let call = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"WebSearch","#
            + #""input":{"query":"q"}},{"type":"tool_use","id":"t2","name":"mcp__mecum__observe","input":{}}]}}"#
        #expect(try claude.decode(Data(call.utf8)) == [.web(id: "t1", kind: .search, detail: "q", phase: .started)])
        let results = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"ok"},"#
            + #"{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"blocked"}]}}"#
        #expect(try claude.decode(Data(results.utf8))
                == [.web(id: "t1", kind: .search, detail: "q", phase: .finished(failed: true))])
        #expect(try claude.decode(Data(results.utf8)).isEmpty, "a result is paired once")
    }

    @Test
    func turnsWithoutTheWebHaveNoWebActivity() throws {
        for fixture in ["claude-turn1", "claude-compact-plain", "claude-compact-disabled"] {
            #expect(!(try events(.claude, fixture)).contains(where: isWeb))
        }
        for fixture in ["codex-turn1", "codex-compact", "codex-lowlimit"] {
            #expect(!(try events(.codex, fixture)).contains(where: isWeb))
        }
    }
}
