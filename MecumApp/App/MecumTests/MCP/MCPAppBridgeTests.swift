import Foundation
import LocalMCP
import Testing
@testable import Mecum

/// Exercises the bundled process, live loopback host and engine adapter using synthetic controls.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MCPAppBridgeTests {
    @Test func bundledBridgeUsesCurrentEngineAndRevocationEndsAnIdleClient() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("mcp-app-bridge-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/mecum-bridge")
        var closed = 0
        let desktop = SyntheticMCPDesktop()
        let model = MCPConnectionsModel(directory: root, executable: executable) { profile, activity in
            let session = ExternalMCPSession(profile: profile, session: desktop, activity: activity)
            return MCPHostSession(router: session.router) { await session.close(); closed += 1 }
        }
        await model.prepare()
        let profile = MCPClientProfile(name: "Synthetic transport")
        model.add(profile)
        await model.waitForIdle()
        model.setEnabled(true, for: profile.id)
        await model.waitForIdle()
        #expect(model.clients.first?.isListening == true)
        let process = Process()
        let output = Pipe()
        let ready = root.appendingPathComponent("ready")
        process.executableURL = URL(filePath: "/usr/bin/python3")
        process.arguments = ["-c", Self.client, executable.path, model.configuration(for: profile.id).connection.path,
                             try #require(desktop.id).uuidString, ready.path]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !FileManager.default.fileExists(atPath: ready.path), process.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: ready.path))
        #expect(desktop.selections == 1)
        model.revoke(profile.id)
        await model.waitForIdle()
        while process.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!process.isRunning)
        if !process.isRunning {
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(process.terminationStatus == 0, "Synthetic client failed: \(text)")
            #expect(text.contains("task_and_revocation_passed"))
        }
        #expect(closed == 1)
        #expect(desktop.id == nil)
        await model.shutdown()
    }

    private static let client = #"""
    import json, pathlib, select, subprocess, sys
    bridge, endpoint, session, ready = sys.argv[1:]
    child = subprocess.Popen([bridge, 'mcp-bridge', '--connection', endpoint],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    counter = 0
    def rpc(method, params):
        global counter
        counter += 1
        message = {'jsonrpc': '2.0', 'id': counter, 'method': method, 'params': params}
        child.stdin.write((json.dumps(message) + '\n').encode())
        child.stdin.flush()
        assert select.select([child.stdout], [], [], 5)[0], 'MCP response timeout'
        response = json.loads(child.stdout.readline())
        assert response['id'] == counter and 'error' not in response, response
        return response['result']
    def tool(name, args):
        result = rpc('tools/call', {'name': name, 'arguments': args})
        assert not result.get('isError'), result
        assert 'structuredContent' not in result, 'Do not duplicate current main tool output'
        return json.loads(result['content'][0]['text'])
    try:
        rpc('initialize', {'protocolVersion': '2025-11-25', 'capabilities': {},
                           'clientInfo': {'name': 'synthetic-client', 'version': '1'}})
        tools = rpc('tools/list', {})['tools']
        assert any(t['name'] == 'select' for t in tools)
        # G76 D1: memory_task, the task the agent declares, is the one memory tool an external client sees.
        assert any(t['name'] == 'memory_task' for t in tools)
        assert not any(t['name'].startswith(('browser_', 'watch_', 'task_'))
                       or (t['name'].startswith('memory_') and t['name'] != 'memory_task') for t in tools)
        tool('select', {'session': session, 'control': 'Mono', 'item': 'Stereo'})
        pathlib.Path(ready).write_text('ready')
        assert child.wait(timeout=10) == 1, 'Host revocation must disconnect the idle bridge'
        assert b'Mecum disconnected' in child.stderr.read()
        print('task_and_revocation_passed')
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()
    """#
}
