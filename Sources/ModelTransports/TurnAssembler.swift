//
//  TurnAssembler.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation

/// Assembles one provider's event stream: bytes in, text deltas and whole
/// tool calls out, and the provider's own terminal event before the turn may
/// be called complete.
///
/// The network path and the tests drive the same `accept`: a chunk may end
/// anywhere, including inside a UTF-8 sequence or halfway through an event, so
/// nothing is decoded before the newline that completes its line.
struct TurnAssembler: Sendable {

    /// One payload in, the text it carries out. It also fills the running
    /// account: the token counts and the provider's own end of turn.
    typealias PayloadDecoding = @Sendable (Data, inout TurnProgress) throws -> String?

    private var reader: EventStreamReader
    private let decode: PayloadDecoding
    private let recordProvider: ModelProvider?
    private(set) var progress = TurnProgress()
    private(set) var deltaCount = 0

    /// How many of `progress.toolCalls` have been taken.
    private var takenToolCalls = 0

    /// `recording` names the provider whose turn is kept as a `TurnRecord`,
    /// nil for a provider that is never sent its turn back.
    init(format: EventStreamReader.Format, decode: @escaping PayloadDecoding,
         recording recordProvider: ModelProvider? = nil) {
        self.reader = EventStreamReader(format: format)
        self.decode = decode
        self.recordProvider = recordProvider
    }

    /// The text this byte completed, if it completed any.
    mutating func accept(_ byte: UInt8) throws -> String? {
        guard let payload = reader.accept(byte) else { return nil }
        guard let text = try decode(payload, &progress), !text.isEmpty else { return nil }
        deltaCount += 1
        return text
    }

    /// The texts this chunk completed, in the order the provider sent them.
    mutating func accept(_ chunk: Data) throws -> [String] {
        try chunk.compactMap { try accept($0) }
    }

    /// The provider's own copy of the turn, when it keeps one and the turn had content.
    var record: TurnRecord? {
        guard let recordProvider, !progress.contentBlocks.isEmpty else { return nil }
        return TurnRecord(provider: recordProvider, blocks: progress.contentBlocks)
    }

    /// The tool calls completed since the last take, in the order they arrived.
    mutating func takeToolCalls() -> [ToolCall] {
        defer { takenToolCalls = progress.toolCalls.count }
        return Array(progress.toolCalls[takenToolCalls...])
    }

    /// The terminal element, or the refusal owed when the provider never
    /// declared the turn finished or ended it short of a whole answer.
    func completion(wallClock: Duration) throws -> TurnEvent {
        guard progress.isFinished else { throw ModelTransportError.streamEndedEarly(deltas: deltaCount) }
        guard progress.isWholeAnswer else {
            throw ModelTransportError.stoppedShort(reason: progress.stopReason, deltas: deltaCount)
        }
        return .completed(progress.usage(wallClock: wallClock))
    }
}

/// Splits a byte stream into the JSON payloads its events carry: the `data:`
/// line of a server-sent event, or a whole line of newline-delimited JSON.
/// Bytes are held until the newline that ends their line, which is what makes
/// a split inside a multi-byte character harmless: nothing is ever decoded as
/// text before it is whole.
struct EventStreamReader: Sendable {

    enum Format: Sendable {
        /// `event:` and `data:` lines separated by blank lines. One `data:`
        /// line per event: no provider here splits a payload over several.
        case serverSentEvents
        /// One JSON object per line.
        case newlineDelimitedJSON
    }

    private static let dataPrefix = Array("data:".utf8)

    private let format: Format
    private var line: [UInt8] = []

    init(format: Format) {
        self.format = format
    }

    /// The payload this byte completed, if the line it ended carried one.
    mutating func accept(_ byte: UInt8) -> Data? {
        guard byte == 0x0A else {
            line.append(byte)
            return nil
        }
        defer { line.removeAll(keepingCapacity: true) }
        var bytes = line[...]
        if bytes.last == 0x0D { bytes = bytes.dropLast() }
        switch format {
        case .serverSentEvents:
            guard bytes.starts(with: Self.dataPrefix) else { return nil }
            var payload = bytes.dropFirst(Self.dataPrefix.count)
            if payload.first == 0x20 { payload = payload.dropFirst() }
            return payload.isEmpty ? nil : Data(payload)
        case .newlineDelimitedJSON:
            return bytes.isEmpty ? nil : Data(bytes)
        }
    }
}
