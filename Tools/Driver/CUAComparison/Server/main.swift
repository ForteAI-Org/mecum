import AppKit
import AutomationMCP
import AutomationRuntime
import Foundation
import LocalMCP
import PrivateSymbols

// mecum-mcp-stdio <knowledge directory>: one JSON-RPC message per line on stdin and stdout, answered by
// the same MCPRouter and AutomationTools the app's worker host uses. MECUM_BENCH_UNVALIDATED=1 is the
// Driver's research opt-in for a macOS build its ledger has not validated, as --allow-unvalidated-build.

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: mecum-mcp-stdio <knowledge directory>\n".utf8))
    exit(2)
}

// Driver ADR 0007: a caller-owned AppKit loop across asynchronous Seat work, as the mecum CLI does.
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
Task { @MainActor in
    FacilityGate.researchOptInForUnvalidatedBuilds = ProcessInfo.processInfo.environment["MECUM_BENCH_UNVALIDATED"] == "1"
    let knowledge = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let tools = AutomationTools(session: AutomationSession(knowledgeDirectory: knowledge))
    let router = MCPRouter(tools: AutomationTools.definitions) { name, arguments in
        try await tools.call(name, arguments)
    }
    do {
        for try await line in FileHandle.standardInput.bytes.lines {
            guard let request = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { continue }
            if let reply = await router.handle(request) {
                FileHandle.standardOutput.write(try JSONEncoder().encode(reply) + Data([10]))
            }
        }
    } catch {
        FileHandle.standardError.write(Data("mecum-mcp-stdio: \(error)\n".utf8))
    }
    // The client closed stdin: return the windows and release the Seat before exiting.
    await tools.session.close()
    exit(0)
}
application.run()
