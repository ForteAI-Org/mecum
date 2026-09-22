//
//  CodexEventStreamTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import Testing
@testable import ModelTransports

@Test func decodesCodexEventStream() throws {
    let answer = #"{"status":"plan","reason":"r","steps":[{"target":"1:click","text":null,"reason":"s"}]}"#
    let lines = [
        #"{"type":"turn.started"}"#,
        #"{"type":"item.completed","item":{"type":"reasoning","text":"..."}}"#,
        #"{"type":"item.completed","item":{"type":"agent_message","text":\#(String(reflecting: answer))}}"#,
        #"{"type":"turn.completed"}"#,
    ].joined(separator: "\n")
    // The transport hands back the final agent message undecoded: what the
    // JSON means is the caller's vocabulary, not this module's.
    let data = try CodexCLIClient.decodeStructuredOutput(output: Data(lines.utf8), exitStatus: 0)
    #expect(String(decoding: data, as: UTF8.self) == answer)
}

@Test func refusesToolUseInCodexStream() {
    let lines = [
        #"{"type":"turn.started"}"#,
        #"{"type":"item.completed","item":{"type":"command_execution","command":"ls"}}"#,
        #"{"type":"turn.completed"}"#,
    ].joined(separator: "\n")
    #expect(throws: CodexClientError.self) {
        try CodexCLIClient.decodeStructuredOutput(output: Data(lines.utf8), exitStatus: 0)
    }
}
